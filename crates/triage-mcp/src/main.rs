#![cfg_attr(windows, allow(dead_code, unused_imports))]
use std::ffi::{OsStr, OsString};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};
use triage_core::session::{SessionApi, SessionId, StyledRowsRequest};
#[cfg(unix)]
use triaged::ipc::{UnixSocketClient, default_socket_path};

const PROTOCOL_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "triage-mcp";

fn main() -> Result<()> {
    let config = ServerConfig::from_args(std::env::args_os().skip(1))?;
    if config.help {
        println!("{}", ServerConfig::HELP);
        return Ok(());
    }

    run_stdio(config)
}

fn run_stdio(config: ServerConfig) -> Result<()> {
    #[cfg(unix)]
    {
        let client = UnixSocketClient::new(config.socket_path.unwrap_or_else(default_socket_path));
        run_stdio_with_client(client, io::stdin().lock(), io::stdout().lock())
    }

    #[cfg(not(unix))]
    {
        let _ = config;
        bail!("triage-mcp requires the Unix socket API, which is only available on Unix platforms")
    }
}

fn run_stdio_with_client(
    client: impl SessionApi,
    input: impl BufRead,
    mut output: impl Write,
) -> Result<()> {
    let server = McpServer::new(client);
    for line in input.lines() {
        let line = line.context("reading MCP stdin")?;
        if line.trim().is_empty() {
            continue;
        }

        let response = match decode_json_rpc_request(&line) {
            Ok(request) => server.handle(request),
            Err((id, error)) => Some(JsonRpcResponse::error(id, error)),
        };

        if let Some(response) = response {
            serde_json::to_writer(&mut output, &response).context("writing MCP response")?;
            output
                .write_all(b"\n")
                .context("terminating MCP response")?;
            output.flush().context("flushing MCP response")?;
        }
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ServerConfig {
    socket_path: Option<PathBuf>,
    help: bool,
}

impl ServerConfig {
    const HELP: &'static str = "\
usage: triage-mcp [--socket <path>]

Options:
  --socket <path>  Connect to a Triage daemon Unix socket at <path>
  -h, --help       Print this help text

By default triage-mcp connects to the same Unix socket path as triaged.";

    fn from_args(args: impl IntoIterator<Item = OsString>) -> Result<Self> {
        let mut socket_path = None;
        let mut args = args.into_iter();

        while let Some(arg) = args.next() {
            match arg.to_str() {
                Some("--socket") => {
                    if socket_path.is_some() {
                        bail!("--socket can only be passed once; pass --help for usage");
                    }
                    let Some(path) = args.next() else {
                        bail!("--socket requires a path; pass --help for usage");
                    };
                    socket_path = Some(PathBuf::from(path));
                }
                Some("--help") | Some("-h") => {
                    return Ok(Self {
                        socket_path: None,
                        help: true,
                    });
                }
                Some(flag) if flag.starts_with('-') => {
                    bail!("unknown option {flag}; pass --help for usage")
                }
                Some(value) => bail!("unexpected argument {value}; pass --help for usage"),
                None => bail!(
                    "unexpected non-UTF-8 argument {}; pass socket paths with --socket or pass --help for usage",
                    display_os_str(&arg)
                ),
            }
        }

        Ok(Self {
            socket_path,
            help: false,
        })
    }
}

fn display_os_str(value: &OsStr) -> String {
    value.to_string_lossy().into_owned()
}

struct McpServer<A> {
    api: A,
}

impl<A: SessionApi> McpServer<A> {
    fn new(api: A) -> Self {
        Self { api }
    }

    fn handle(&self, request: JsonRpcRequest) -> Option<JsonRpcResponse> {
        let id = match request.id {
            JsonRpcId::Notification => return None,
            JsonRpcId::Request(id) => id,
        };
        match self.handle_request(&request.method, request.params) {
            Ok(result) => Some(JsonRpcResponse::result(id, result)),
            Err(error) => Some(JsonRpcResponse::error(id, error)),
        }
    }

    fn handle_request(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> std::result::Result<Value, JsonRpcError> {
        match method {
            "initialize" => Ok(json!({
                "protocolVersion": requested_protocol_version(params).unwrap_or(PROTOCOL_VERSION),
                "capabilities": {
                    "tools": {
                        "listChanged": false
                    }
                },
                "serverInfo": {
                    "name": SERVER_NAME,
                    "version": env!("CARGO_PKG_VERSION")
                }
            })),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({ "tools": tool_definitions() })),
            "tools/call" => {
                let params = params
                    .ok_or_else(|| JsonRpcError::invalid_params("tools/call requires params"))?;
                match self.call_tool(params) {
                    Ok(result) => Ok(result),
                    Err(ToolCallError::Protocol(error)) => Err(error),
                    Err(ToolCallError::Tool(error)) => Ok(tool_error(error)),
                }
            }
            other => Err(JsonRpcError::method_not_found(format!(
                "unsupported MCP method {other}"
            ))),
        }
    }

    fn call_tool(&self, params: Value) -> std::result::Result<Value, ToolCallError> {
        let params = params
            .as_object()
            .ok_or_else(|| JsonRpcError::invalid_params("tools/call params must be an object"))?;
        let name = required_string(params, "name")?;
        let arguments = params
            .get("arguments")
            .cloned()
            .unwrap_or_else(|| json!({}));

        match name {
            "list_sessions" => tool_result(list_sessions(&self.api)?),
            "snapshot_session" => tool_result(snapshot_session(&self.api, arguments)?),
            "styled_rows" => tool_result(styled_rows(&self.api, arguments)?),
            other => {
                Err(JsonRpcError::invalid_params(format!("unknown Triage tool {other}")).into())
            }
        }
    }
}

fn decode_json_rpc_request(
    line: &str,
) -> std::result::Result<JsonRpcRequest, (Value, JsonRpcError)> {
    let value = serde_json::from_str::<Value>(line)
        .map_err(|error| (Value::Null, JsonRpcError::parse_error(error.to_string())))?;
    let id = response_id_for_invalid_request(&value);
    serde_json::from_value::<JsonRpcRequest>(value).map_err(|error| {
        (
            id,
            JsonRpcError::invalid_request(format!("invalid JSON-RPC request: {error}")),
        )
    })
}

fn response_id_for_invalid_request(value: &Value) -> Value {
    let Some(id) = value.get("id") else {
        return Value::Null;
    };
    match id {
        Value::Null | Value::String(_) | Value::Number(_) => id.clone(),
        _ => Value::Null,
    }
}

fn requested_protocol_version(params: Option<Value>) -> Option<&'static str> {
    params?
        .get("protocolVersion")?
        .as_str()
        .filter(|value| !value.trim().is_empty())?;
    Some(PROTOCOL_VERSION)
}

fn tool_definitions() -> Value {
    json!([
        {
            "name": "list_sessions",
            "title": "List Triage Sessions",
            "description": "List daemon-owned Triage sessions with current snapshots.",
            "inputSchema": {
                "type": "object",
                "properties": {}
            },
            "annotations": {
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            }
        },
        {
            "name": "snapshot_session",
            "title": "Read Triage Session Snapshot",
            "description": "Read the current daemon snapshot for one Triage session.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": "Triage session id."
                    }
                },
                "required": ["session_id"]
            },
            "annotations": {
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            }
        },
        {
            "name": "styled_rows",
            "title": "Read Triage Styled Rows",
            "description": "Read a styled row range from one Triage session snapshot.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": "Triage session id."
                    },
                    "start": {
                        "type": "integer",
                        "minimum": 0,
                        "description": "Inclusive visible row index."
                    },
                    "end": {
                        "type": "integer",
                        "minimum": 0,
                        "description": "Exclusive visible row index."
                    }
                },
                "required": ["session_id", "start", "end"]
            },
            "annotations": {
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            }
        }
    ])
}

