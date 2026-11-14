use std::ffi::{OsStr, OsString};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};
use triage_core::session::{
    SESSION_MESSAGE_DEFAULT_WAIT_TIMEOUT_MS, SESSION_MESSAGE_MAX_WAIT_TIMEOUT_MS,
    SendSessionMessageRequest, SessionApi, SessionId, SessionSize, StartSessionRequest,
    StyledRowsRequest, WaitForSessionMessagesRequest,
};
#[cfg(any(unix, windows))]
use triaged::ipc::{IpcClient, default_socket_path};

const PROTOCOL_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "triage-mcp";

mod workers;

fn main() -> Result<()> {
    let mut args = std::env::args_os().skip(1);
    if args.next().as_deref() == Some(OsStr::new("worker-update")) {
        return workers::update_cli(args);
    }
    let config = ServerConfig::from_args(std::env::args_os().skip(1))?;
    if config.help {
        println!("{}", ServerConfig::HELP);
        return Ok(());
    }

    run_stdio(config)
}

fn run_stdio(config: ServerConfig) -> Result<()> {
    #[cfg(any(unix, windows))]
    {
        let client = IpcClient::new(config.socket_path.unwrap_or_else(default_socket_path));
        run_stdio_with_client(client, io::stdin().lock(), io::stdout().lock())
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = config;
        bail!("triage-mcp requires the local IPC transport, which is unavailable on this platform")
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
  --socket <path>  Connect to a Triage daemon control socket at <path>
                   (Unix domain socket on Unix, named pipe on Windows)
  -h, --help       Print this help text

By default triage-mcp connects to the same control socket as triaged.";

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
            name if workers::TOOL_NAMES.contains(&name) => {
                tool_result(workers::call(&self.api, name, arguments)?)
            }
            "list_sessions" => tool_result(list_sessions(&self.api)?),
            "start_session" => tool_result(start_session(&self.api, arguments)?),
            "shutdown_session" => tool_result(shutdown_session(&self.api, arguments)?),
            "snapshot_session" => tool_result(snapshot_session(&self.api, arguments)?),
            "styled_rows" => tool_result(styled_rows(&self.api, arguments)?),
            "send_session_message" => tool_result(send_session_message(&self.api, arguments)?),
            "receive_session_messages" => {
                tool_result(receive_session_messages(&self.api, arguments)?)
            }
            "wait_for_session_message" => {
                tool_result(wait_for_session_message(&self.api, arguments)?)
            }
            "ack_session_messages" => tool_result(ack_session_messages(&self.api, arguments)?),
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
    if !value.is_object() {
        return Err((
            Value::Null,
            JsonRpcError::invalid_request("JSON-RPC request must be an object"),
        ));
    }
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
    let mut definitions = json!([
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
            "name": "start_session",
            "title": "Start Triage Session",
            "description": "Start an executable in a new daemon-owned terminal session with an explicit absolute working directory. Arguments are passed directly, without shell expansion. Returns session_id; track it to manage only this worker. Launch flags and initial prompts are runtime-specific. An ambiguous failure must be reconciled before retrying because this operation is not idempotent.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "command": { "type": "string", "minLength": 1, "description": "Executable name or path, not a shell command line." },
                    "args": { "type": "array", "items": { "type": "string" }, "description": "Literal argv entries, including any agent-specific initial prompt or launch flags. Defaults to []." },
                    "cwd": { "type": "string", "minLength": 1, "description": "Absolute working directory on the daemon host." },
                    "rows": { "type": "integer", "minimum": 1, "maximum": 65535, "description": "PTY rows (default 24)." },
                    "cols": { "type": "integer", "minimum": 1, "maximum": 65535, "description": "PTY columns (default 80)." }
                },
                "required": ["command", "cwd"],
                "additionalProperties": false
            },
            "annotations": {
                "readOnlyHint": false,
                "destructiveHint": true,
                "idempotentHint": false,
                "openWorldHint": true
            }
        },
        {
            "name": "shutdown_session",
            "title": "Shutdown Triage Session",
            "description": "Stop the specified terminal session and its running work using the daemon's shutdown path. Only stop a session you currently own or that the user explicitly asked you to stop. Revalidate worker identity before using a saved ID: numeric IDs can be reused after a cold daemon restart. Returns its completed terminal output, not an agent review report. Repeated calls may fail if the session is already gone.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string", "minLength": 1, "description": "Exact, currently verified worker session id, or a current session explicitly selected by the user." }
                },
                "required": ["session_id"],
                "additionalProperties": false
            },
            "annotations": {
                "readOnlyHint": false,
                "destructiveHint": true,
                "idempotentHint": false,
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
        },
        {
            "name": "send_session_message",
            "title": "Send Session Message",
            "description": "Queue a direct coordination message in another session's inbox. Mail is poll-based: the target reads it with receive_session_messages or wait_for_session_message, which keeps returning it until ack_session_messages confirms it. Pass wake: true to nudge the target session if it is currently idle or waiting for input.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "from_session_id": {
                        "type": "string",
                        "description": "Sender session id (caller-asserted)."
                    },
                    "to_session_id": {
                        "type": "string",
                        "description": "Target session id."
                    },
                    "body": {
                        "type": "string",
                        "description": "Message body (required, non-blank after trimming, at most 65536 bytes; blank or oversize bodies are rejected)."
                    },
                    "wake": {
                        "type": "boolean",
                        "description": "Optional. When true, nudges the target session to check its Triage inbox if it is currently idle or waiting for input."
                    }
                },
                "required": ["from_session_id", "to_session_id", "body"]
            },
            "annotations": {
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false
            }
        },
        {
            "name": "receive_session_messages",
            "title": "Read Session Messages",
            "description": "Peek a session's unacked inbox mail, oldest first. Poll this to check for mail; unacked mail is returned again on the next call.",
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
            "name": "wait_for_session_message",
            "title": "Wait For Session Message",
            "description": "Block until at least one unacked message is present in the session's inbox or timeout_ms elapses. Returns immediately if unacked mail is already waiting, or an empty messages list on timeout.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": "Triage session id."
                    },
                    "timeout_ms": {
                        "type": "integer",
                        "minimum": 0,
                        "maximum": SESSION_MESSAGE_MAX_WAIT_TIMEOUT_MS,
                        "description": "Maximum milliseconds to wait before returning an empty messages list (default 30000, max 300000)."
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
            "name": "ack_session_messages",
            "title": "Acknowledge Session Messages",
            "description": "Confirm receipt of inbox mail, removing it so it stops redelivering. Unknown ids are ignored.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": "Triage session id."
                    },
                    "message_ids": {
                        "type": "array",
                        "items": {
                            "type": "integer",
                            "minimum": 0
                        },
                        "description": "Inbox message ids to confirm."
                    }
                },
                "required": ["session_id", "message_ids"]
            },
            "annotations": {
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            }
        }
    ]);
    definitions
        .as_array_mut()
        .expect("tool definitions are an array")
        .extend(workers::definitions());
    definitions
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StartSessionArguments {
    command: String,
    #[serde(default)]
    args: Vec<String>,
    cwd: String,
    #[serde(default = "default_session_rows")]
    rows: usize,
    #[serde(default = "default_session_cols")]
    cols: usize,
}