fn list_sessions(api: &impl SessionApi) -> Result<Value> {
    let session_ids = api.list_sessions().context("listing sessions")?;
    let sessions = session_ids
        .into_iter()
        .map(|session_id| {
            let snapshot = api
                .snapshot_session(session_id.clone())
                .with_context(|| format!("reading snapshot for session {session_id}"))?;
            Ok(json!({
                "id": session_id,
                "snapshot": snapshot
            }))
        })
        .collect::<Result<Vec<_>>>()?;

    Ok(json!({ "sessions": sessions }))
}

fn snapshot_session(
    api: &impl SessionApi,
    arguments: Value,
) -> std::result::Result<Value, ToolCallError> {
    let arguments = arguments_object(&arguments)?;
    let session_id = session_id_arg(arguments)?;
    let snapshot = api
        .snapshot_session(session_id.clone())
        .with_context(|| format!("reading snapshot for session {session_id}"))?;

    Ok(json!({
        "session_id": session_id,
        "snapshot": snapshot
    }))
}

fn styled_rows(
    api: &impl SessionApi,
    arguments: Value,
) -> std::result::Result<Value, ToolCallError> {
    let arguments = arguments_object(&arguments)?;
    let request = StyledRowsRequest {
        session_id: session_id_arg(arguments)?,
        start: required_usize(arguments, "start")?,
        end: required_usize(arguments, "end")?,
    };
    if request.end < request.start {
        return Err(JsonRpcError::invalid_params(
            "styled_rows end must be greater than or equal to start",
        )
        .into());
    }

    let response = api
        .styled_rows(request.clone())
        .with_context(|| format!("reading styled rows for session {}", request.session_id))?;

    Ok(json!({
        "session_id": request.session_id,
        "output_seq": response.output_seq,
        "start": response.start,
        "rows": response.rows
    }))
}

fn tool_result(structured_content: Value) -> std::result::Result<Value, ToolCallError> {
    let text = serde_json::to_string_pretty(&structured_content)
        .context("serializing tool result")
        .map_err(ToolCallError::Tool)?;
    Ok(json!({
        "content": [
            {
                "type": "text",
                "text": text
            }
        ],
        "structuredContent": structured_content,
        "isError": false
    }))
}

fn tool_error(error: anyhow::Error) -> Value {
    json!({
        "content": [
            {
                "type": "text",
                "text": format!("{error:#}")
            }
        ],
        "isError": true
    })
}

fn arguments_object(
    arguments: &Value,
) -> std::result::Result<&serde_json::Map<String, Value>, ToolCallError> {
    arguments
        .as_object()
        .ok_or_else(|| JsonRpcError::invalid_params("tool arguments must be an object").into())
}

fn session_id_arg(
    arguments: &serde_json::Map<String, Value>,
) -> std::result::Result<SessionId, ToolCallError> {
    SessionId::new(required_argument_string(arguments, "session_id")?)
        .context("validating session_id")
        .map_err(ToolCallError::Tool)
}

fn required_argument_string<'a>(
    values: &'a serde_json::Map<String, Value>,
    field: &str,
) -> std::result::Result<&'a str, ToolCallError> {
    values
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| {
            JsonRpcError::invalid_params(format!("{field} must be a non-empty string")).into()
        })
}

fn required_string<'a>(
    values: &'a serde_json::Map<String, Value>,
    field: &str,
) -> std::result::Result<&'a str, ToolCallError> {
    let value = values
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| {
            JsonRpcError::invalid_params(format!("{field} must be a non-empty string"))
        })?;
    Ok(value)
}

fn required_usize(
    values: &serde_json::Map<String, Value>,
    field: &str,
) -> std::result::Result<usize, ToolCallError> {
    let value = values.get(field).and_then(Value::as_u64).ok_or_else(|| {
        JsonRpcError::invalid_params(format!("{field} must be a non-negative integer"))
    })?;
    usize::try_from(value)
        .with_context(|| format!("{field} must fit in usize"))
        .map_err(ToolCallError::Tool)
}

#[derive(Debug)]
enum ToolCallError {
    Protocol(JsonRpcError),
    Tool(anyhow::Error),
}

impl From<JsonRpcError> for ToolCallError {
    fn from(error: JsonRpcError) -> Self {
        Self::Protocol(error)
    }
}

impl From<anyhow::Error> for ToolCallError {
    fn from(error: anyhow::Error) -> Self {
        Self::Tool(error)
    }
}

#[derive(Debug, Deserialize)]
struct JsonRpcRequest {
    #[serde(default)]
    id: JsonRpcId,
    method: String,
    #[serde(default)]
    params: Option<Value>,
}