fn default_session_rows() -> usize {
    SessionSize::default().rows
}

fn default_session_cols() -> usize {
    SessionSize::default().cols
}

fn start_session(
    api: &impl SessionApi,
    arguments: Value,
) -> std::result::Result<Value, ToolCallError> {
    arguments_object(&arguments)?;
    let arguments: StartSessionArguments = serde_json::from_value(arguments).map_err(|error| {
        JsonRpcError::invalid_params(format!("invalid start_session arguments: {error}"))
    })?;
    if arguments.command.trim().is_empty()
        || arguments.command.contains('\0')
        || arguments.args.iter().any(|arg| arg.contains('\0'))
    {
        return Err(JsonRpcError::invalid_params(
            "command must be non-blank and command/args must not contain NUL bytes",
        )
        .into());
    }
    let cwd = PathBuf::from(&arguments.cwd);
    if !cwd.is_absolute() || arguments.cwd.contains('\0') {
        return Err(
            JsonRpcError::invalid_params("cwd must be an absolute path without NUL bytes").into(),
        );
    }
    let mut request = StartSessionRequest::new(arguments.command);
    request.args = arguments.args;
    request.cwd = Some(cwd);
    request.size.rows = arguments.rows;
    request.size.cols = arguments.cols;
    request
        .validate()
        .map_err(|error| JsonRpcError::invalid_params(error.to_string()))?;
    let session_id = api.start_session(request).context("starting session")?;
    Ok(json!({ "session_id": session_id }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ShutdownSessionArguments {
    session_id: String,
}

fn shutdown_session(
    api: &impl SessionApi,
    arguments: Value,
) -> std::result::Result<Value, ToolCallError> {
    arguments_object(&arguments)?;
    let arguments: ShutdownSessionArguments =
        serde_json::from_value(arguments).map_err(|error| {
            JsonRpcError::invalid_params(format!("invalid shutdown_session arguments: {error}"))
        })?;
    let session_id = SessionId::new(arguments.session_id)
        .map_err(|error| JsonRpcError::invalid_params(error.to_string()))?;
    let completed = api
        .shutdown_session(session_id.clone())
        .with_context(|| format!("shutting down session {session_id}"))?;
    Ok(json!({ "session_id": session_id, "completed": completed }))
}

fn list_sessions(api: &impl SessionApi) -> Result<Value> {
    let session_ids = api.list_sessions().context("listing sessions")?;
    // Labels are enrichment, not the feature: a layout failure (or a daemon
    // predating the rail-layout call) degrades to unlabeled sessions rather
    // than failing the whole read.
    let layout = api.get_rail_layout().unwrap_or_default();
    let sessions = session_ids
        .into_iter()
        .map(|session_id| {
            let snapshot = api
                .snapshot_session(session_id.clone())
                .with_context(|| format!("reading snapshot for session {session_id}"))?;
            let custom_label: Option<&String> = layout.custom_labels.get(session_id.as_str());
            Ok(json!({
                "id": session_id,
                "custom_label": custom_label,
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

fn send_session_message(
    api: &impl SessionApi,
    arguments: Value,
) -> std::result::Result<Value, ToolCallError> {
    let arguments = arguments_object(&arguments)?;
    let from = named_session_id_arg(arguments, "from_session_id")?;
    let to = named_session_id_arg(arguments, "to_session_id")?;
    let body = required_argument_string(arguments, "body")?.to_string();
    let wake = optional_bool(arguments, "wake")?.unwrap_or(false);

    let response = api
        .send_session_message_with_options(SendSessionMessageRequest {
            from: from.clone(),
            to: to.clone(),
            body,
            wake,
        })
        .with_context(|| format!("sending message from session {from} to session {to}"))?;

    Ok(json!({
        "message_id": response.message_id,
        "woke": response.woke,
    }))
}

fn receive_session_messages(
    api: &impl SessionApi,
    arguments: Value,
) -> std::result::Result<Value, ToolCallError> {
    let arguments = arguments_object(&arguments)?;
    let session_id = session_id_arg(arguments)?;
    let messages = api
        .receive_session_messages(session_id.clone())
        .with_context(|| format!("reading messages for session {session_id}"))?;

    Ok(format_session_messages_result(session_id, &messages))
}

fn wait_for_session_message(
    api: &impl SessionApi,
    arguments: Value,
) -> std::result::Result<Value, ToolCallError> {
    let arguments = arguments_object(&arguments)?;
    let session_id = session_id_arg(arguments)?;
    let timeout_ms =
        optional_u64(arguments, "timeout_ms")?.unwrap_or(SESSION_MESSAGE_DEFAULT_WAIT_TIMEOUT_MS);
    if timeout_ms > SESSION_MESSAGE_MAX_WAIT_TIMEOUT_MS {
        return Err(JsonRpcError::invalid_params(format!(
            "timeout_ms must be at most {SESSION_MESSAGE_MAX_WAIT_TIMEOUT_MS}"
        ))
        .into());
    }

    let messages = api
        .wait_for_session_messages(WaitForSessionMessagesRequest {
            session_id: session_id.clone(),
            timeout_ms,
        })
        .with_context(|| format!("waiting for messages for session {session_id}"))?;

    Ok(format_session_messages_result(session_id, &messages))
}

fn format_session_messages_result(
    session_id: SessionId,
    messages: &[triage_core::session::SessionMessage],
) -> Value {
    json!({
        "session_id": session_id,
        "messages": messages
            .iter()
            .map(|message| json!({
                "id": message.id,
                "from_session_id": message.from,
                "body": message.body,
                "sent_at_ms": message.sent_at_ms,
            }))
            .collect::<Vec<_>>(),
    })
}

fn ack_session_messages(
    api: &impl SessionApi,
    arguments: Value,
) -> std::result::Result<Value, ToolCallError> {
    let arguments = arguments_object(&arguments)?;
    let session_id = session_id_arg(arguments)?;
    let message_ids = required_u64_list(arguments, "message_ids")?;
    api.ack_session_messages(session_id, message_ids)
        .context("acknowledging session messages")?;

    Ok(json!({ "ok": true }))
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
    named_session_id_arg(arguments, "session_id")
}

fn named_session_id_arg(
    arguments: &serde_json::Map<String, Value>,
    field: &str,
) -> std::result::Result<SessionId, ToolCallError> {
    SessionId::new(required_argument_string(arguments, field)?)
        .with_context(|| format!("validating {field}"))
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

fn required_u64_list(
    values: &serde_json::Map<String, Value>,
    field: &str,
) -> std::result::Result<Vec<u64>, ToolCallError> {
    let items = values.get(field).and_then(Value::as_array).ok_or_else(|| {
        JsonRpcError::invalid_params(format!("{field} must be an array of integers"))
    })?;
    items
        .iter()
        .map(|item| {
            item.as_u64().ok_or_else(|| {
                JsonRpcError::invalid_params(format!("{field} must be an array of integers")).into()
            })
        })
        .collect()
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

fn optional_bool(
    values: &serde_json::Map<String, Value>,
    field: &str,
) -> std::result::Result<Option<bool>, ToolCallError> {
    match values.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(JsonRpcError::invalid_params(format!("{field} must be a boolean")).into()),
    }
}

fn optional_u64(
    values: &serde_json::Map<String, Value>,
    field: &str,
) -> std::result::Result<Option<u64>, ToolCallError> {
    match values.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value.as_u64().map(Some).ok_or_else(|| {
            JsonRpcError::invalid_params(format!("{field} must be a non-negative integer")).into()
        }),
    }
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
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::rc::Rc;
    use triage_core::session::{
        AttachSessionRequest, AttachSessionResponse, CompletedSession, InputLeaseRequest,
        LeaseChange, RailLayout, ResizeSessionRequest, SessionEventReceiver, SessionMessage,
        SessionSize, SessionSnapshot, TerminalCursor,
    };

    #[derive(Clone)]
    struct RecordingApi {
        sessions: Vec<SessionId>,
        snapshot: SessionSnapshot,
        snapshot_error: Option<&'static str>,
        inbox: RefCell<Vec<SessionMessage>>,
        labels: HashMap<String, String>,
        layout_error: bool,
        starts: Rc<RefCell<Vec<StartSessionRequest>>>,
        shutdowns: Rc<RefCell<Vec<SessionId>>>,
        lifecycle_error: Option<&'static str>,
        worker_calls: Rc<RefCell<Vec<triage_core::workers::WorkerRequest>>>,
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
                    raw_output_prefix: Vec::new(),
                    snippet: None,
                    snippet_detail: None,
                    agent: None,
                },
                snapshot_error: None,
                inbox: RefCell::new(Vec::new()),
                labels: HashMap::new(),
                layout_error: false,
                starts: Rc::new(RefCell::new(Vec::new())),
                shutdowns: Rc::new(RefCell::new(Vec::new())),
                lifecycle_error: None,
                worker_calls: Rc::new(RefCell::new(Vec::new())),
            }
        }

        fn with_layout_error(mut self) -> Self {
            self.layout_error = true;
            self
        }

        fn with_label(mut self, session_id: &str, label: &str) -> Self {
            self.labels
                .insert(session_id.to_string(), label.to_string());
            self
        }

        fn with_snapshot_error(mut self, message: &'static str) -> Self {
            self.snapshot_error = Some(message);
            self
        }
    }

    impl SessionApi for RecordingApi {
        fn worker_operation(
            &self,
            request: triage_core::workers::WorkerRequest,
        ) -> Result<triage_core::workers::WorkerResponse> {
            self.worker_calls.borrow_mut().push(request);
            if let Some(error) = self.lifecycle_error {
                bail!(error);
            }
            Ok(triage_core::workers::WorkerResponse::Groups(Vec::new()))
        }
        fn list_sessions(&self) -> Result<Vec<SessionId>> {
            Ok(self.sessions.clone())
        }

        fn start_session(&self, request: StartSessionRequest) -> Result<SessionId> {
            self.starts.borrow_mut().push(request);
            if let Some(error) = self.lifecycle_error {
                bail!(error);
            }
            SessionId::new("worker-1")
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

        fn send_session_message(
            &self,
            from: SessionId,
            _to: SessionId,
            body: String,
        ) -> Result<u64> {
            let id = self.inbox.borrow().len() as u64 + 1;
            self.inbox.borrow_mut().push(SessionMessage {
                id,
                from,
                body,
                sent_at_ms: 1_700_000_000_000,
            });
            Ok(id)
        }

        fn send_session_message_with_options(
            &self,
            request: SendSessionMessageRequest,
        ) -> Result<triage_core::session::SendSessionMessageResponse> {
            let message_id = self.send_session_message(request.from, request.to, request.body)?;
            Ok(triage_core::session::SendSessionMessageResponse {
                message_id,
                woke: request.wake,
            })
        }

        fn receive_session_messages(&self, _session_id: SessionId) -> Result<Vec<SessionMessage>> {
            Ok(self.inbox.borrow().clone())
        }

        fn wait_for_session_messages(
            &self,
            _request: WaitForSessionMessagesRequest,
        ) -> Result<Vec<SessionMessage>> {
            Ok(self.inbox.borrow().clone())
        }

        fn ack_session_messages(
            &self,
            _session_id: SessionId,
            message_ids: Vec<u64>,
        ) -> Result<()> {
            self.inbox
                .borrow_mut()
                .retain(|message| !message_ids.contains(&message.id));
            Ok(())
        }

        fn get_rail_layout(&self) -> Result<RailLayout> {
            if self.layout_error {
                bail!("rail layout unavailable");
            }
            Ok(RailLayout {
                group_keys: Vec::new(),
                session_ids: Vec::new(),
                custom_labels: self.labels.clone(),
            })
        }

        fn shutdown_session(&self, session_id: SessionId) -> Result<CompletedSession> {
            self.shutdowns.borrow_mut().push(session_id);
            if let Some(error) = self.lifecycle_error {
                bail!(error);
            }
            Ok(CompletedSession {
                output_seq: self.snapshot.output_seq,
                bytes_logged: self.snapshot.bytes_logged,
                visible_rows: self.snapshot.visible_rows.clone(),
            })
        }
    }

    #[test]
    fn managed_worker_arguments_are_strict_and_errors_do_not_call_the_backend() {
        let api = RecordingApi::new();
        let server = McpServer::new(api.clone());
        let spawn = json!({"group_id":"group-a","parent_session_id":"session-1","key":"a","profile":"codex","cwd":absolute_test_cwd(),"task":"Review"});
        let mut invalid = spawn.clone();
        invalid["cwd"] = json!("relative");
        let mut unknown = spawn.clone();
        unknown["extra"] = json!(true);
        let mut null = spawn.clone();
        null["task"] = Value::Null;
        let mut bad_id = spawn.clone();
        bad_id["parent_session_id"] = json!("../bad");
        let mut bad_key = spawn.clone();
        bad_key["key"] = json!("bad key");
        for (name, args) in [
            ("spawn_worker", json!([])),
            ("spawn_worker", json!([spawn.clone()])),
            ("spawn_worker", invalid),
            ("spawn_worker", unknown),
            ("spawn_worker", null),
            ("spawn_worker", bad_id),
            ("spawn_worker", bad_key),
            ("list_worker_groups", json!({"extra":true})),
            ("get_worker_group", json!({"group_id":null})),
            (
                "update_worker",
                json!({"group_id":"group-a","task_id":"task-a","session_id":"worker-a","phase":"succeeded"}),
            ),
            (
                "update_worker",
                json!({"group_id":"group-a","task_id":"task-a","session_id":"worker-a","phase":"launched"}),
            ),
            (
                "cleanup_worker_group",
                json!({"group_id":"group-a","extra":true}),
            ),
            (
                "cleanup_worker_group",
                json!({"group_id":"group-a","subtree_session_id":null}),
            ),
            (
                "update_worker",
                json!({"group_id":"group-a","task_id":"task-a","session_id":"worker-a","phase":"ready","result":null}),
            ),
        ] {
            let error = server
                .call_tool(json!({"name":name,"arguments":args}))
                .unwrap_err();
            assert!(
                matches!(error, ToolCallError::Protocol(_)),
                "{name}: {error:?}"
            );
        }
        assert!(api.worker_calls.borrow().is_empty());
        server
            .call_tool(json!({"name":"spawn_worker","arguments":spawn}))
            .unwrap();
        assert_eq!(api.worker_calls.borrow().len(), 1);
    }

    #[test]
    fn managed_worker_backend_failures_are_tool_errors() {
        let mut api = RecordingApi::new();
        api.lifecycle_error = Some("registry unavailable");
        let server = McpServer::new(api);
        let response = server
            .handle_request(
                "tools/call",
                Some(json!({"name":"list_worker_groups","arguments":{}})),
            )
            .unwrap();
        assert_eq!(response["isError"], true);
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
        assert_eq!(tools.len(), 16);
        assert_eq!(tools[0]["name"], "list_sessions");
        let names = tools
            .iter()
            .map(|tool| tool["name"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            names,
            [
                "list_sessions",
                "start_session",
                "shutdown_session",
                "snapshot_session",
                "styled_rows",
                "send_session_message",
                "receive_session_messages",
                "wait_for_session_message",
                "ack_session_messages",
                "list_worker_profiles",
                "create_worker_group",
                "list_worker_groups",
                "get_worker_group",
                "spawn_worker",
                "update_worker",
                "cleanup_worker_group",
            ]
        );
    }

    fn absolute_test_cwd() -> String {
        std::env::current_dir()
            .unwrap()
            .to_str()
            .unwrap()
            .to_string()
    }

    fn lifecycle_call<A: SessionApi>(
        server: &McpServer<A>,
        name: &str,
        arguments: Value,
    ) -> JsonRpcResponse {
        server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!("lifecycle")),
                method: "tools/call".to_string(),
                params: Some(json!({ "name": name, "arguments": arguments })),
            })
            .unwrap()
    }

    #[test]
    fn start_session_forwards_agent_executable_and_literal_arguments() {
        for command in ["agy", "claude", "muse", "codex"] {
            let server = McpServer::new(RecordingApi::new());
            let cwd = absolute_test_cwd();
            let args = vec![
                "review a path with spaces",
                "$(touch should-not-run)",
                "",
                "a'b\"c",
            ];
            let result = lifecycle_call(
                &server,
                "start_session",
                json!({
                    "command": command, "args": args, "cwd": cwd,
                    "rows": 40, "cols": 120,
                }),
            )
            .result
            .unwrap();
            assert_eq!(result["isError"], false);
            assert_eq!(
                result["structuredContent"],
                json!({ "session_id": "worker-1" })
            );
            assert_eq!(
                serde_json::from_str::<Value>(result["content"][0]["text"].as_str().unwrap())
                    .unwrap(),
                result["structuredContent"]
            );
            let starts = server.api.starts.borrow();
            assert_eq!(starts.len(), 1);
            assert_eq!(starts[0].command, command);
            assert_eq!(starts[0].args, args);
            assert_eq!(starts[0].cwd, Some(PathBuf::from(cwd)));
            assert_eq!(starts[0].size.rows, 40);
            assert_eq!(starts[0].size.cols, 120);
        }
    }

    #[test]
    fn start_session_defaults_options_and_does_not_fetch_snapshot_after_launch() {
        let mut api = RecordingApi::new();
        api.snapshot_error = Some("snapshot unavailable");
        let server = McpServer::new(api);
        let result = lifecycle_call(
            &server,
            "start_session",
            json!({
                "command": "worker", "cwd": absolute_test_cwd(),
            }),
        )
        .result
        .unwrap();
        assert_eq!(result["isError"], false);
        assert_eq!(result["structuredContent"]["session_id"], "worker-1");
        let starts = server.api.starts.borrow();
        assert!(starts[0].args.is_empty());
        assert_eq!(starts[0].size, SessionSize::default());
    }

    #[test]
    fn lifecycle_rejects_invalid_arguments_before_calling_daemon() {
        let cwd = absolute_test_cwd();
        let valid_start = json!({ "command": "worker", "cwd": cwd });
        let mut invalid_starts = vec![
            json!(null),
            json!([]),
            json!({}),
            json!({"command": "worker"}),
        ];
        for (field, value) in [
            ("command", json!(" ")),
            ("command", json!("wo\0rker")),
            ("command", json!(4)),
            ("cwd", json!("relative/path")),
            ("cwd", json!("")),
            ("cwd", json!(format!("{cwd}\0"))),
            ("cwd", json!(null)),
            ("args", json!("--flag")),
            ("args", json!([42])),
            ("args", json!(["arg\0"])),
            ("args", json!(null)),
            ("rows", json!(0)),
            ("cols", json!(65536)),
            ("rows", json!(-1)),
            ("cols", json!(1.5)),
            ("rows", json!("24")),
            ("extra", json!(true)),
        ] {
            let mut invalid = valid_start.clone();
            invalid[field] = value;
            invalid_starts.push(invalid);
        }
        let invalid_shutdowns = vec![
            json!(null),
            json!([]),
            json!({}),
            json!({"session_id": " "}),
            json!({"session_id": "../other"}),
            json!({"session_id": "a\0b"}),
            json!({"session_id": 42}),
            json!({"session_id": "worker-1", "extra": true}),
        ];
        let server = McpServer::new(RecordingApi::new());
        for (name, cases) in [
            ("start_session", invalid_starts),
            ("shutdown_session", invalid_shutdowns),
        ] {
            for arguments in cases {
                let response = lifecycle_call(&server, name, arguments.clone());
                assert_eq!(
                    response
                        .error
                        .unwrap_or_else(|| panic!("{name}: {arguments}"))
                        .code,
                    -32602
                );
                assert!(server.api.starts.borrow().is_empty());
                assert!(server.api.shutdowns.borrow().is_empty());
            }
        }
    }

    #[test]
    fn lifecycle_rejects_populated_positional_arrays() {
        let server = McpServer::new(RecordingApi::new());
        for (name, arguments) in [
            (
                "start_session",
                json!(["worker", [], absolute_test_cwd(), 24, 80]),
            ),
            ("shutdown_session", json!(["worker-7"])),
        ] {
            let response = lifecycle_call(&server, name, arguments);
            assert_eq!(
                response
                    .error
                    .expect("positional arrays must be rejected")
                    .code,
                -32602
            );
            assert!(server.api.starts.borrow().is_empty());
            assert!(server.api.shutdowns.borrow().is_empty());
        }
    }

    #[test]
    fn start_session_rejects_explicit_null_dimensions() {
        let server = McpServer::new(RecordingApi::new());
        for field in ["rows", "cols"] {
            let mut arguments = json!({"command": "worker", "cwd": absolute_test_cwd()});
            arguments[field] = Value::Null;
            let response = lifecycle_call(&server, "start_session", arguments);
            assert_eq!(
                response
                    .error
                    .expect("supplied dimensions must be integers")
                    .code,
                -32602
            );
            assert!(server.api.starts.borrow().is_empty());
        }
    }

    #[test]
    fn shutdown_session_targets_exact_id_and_returns_completed_output() {
        let server = McpServer::new(RecordingApi::new());
        let result = lifecycle_call(
            &server,
            "shutdown_session",
            json!({"session_id": "worker-7"}),
        )
        .result
        .unwrap();
        assert_eq!(result["isError"], false);
        assert_eq!(
            *server.api.shutdowns.borrow(),
            vec![SessionId::new("worker-7").unwrap()]
        );
        assert_eq!(
            result["structuredContent"],
            json!({
                "session_id": "worker-7",
                "completed": {"output_seq": 7, "bytes_logged": 12, "visible_rows": ["ready"]},
            })
        );
    }

    #[test]
    fn lifecycle_backend_failures_are_tool_errors() {
        for (name, arguments) in [
            (
                "start_session",
                json!({"command": "worker", "cwd": absolute_test_cwd()}),
            ),
            ("shutdown_session", json!({"session_id": "missing"})),
        ] {
            let mut api = RecordingApi::new();
            api.lifecycle_error = Some("backend refused request");
            let server = McpServer::new(api);
            let response = lifecycle_call(&server, name, arguments);
            assert!(response.error.is_none());
            let result = response.result.unwrap();
            assert_eq!(result["isError"], true);
            assert!(
                result["content"][0]["text"]
                    .as_str()
                    .unwrap()
                    .contains("backend refused request")
            );
            assert!(result.get("structuredContent").is_none());
        }
    }

    #[test]
    #[cfg(unix)]
    fn lifecycle_drives_real_pty_and_preserves_literal_argv() {
        use std::sync::Arc;
        use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
        use triaged::session::{SessionManager, SessionManagerConfig};

        struct IsolatedSessions {
            manager: Arc<SessionManager>,
            directory: PathBuf,
        }
        impl Drop for IsolatedSessions {
            fn drop(&mut self) {
                for session in self.manager.list_sessions().unwrap_or_default() {
                    let _ = self.manager.shutdown_session(session);
                }
                let _ = std::fs::remove_dir_all(&self.directory);
            }
        }

        let directory = std::env::temp_dir().join(format!(
            "triage-mcp-worker-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
        ));
        std::fs::create_dir(&directory).unwrap();
        let fixture = IsolatedSessions {
            manager: Arc::new(SessionManager::new(SessionManagerConfig::new(
                directory.join("logs"),
            ))),
            directory,
        };
        let cwd = fixture.directory.join("work tree");
        std::fs::create_dir(&cwd).unwrap();
        let cwd = cwd.canonicalize().unwrap();
        let server = McpServer::new(Arc::clone(&fixture.manager));
        let literal = "literal $(printf expanded) 'quotes'";
        let result = lifecycle_call(&server, "start_session", json!({
            "command": "/bin/sh",
            "args": ["-c", "printf '%s\\n' \"mcp-worker:$TRIAGE_SESSION_ID\" \"$PWD\" \"$1\"; cat", "worker", literal],
            "cwd": cwd,
            "rows": 30,
            "cols": 240,
        })).result.unwrap();
        assert_eq!(result["isError"], false, "{result}");
        let session =
            SessionId::new(result["structuredContent"]["session_id"].as_str().unwrap()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let snapshot = server.api.snapshot_session(session.clone()).unwrap();
            let output = snapshot.visible_rows.join("\n");
            if output.contains(literal)
                && output.contains(&format!("mcp-worker:{session}"))
                && output.contains(cwd.to_str().unwrap())
            {
                assert_eq!(snapshot.size.rows, 30);
                assert_eq!(snapshot.size.cols, 240);
                break;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for worker output: {output}"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        let sent = lifecycle_call(
            &server,
            "send_session_message",
            json!({
                "from_session_id": session, "to_session_id": session, "body": "assignment",
            }),
        )
        .result
        .unwrap();
        assert_eq!(sent["isError"], false);
        let mail = lifecycle_call(
            &server,
            "receive_session_messages",
            json!({"session_id": session}),
        )
        .result
        .unwrap();
        assert_eq!(
            mail["structuredContent"]["messages"][0]["body"],
            "assignment"
        );
        let stopped = lifecycle_call(&server, "shutdown_session", json!({"session_id": session}))
            .result
            .unwrap();
        assert_eq!(stopped["isError"], false, "{stopped}");
        assert_eq!(stopped["structuredContent"]["session_id"], session.as_str());
        assert!(server.api.list_sessions().unwrap().is_empty());
        let repeated = lifecycle_call(&server, "shutdown_session", json!({"session_id": session}))
            .result
            .unwrap();
        assert_eq!(repeated["isError"], true);
    }

    #[test]
    fn lifecycle_tools_advertise_mutation_and_non_idempotency() {
        let tools = tool_definitions();
        for name in ["start_session", "shutdown_session"] {
            let tool = tools
                .as_array()
                .unwrap()
                .iter()
                .find(|tool| tool["name"] == name)
                .unwrap();
            assert_eq!(tool["annotations"]["readOnlyHint"], false);
            assert_eq!(tool["annotations"]["destructiveHint"], true);
            assert_eq!(tool["annotations"]["idempotentHint"], false);
            assert_eq!(tool["inputSchema"]["additionalProperties"], false);
        }
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
        // No label set: null, not missing.
        assert_eq!(
            result["structuredContent"]["sessions"][0]["custom_label"],
            Value::Null
        );
    }

    #[test]
    fn list_sessions_includes_custom_labels() {
        let server = McpServer::new(RecordingApi::new().with_label("session-1", "Dev Server"));

        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!("call-label")),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "list_sessions",
                    "arguments": {}
                })),
            })
            .expect("response");

        let result = response.result.unwrap();
        assert_eq!(
            result["structuredContent"]["sessions"][0]["custom_label"],
            "Dev Server"
        );
    }

    #[test]
    fn list_sessions_survives_layout_failure() {
        let server = McpServer::new(RecordingApi::new().with_layout_error());

        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!("call-layout-fail")),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "list_sessions",
                    "arguments": {}
                })),
            })
            .expect("response");

        // Labels are enrichment: the read degrades to unlabeled sessions
        // rather than failing the whole tool.
        let result = response.result.unwrap();
        assert_eq!(result["isError"], false);
        assert_eq!(
            result["structuredContent"]["sessions"][0]["id"],
            "session-1"
        );
        assert_eq!(
            result["structuredContent"]["sessions"][0]["custom_label"],
            Value::Null
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

    fn call_tool(server: &McpServer<RecordingApi>, name: &str, arguments: Value) -> Value {
        server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!(name)),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": name,
                    "arguments": arguments
                })),
            })
            .expect("response")
            .result
            .expect("result")
    }

    #[test]
    fn session_messaging_tools_round_trip_through_dispatch() {
        let server = McpServer::new(RecordingApi::new());

        let sent = call_tool(
            &server,
            "send_session_message",
            json!({
                "from_session_id": "session-1",
                "to_session_id": "session-2",
                "body": "handoff: build is green",
                "wake": true
            }),
        );
        assert_eq!(sent["isError"], false);
        assert_eq!(sent["structuredContent"]["message_id"], 1);
        assert_eq!(sent["structuredContent"]["woke"], true);

        let waited = call_tool(
            &server,
            "wait_for_session_message",
            json!({ "session_id": "session-2", "timeout_ms": 1000 }),
        );
        assert_eq!(
            waited["structuredContent"]["messages"]
                .as_array()
                .unwrap()
                .len(),
            1
        );

        // Peek: unacked mail redelivers.
        for _ in 0..2 {
            let received = call_tool(
                &server,
                "receive_session_messages",
                json!({ "session_id": "session-2" }),
            );
            let messages = received["structuredContent"]["messages"]
                .as_array()
                .unwrap();
            assert_eq!(messages.len(), 1);
            assert_eq!(messages[0]["id"], 1);
            assert_eq!(messages[0]["from_session_id"], "session-1");
            assert_eq!(messages[0]["body"], "handoff: build is green");
            assert_eq!(messages[0]["sent_at_ms"], 1_700_000_000_000u64);
        }

        let acked = call_tool(
            &server,
            "ack_session_messages",
            json!({ "session_id": "session-2", "message_ids": [1] }),
        );
        assert_eq!(acked["structuredContent"]["ok"], true);

        let received = call_tool(
            &server,
            "receive_session_messages",
            json!({ "session_id": "session-2" }),
        );
        assert_eq!(
            received["structuredContent"]["messages"]
                .as_array()
                .unwrap()
                .len(),
            0
        );
    }

    #[test]
    fn session_messaging_tools_validate_arguments() {
        let server = McpServer::new(RecordingApi::new());

        // Missing body.
        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!(1)),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "send_session_message",
                    "arguments": {
                        "from_session_id": "session-1",
                        "to_session_id": "session-2"
                    }
                })),
            })
            .expect("response");
        let error = response.error.expect("error");
        assert_eq!(error.code, -32602);
        assert!(error.message.contains("body"));

        // Non-array message_ids.
        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!(2)),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "ack_session_messages",
                    "arguments": {
                        "session_id": "session-2",
                        "message_ids": "1"
                    }
                })),
            })
            .expect("response");
        let error = response.error.expect("error");
        assert_eq!(error.code, -32602);
        assert!(error.message.contains("message_ids"));

        // Non-integer message id.
        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!(3)),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "ack_session_messages",
                    "arguments": {
                        "session_id": "session-2",
                        "message_ids": [1, "two"]
                    }
                })),
            })
            .expect("response");
        let error = response.error.expect("error");
        assert_eq!(error.code, -32602);
        assert!(error.message.contains("message_ids"));

        // Missing session_id on receive.
        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!(4)),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "receive_session_messages",
                    "arguments": {}
                })),
            })
            .expect("response");
        let error = response.error.expect("error");
        assert_eq!(error.code, -32602);
        assert!(error.message.contains("session_id"));

        // Invalid wake type on send.
        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!(5)),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "send_session_message",
                    "arguments": {
                        "from_session_id": "session-1",
                        "to_session_id": "session-2",
                        "body": "hello",
                        "wake": "yes"
                    }
                })),
            })
            .expect("response");
        let error = response.error.expect("error");
        assert_eq!(error.code, -32602);
        assert!(error.message.contains("wake"));

        // Oversize timeout_ms on wait_for_session_message.
        let response = server
            .handle(JsonRpcRequest {
                id: JsonRpcId::Request(json!(6)),
                method: "tools/call".to_string(),
                params: Some(json!({
                    "name": "wait_for_session_message",
                    "arguments": {
                        "session_id": "session-2",
                        "timeout_ms": SESSION_MESSAGE_MAX_WAIT_TIMEOUT_MS + 1
                    }
                })),
            })
            .expect("response");
        let error = response.error.expect("error");
        assert_eq!(error.code, -32602);
        assert!(error.message.contains("timeout_ms"));
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
    #[test]
    fn stdio_rejects_positional_lifecycle_envelopes() {
        let api = RecordingApi::new();
        let launch = json!({"name": "start_session", "arguments": {"command": "worker", "cwd": absolute_test_cwd()}});
        let shutdown = json!({"name": "shutdown_session", "arguments": {"session_id": "worker-1"}});
        let input = format!(
            "{}\n{}\n",
            json!(["launch", "tools/call", launch.clone()]),
            json!(["stop", "tools/call", shutdown.clone()]),
        );
        let mut output = Vec::new();
        run_stdio_with_client(api.clone(), std::io::Cursor::new(input), &mut output).unwrap();
        assert!(
            api.starts.borrow().is_empty(),
            "a positional envelope launched a worker"
        );
        assert!(
            api.shutdowns.borrow().is_empty(),
            "a positional envelope stopped a worker"
        );
        let responses = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(responses.len(), 2);
        for response in responses {
            assert_eq!(response["error"]["code"], -32600);
            assert_eq!(response["id"], Value::Null);
        }
        let valid = format!(
            "{}\n{}\n",
            json!({"jsonrpc": "2.0", "id": "launch", "method": "tools/call", "params": launch}),
            json!({"jsonrpc": "2.0", "id": "stop", "method": "tools/call", "params": shutdown}),
        );
        let mut output = Vec::new();
        run_stdio_with_client(api.clone(), std::io::Cursor::new(valid), &mut output).unwrap();
        assert_eq!(api.starts.borrow().len(), 1);
        assert_eq!(api.shutdowns.borrow().len(), 1);
        let responses = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(responses.len(), 2);
        for response in responses {
            assert_eq!(response["result"]["isError"], false);
        }
    }
}