#[derive(Debug, Default)]
enum JsonRpcId {
    #[default]
    Notification,
    Request(Value),
}

impl<'de> Deserialize<'de> for JsonRpcId {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Value::deserialize(deserializer).map(Self::Request)
    }
}

#[derive(Debug, Serialize)]
struct JsonRpcResponse {
    jsonrpc: &'static str,
    id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<JsonRpcError>,
}

impl JsonRpcResponse {
    fn result(id: Value, result: Value) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: Some(result),
            error: None,
        }
    }

    fn error(id: Value, error: JsonRpcError) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: None,
            error: Some(error),
        }
    }
}

#[derive(Debug, Serialize)]
struct JsonRpcError {
    code: i64,
    message: String,
}

impl JsonRpcError {
    fn parse_error(message: impl Into<String>) -> Self {
        Self {
            code: -32700,
            message: message.into(),
        }
    }

    fn invalid_request(message: impl Into<String>) -> Self {
        Self {
            code: -32600,
            message: message.into(),
        }
    }

    fn invalid_params(message: impl Into<String>) -> Self {
        Self {
            code: -32602,
            message: message.into(),
        }
    }

    fn method_not_found(message: impl Into<String>) -> Self {
        Self {
            code: -32601,
            message: message.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use triage_core::session::{
        AttachSessionRequest, AttachSessionResponse, CompletedSession, InputLeaseRequest,
        LeaseChange, ResizeSessionRequest, SessionEventReceiver, SessionSize, SessionSnapshot,
        TerminalCursor,
    };

    #[derive(Clone)]
    struct RecordingApi {
        sessions: Vec<SessionId>,
        snapshot: SessionSnapshot,
        snapshot_error: Option<&'static str>,
    }

    impl RecordingApi {
        fn new() -> Self {
            Self {
                sessions: vec![SessionId::new("session-1").unwrap()],
                snapshot: SessionSnapshot {
                    output_seq: 7,
                    bytes_logged: 12,
                    size: SessionSize::default(),
                    visible_rows: vec!["ready".to_string()],
                    styled_rows_start: 0,
                    styled_rows: Vec::new(),
                    cursor: TerminalCursor {
                        row: 0,
                        col: 5,
                        visible: true,
                    },
                    current_working_directory: None,
                    context: None,
                    bracketed_paste_enabled: false,
                    exited: false,
                    raw_output: Vec::new(),
                    raw_output_start: 0,
                    snippet: None,
                    snippet_detail: None,
                },
                snapshot_error: None,
            }
        }

        fn with_snapshot_error(mut self, message: &'static str) -> Self {
            self.snapshot_error = Some(message);
            self
        }
    }

    impl SessionApi for RecordingApi {
        fn list_sessions(&self) -> Result<Vec<SessionId>> {
            Ok(self.sessions.clone())
        }

        fn start_session(
            &self,
            _request: triage_core::session::StartSessionRequest,
        ) -> Result<SessionId> {
            unimplemented!()
        }

        fn attach_session(&self, _request: AttachSessionRequest) -> Result<AttachSessionResponse> {
            unimplemented!()
        }

        fn subscribe_session_events(&self, _session_id: SessionId) -> Result<SessionEventReceiver> {
            unimplemented!()
        }

        fn acquire_input_lease(&self, _request: InputLeaseRequest) -> Result<LeaseChange> {
            unimplemented!()
        }

        fn release_input_lease(
            &self,
            _session_id: SessionId,
            _client_id: triage_core::session::ClientId,
        ) -> Result<LeaseChange> {
            unimplemented!()
        }

        fn write_input(&self, _request: triage_core::session::WriteInputRequest) -> Result<()> {
            unimplemented!()
        }

        fn resize_session(&self, _request: ResizeSessionRequest) -> Result<SessionSnapshot> {
            unimplemented!()
        }

        fn snapshot_session(&self, _session_id: SessionId) -> Result<SessionSnapshot> {
            if let Some(message) = self.snapshot_error {
                bail!(message);
            }
            Ok(self.snapshot.clone())
        }

        fn styled_rows(
            &self,
            request: StyledRowsRequest,
        ) -> Result<triage_core::session::StyledRowsResponse> {
            Ok(triage_core::session::StyledRowsResponse {
                output_seq: self.snapshot.output_seq,
                start: request.start,
                rows: Vec::new(),
            })
        }

        fn shutdown_session(&self, _session_id: SessionId) -> Result<CompletedSession> {
            unimplemented!()
        }
    }

    #[test]
    fn lists_tools() {
        let server = McpServer::new(RecordingApi::new());

        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!(1)),
                method: "tools/list".to_string(),
                params: None,
            })
            .expect("response");

        let tools = response.result.unwrap()["tools"]
            .as_array()
            .unwrap()
            .clone();
        assert_eq!(tools.len(), 3);
        assert_eq!(tools[0]["name"], "list_sessions");
    }

    #[test]
    fn list_sessions_returns_structured_content() {
        let server = McpServer::new(RecordingApi::new());

        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!("call-1")),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "list_sessions",
                    "arguments": {}
                })),
            })
            .expect("response");

        let result = response.result.unwrap();
        assert_eq!(result["isError"], false);
        assert_eq!(
            result["structuredContent"]["sessions"][0]["id"],
            "session-1"
        );
        assert_eq!(
            result["structuredContent"]["sessions"][0]["snapshot"]["visible_rows"][0],
            "ready"
        );
    }

    #[test]
    fn validates_required_tool_arguments() {
        let server = McpServer::new(RecordingApi::new());

        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!(2)),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "snapshot_session",
                    "arguments": {}
                })),
            })
            .expect("response");

        let error = response.error.expect("error");
        assert_eq!(error.code, -32602);
        assert!(error.message.contains("session_id"));
    }

    #[test]
    fn unknown_tool_names_are_invalid_params() {
        let server = McpServer::new(RecordingApi::new());

        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!(3)),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "missing_tool",
                    "arguments": {}
                })),
            })
            .expect("response");

        let error = response.error.expect("error");
        assert_eq!(error.code, -32602);
        assert!(error.message.contains("missing_tool"));
    }

    #[test]
    fn stdio_distinguishes_parse_errors_from_invalid_requests() {
        let input = b"{\n{}\n{\"jsonrpc\":\"2.0\",\"id\":\"bad\",\"params\":{}}\n".as_slice();
        let mut output = Vec::new();

        run_stdio_with_client(RecordingApi::new(), input, &mut output).expect("stdio run");

        let responses = String::from_utf8(output)
            .expect("utf8 output")
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("json response"))
            .collect::<Vec<_>>();

        assert_eq!(responses.len(), 3);
        assert_eq!(responses[0]["id"], Value::Null);
        assert_eq!(responses[0]["error"]["code"], -32700);
        assert_eq!(responses[1]["id"], Value::Null);
        assert_eq!(responses[1]["error"]["code"], -32600);
        assert_eq!(responses[2]["id"], "bad");
        assert_eq!(responses[2]["error"]["code"], -32600);
    }

    #[test]
    fn tool_execution_errors_return_tool_results() {
        let server = McpServer::new(RecordingApi::new().with_snapshot_error("session exited"));

        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!("call-2")),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "snapshot_session",
                    "arguments": {
                        "session_id": "session-1"
                    }
                })),
            })
            .expect("response");

        assert!(response.error.is_none());
        let result = response.result.expect("result");
        assert_eq!(result["isError"], true);
        assert!(
            result["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("session exited")
        );
    }

    #[test]
    fn explicit_null_ids_get_responses() {
        let server = McpServer::new(RecordingApi::new());
        let request = serde_json::from_value::<JsonRpcRequest>(json!({
            "jsonrpc": "2.0",
            "id": null,
            "method": "ping"
        }))
        .expect("request");

        let response = server.handle(request).expect("response");

        assert_eq!(response.id, Value::Null);
        assert_eq!(response.result.expect("result"), json!({}));
    }

    #[test]
    fn notifications_do_not_get_responses() {
        let server = McpServer::new(RecordingApi::new());

        let response = server.handle(JsonRpcRequest {
            id: JsonRpcId::Notification,
            method: "notifications/initialized".to_string(),
            params: None,
        });

        assert!(response.is_none());
    }
}
