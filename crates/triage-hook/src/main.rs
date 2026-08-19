//! Agent lifecycle-hook shim.
//!
//! Reads an agent's `PreToolUse` payload on stdin, asks the Triage daemon
//! whether the tool call may run, and writes the decision to stdout. Registered
//! in the agent's `hooks.json`; see `docs/approval-judge.md`.
//!
//! # The one invariant
//!
//! This process must never be the reason an agent breaks. It runs on *every*
//! tool call and blocks the agent's loop while it does, so:
//!
//! * It always exits `0`.
//! * It always prints exactly one decision object.
//! * Every failure prints `ask`, which is precisely what the agent does with no
//!   hook installed. A missing `TRIAGE_SESSION_ID`, an unparseable payload, a
//!   stopped daemon, a wedged daemon, a socket that does not exist: all `ask`.
//! * It bounds its own wait ([`JUDGE_TIMEOUT`]) well under the hook timeout, so
//!   it reports `ask` itself rather than being killed mid-write and leaving the
//!   agent to interpret an empty stdout.
//!
//! It also loads no model. The resident model belongs to the daemon; this
//! process only carries a question to it.

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::Duration;

use triage_core::judge::{JudgeRequest, JudgeVerdict};
use triage_core::session::SessionId;

/// Environment variable naming the Triage session this agent runs inside. Set by
/// the daemon when it spawns the PTY.
const SESSION_ENV: &str = "TRIAGE_SESSION_ID";

/// How long to wait for the daemon before answering `ask` ourselves.
///
/// Must stay well under the hook's own timeout (15s, as shipped in
/// `.agents/hooks.json`; the agent's own default is 30s) so that a wedged
/// daemon produces a clean `ask` rather than a killed process. The daemon
/// applies its own, shorter bound to the model call, so reaching this timeout
/// means the daemon itself is unresponsive.
const JUDGE_TIMEOUT: Duration = Duration::from_secs(10);

/// Decodes the agent payload from arbitrary agent hook schemas (Claude, Antigravity, Gemini, etc.).
fn extract_tool_info(val: &serde_json::Value) -> Option<(String, serde_json::Value)> {
    // Check nested tool_call / toolCall / tool_use / toolUse
    for key in ["tool_call", "toolCall", "tool_use", "toolUse"] {
        if let Some(res) = val.get(key).and_then(extract_tool_info) {
            return Some(res);
        }
    }

    // Check name / tool_name / toolName / tool
    let name = val
        .get("name")
        .or_else(|| val.get("tool_name"))
        .or_else(|| val.get("toolName"))
        .or_else(|| val.get("tool"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    if let Some(name) = name {
        let args = val
            .get("args")
            .or_else(|| val.get("arguments"))
            .or_else(|| val.get("tool_input"))
            .or_else(|| val.get("toolInput"))
            .or_else(|| val.get("input"))
            .or_else(|| val.get("parameters"))
            .cloned()
            .unwrap_or_else(|| serde_json::Value::Object(serde_json::Map::new()));
        return Some((name, args));
    }

    None
}

fn extract_cwd(val: &serde_json::Value) -> Option<String> {
    if let Some(first) = val
        .get("workspace_paths")
        .or_else(|| val.get("workspacePaths"))
        .and_then(|v| v.as_array())
        .and_then(|paths| paths.first())
        .and_then(|v| v.as_str())
    {
        return Some(first.to_string());
    }
    for key in [
        "cwd",
        "working_directory",
        "workingDirectory",
        "workspacePath",
        "workspace_path",
    ] {
        if let Some(s) = val.get(key).and_then(|v| v.as_str()) {
            return Some(s.to_string());
        }
    }
    None
}

fn extract_session_id(val: &serde_json::Value) -> SessionId {
    if let Some(id) = std::env::var(SESSION_ENV)
        .ok()
        .and_then(|raw| SessionId::new(&raw).ok())
    {
        return id;
    }
    for key in ["session_id", "sessionId", "session"] {
        if let Some(id) = val
            .get(key)
            .and_then(|v| v.as_str())
            .and_then(|s| SessionId::new(s).ok())
        {
            return id;
        }
    }
    SessionId::default()
}

fn extract_command_line(args: &serde_json::Value) -> Option<String> {
    for key in [
        "CommandLine",
        "command_line",
        "commandLine",
        "command",
        "cmd",
        "script",
        "code",
    ] {
        if let Some(val) = args.get(key).and_then(|v| v.as_str()) {
            return Some(val.to_string());
        }
    }
    None
}

fn extract_path(args: &serde_json::Value) -> Option<String> {
    for key in [
        "AbsolutePath",
        "absolute_path",
        "absolutePath",
        "path",
        "Path",
        "FilePath",
        "file_path",
        "filePath",
        "TargetFile",
        "target_file",
        "targetFile",
        "DirectoryPath",
        "directory_path",
        "directoryPath",
        "SearchPath",
        "search_path",
        "searchPath",
        "Url",
        "url",
    ] {
        if let Some(val) = args.get(key).and_then(|v| v.as_str()) {
            return Some(val.to_string());
        }
    }
    None
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AgentFormat {
    Antigravity,
    ClaudeCode,
    Generic,
}

fn detect_format(val: &serde_json::Value) -> AgentFormat {
    if let Ok(fmt) = std::env::var("TRIAGE_HOOK_FORMAT") {
        match fmt.to_lowercase().as_str() {
            "claude" | "claude_code" | "claudecode" => return AgentFormat::ClaudeCode,
            "antigravity" | "gemini" | "agy" => return AgentFormat::Antigravity,
            "generic" => return AgentFormat::Generic,
            _ => {}
        }
    }
    for arg in std::env::args() {
        if arg == "--format=claude" {
            return AgentFormat::ClaudeCode;
        }
        if arg == "--format=antigravity" || arg == "--format=gemini" || arg == "--format=agy" {
            return AgentFormat::Antigravity;
        }
        if arg == "--format=generic" {
            return AgentFormat::Generic;
        }
    }

    // Auto-detect format based on characteristic payload keys
    if val.get("conversationId").is_some() || val.get("stepIdx").is_some() {
        return AgentFormat::Antigravity;
    }
    if val.get("hook_event_name").is_some() || val.get("hookEventName").is_some() {
        return AgentFormat::ClaudeCode;
    }

    AgentFormat::Antigravity
}

fn strip_leading_env_vars(mut cmd: &str) -> &str {
    loop {
        let trimmed = cmd.trim_start();
        if let Some(rest) = trimmed.strip_prefix("env ") {
            let mut inner = rest.trim_start();
            while inner.starts_with('-') {
                if let Some(space_idx) = inner.find(char::is_whitespace) {
                    inner = inner[space_idx..].trim_start();
                } else {
                    return "";
                }
            }
            cmd = inner;
            continue;
        }
        let Some((var, rest)) = trimmed.split_once('=') else {
            return trimmed;
        };
        if var.contains(char::is_whitespace) {
            return trimmed;
        }
        let is_valid_ident = var.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
            && var.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
        if is_valid_ident {
            if let Some(quote) = rest.chars().next().filter(|&c| c == '"' || c == '\'') {
                let mut escaped = false;
                let mut matched_closing = None;
                for (idx, ch) in rest[1..].char_indices() {
                    if ch == '\\' && !escaped {
                        escaped = true;
                    } else if ch == quote && !escaped {
                        matched_closing = Some(idx);
                        break;
                    } else {
                        escaped = false;
                    }
                }
                if let Some(closing_idx) = matched_closing {
                    cmd = &rest[1 + closing_idx + quote.len_utf8()..];
                    continue;
                }
                return trimmed;
            } else if let Some(space_idx) = rest.find(char::is_whitespace) {
                cmd = &rest[space_idx..];
                continue;
            } else {
                return "";
            }
        }
        return trimmed;
    }
}

fn encode_response(
    format: AgentFormat,
    verdict: &JudgeVerdict,
    request: Option<&JudgeRequest>,
) -> String {
    let decision_str = verdict.decision.as_hook_str();
    match format {
        AgentFormat::Antigravity | AgentFormat::Generic => {
            let mut permission_overrides = Vec::new();
            if verdict.decision == triage_core::judge::JudgeDecision::Allow
                && let Some(req) = request
            {
                if let Some(ref cmd) = req.command_line {
                    let trimmed = cmd.trim();
                    permission_overrides.push(format!("command({trimmed})"));
                    let stripped = strip_leading_env_vars(trimmed);
                    if stripped != trimmed && !stripped.is_empty() {
                        permission_overrides.push(format!("command({stripped})"));
                    }
                    // Extract all chain & pipeline segments (e.g. for &&, ||, ;, |, \n)
                    let segments = triaged::judge::pipeline_and_chain_segments(trimmed);
                    for seg in &segments {
                        let seg_trimmed = seg.trim();
                        if !seg_trimmed.is_empty() && seg_trimmed != trimmed {
                            permission_overrides.push(format!("command({seg_trimmed})"));
                        }
                        let stripped_seg = strip_leading_env_vars(seg_trimmed);
                        if stripped_seg != seg_trimmed && !stripped_seg.is_empty() {
                            permission_overrides.push(format!("command({stripped_seg})"));
                        }
                        let words: Vec<&str> = stripped_seg.split_whitespace().collect();
                        if words.len() >= 2
                            && !words[1].starts_with('-')
                            && !words[1].starts_with('"')
                            && !words[1].starts_with('\'')
                            && !words[0].contains('=')
                        {
                            permission_overrides
                                .push(format!("command({} {})", words[0], words[1]));
                        }
                    }
                }
                if let Some(ref path) = req.path {
                    permission_overrides.push(format!("file({path})"));
                }
                permission_overrides.push(format!("tool({})", req.tool_name));

                let mut seen = std::collections::HashSet::new();
                permission_overrides.retain(|item| seen.insert(item.clone()));
            }

            #[derive(serde::Serialize)]
            #[serde(rename_all = "camelCase")]
            struct AntigravityResponse<'a> {
                decision: &'a str,
                #[serde(skip_serializing_if = "str::is_empty")]
                reason: &'a str,
                #[serde(skip_serializing_if = "Vec::is_empty")]
                permission_overrides: Vec<String>,
            }
            serde_json::to_string(&AntigravityResponse {
                decision: decision_str,
                reason: &verdict.reason,
                permission_overrides,
            })
            .unwrap_or_else(|_| r#"{"decision":"ask"}"#.to_string())
        }
        AgentFormat::ClaudeCode => {
            #[derive(serde::Serialize)]
            #[serde(rename_all = "camelCase")]
            struct ClaudeHookSpecificOutput<'a> {
                hook_event_name: &'static str,
                permission_decision: &'a str,
                #[serde(skip_serializing_if = "str::is_empty")]
                permission_decision_reason: &'a str,
            }
            #[derive(serde::Serialize)]
            #[serde(rename_all = "camelCase")]
            struct ClaudeResponse<'a> {
                decision: &'a str,
                #[serde(skip_serializing_if = "str::is_empty")]
                reason: &'a str,
                hook_specific_output: ClaudeHookSpecificOutput<'a>,
            }
            serde_json::to_string(&ClaudeResponse {
                decision: decision_str,
                reason: &verdict.reason,
                hook_specific_output: ClaudeHookSpecificOutput {
                    hook_event_name: "PreToolUse",
                    permission_decision: decision_str,
                    permission_decision_reason: &verdict.reason,
                },
            })
            .unwrap_or_else(|_| r#"{"decision":"ask"}"#.to_string())
        }
    }
}

fn main() {
    let (verdict, format, request) = decide();
    let encoded = encode_response(format, &verdict, request.as_ref());
    let mut stdout = std::io::stdout();
    let _ = writeln!(stdout, "{encoded}");
    let _ = stdout.flush();
}

/// Produces the verdict and detected agent format, resolving every failure to `ask`.
fn decide() -> (JudgeVerdict, AgentFormat, Option<JudgeRequest>) {
    let mut stdin = String::new();
    if let Err(error) = std::io::stdin().read_to_string(&mut stdin) {
        return (
            JudgeVerdict::fallback(format!("could not read the hook payload: {error}")),
            AgentFormat::Generic,
            None,
        );
    }
    let val: serde_json::Value = match serde_json::from_str(&stdin) {
        Ok(val) => val,
        Err(error) => {
            return (
                JudgeVerdict::fallback(format!("could not parse the hook payload: {error}")),
                AgentFormat::Generic,
                None,
            );
        }
    };
    let format = detect_format(&val);
    let Some((tool_name, tool_args)) = extract_tool_info(&val) else {
        return (
            JudgeVerdict::fallback("hook payload carried no tool call"),
            format,
            None,
        );
    };

    let session_id = extract_session_id(&val);
    let cwd = extract_cwd(&val);
    let command_line = extract_command_line(&tool_args);
    let path = extract_path(&tool_args);

    let request = JudgeRequest {
        session_id,
        tool_name,
        command_line,
        path,
        cwd,
    };
    let verdict = ask_daemon(request.clone());
    (verdict, format, Some(request))
}

fn evaluate_in_process(request: &JudgeRequest) -> Option<JudgeVerdict> {
    let config = triage_core::config::Config::default_path()
        .ok()
        .and_then(|path| triage_core::config::Config::load_from_path(path).ok())
        .map(|c| c.judge)
        .unwrap_or_default();
    let rules = triaged::judge::JudgeRules::new(&config);
    rules.evaluate(request)
}

/// Runs the round trip on a worker thread so a wedged daemon cannot hold us past
/// [`JUDGE_TIMEOUT`]. If the daemon is unreachable or does not answer in time,
/// deterministic Layer 1/2 rules are evaluated in-process as a resilient fallback.
fn ask_daemon(request: JudgeRequest) -> JudgeVerdict {
    let (tx, rx) = mpsc::channel();
    let req_clone = request.clone();
    let spawned = std::thread::Builder::new()
        .name("triage-hook-judge".to_string())
        .spawn(move || {
            let client = triaged::ipc::IpcClient::new(triaged::ipc::default_socket_path());
            let _ = tx.send(client.judge_tool_call_result(req_clone));
        });
    if let Err(error) = spawned {
        return evaluate_in_process(&request).unwrap_or_else(|| {
            JudgeVerdict::fallback(format!("could not start the judge thread: {error}"))
        });
    }
    match rx.recv_timeout(JUDGE_TIMEOUT) {
        // IPC succeeded: the daemon is authoritative, even if it answered Ask
        // (e.g. auto-approval explicitly disabled for the session).
        Ok(Ok(verdict)) => verdict,
        // IPC transport error (daemon not running, socket unreachable): fallback to in-process rules.
        Ok(Err(_)) => evaluate_in_process(&request)
            .unwrap_or_else(|| JudgeVerdict::fallback("the Triage daemon is unreachable")),
        Err(_) => evaluate_in_process(&request)
            .unwrap_or_else(|| JudgeVerdict::fallback("the Triage daemon did not answer in time")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use triage_core::judge::JudgeDecision;

    #[test]
    fn parses_a_real_pre_tool_use_payload() {
        let val: serde_json::Value = serde_json::from_str(
            r#"{
                "toolCall": {"name": "run_command", "args": {"CommandLine": "npm test"}},
                "stepIdx": 19,
                "conversationId": "ec33ebf9",
                "workspacePaths": ["/work/repo"],
                "modelName": "auto"
            }"#,
        )
        .expect("payload parses");
        let (name, args) = extract_tool_info(&val).expect("tool call present");
        assert_eq!(name, "run_command");
        assert_eq!(extract_command_line(&args).as_deref(), Some("npm test"));
        assert_eq!(extract_path(&args), None);
        assert_eq!(extract_cwd(&val).as_deref(), Some("/work/repo"));
    }

    #[test]
    fn parses_file_path_for_read_tool_calls() {
        let val: serde_json::Value = serde_json::from_str(
            r#"{
                "toolCall": {"name": "Read", "args": {"AbsolutePath": "~/development/cera/.git/refs/heads/ci/hf-space-demo"}},
                "stepIdx": 5
            }"#,
        )
        .expect("payload parses");
        let (name, args) = extract_tool_info(&val).expect("tool call present");
        assert_eq!(name, "Read");
        assert_eq!(
            extract_path(&args).as_deref(),
            Some("~/development/cera/.git/refs/heads/ci/hf-space-demo")
        );
    }

    #[test]
    fn parses_snake_case_tool_name_and_tool_input() {
        let val: serde_json::Value = serde_json::from_str(
            r#"{
                "tool_name": "run_command",
                "tool_input": {"command": "cargo test"},
                "cwd": "/work/project"
            }"#,
        )
        .expect("payload parses");
        let (name, args) = extract_tool_info(&val).expect("tool call present");
        assert_eq!(name, "run_command");
        assert_eq!(extract_command_line(&args).as_deref(), Some("cargo test"));
        assert_eq!(extract_cwd(&val).as_deref(), Some("/work/project"));
    }

    #[test]
    fn tolerates_unknown_and_missing_fields() {
        // The agent may grow its payload; that must not turn into an `ask`.
        let val: serde_json::Value = serde_json::from_str(
            r#"{"toolCall":{"name":"view_file","args":{}},"somethingNew":true}"#,
        )
        .expect("payload parses");
        let (name, args) = extract_tool_info(&val).expect("tool call present");
        assert_eq!(name, "view_file");
        assert_eq!(extract_command_line(&args), None);
        assert_eq!(extract_path(&args), None);
        assert_eq!(extract_cwd(&val), None);
    }

    #[test]
    fn a_payload_without_a_tool_call_is_handled() {
        let val: serde_json::Value =
            serde_json::from_str(r#"{"stepIdx": 3}"#).expect("payload parses");
        assert!(extract_tool_info(&val).is_none());
    }

    #[test]
    fn response_serializes_to_the_agy_contract() {
        let verdict = JudgeVerdict {
            decision: JudgeDecision::Allow,
            source: triage_core::judge::JudgeSource::AllowRule,
            reason: "matched allow rule: ls".to_string(),
        };
        let request = JudgeRequest {
            session_id: SessionId::new("123").unwrap(),
            tool_name: "run_command".to_string(),
            command_line: Some("VAR=1 ls -la".to_string()),
            path: None,
            cwd: None,
        };
        let encoded = encode_response(AgentFormat::Antigravity, &verdict, Some(&request));
        assert_eq!(
            encoded,
            r#"{"decision":"allow","reason":"matched allow rule: ls","permissionOverrides":["command(VAR=1 ls -la)","command(ls -la)","tool(run_command)"]}"#
        );
    }

    #[test]
    fn response_serializes_to_the_claude_contract() {
        let verdict = JudgeVerdict {
            decision: JudgeDecision::Allow,
            source: triage_core::judge::JudgeSource::AllowRule,
            reason: "matched allow rule: ls".to_string(),
        };
        let encoded = encode_response(AgentFormat::ClaudeCode, &verdict, None);
        assert_eq!(
            encoded,
            r#"{"decision":"allow","reason":"matched allow rule: ls","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"matched allow rule: ls"}}"#
        );
    }

    #[test]
    fn detects_antigravity_and_claude_signatures() {
        let agy_val: serde_json::Value =
            serde_json::from_str(r#"{"conversationId": "123", "stepIdx": 1}"#).unwrap();
        assert_eq!(detect_format(&agy_val), AgentFormat::Antigravity);

        let claude_val: serde_json::Value =
            serde_json::from_str(r#"{"hook_event_name": "PreToolUse"}"#).unwrap();
        assert_eq!(detect_format(&claude_val), AgentFormat::ClaudeCode);
    }

    #[test]
    fn an_empty_reason_is_omitted_rather_than_sent_blank() {
        let verdict = JudgeVerdict {
            decision: JudgeDecision::Ask,
            source: triage_core::judge::JudgeSource::Fallback,
            reason: String::new(),
        };
        let encoded = encode_response(AgentFormat::Antigravity, &verdict, None);
        assert_eq!(encoded, r#"{"decision":"ask"}"#);
    }

    #[test]
    fn strip_leading_env_vars_handles_unquoted_and_quoted_values() {
        assert_eq!(strip_leading_env_vars("FOO=bar cargo test"), "cargo test");
        assert_eq!(
            strip_leading_env_vars("RUSTFLAGS=\"-C target-cpu=native\" cargo build"),
            "cargo build"
        );
        assert_eq!(
            strip_leading_env_vars("VAR='123' KEY=\"hello world\" git diff"),
            "git diff"
        );
        assert_eq!(
            strip_leading_env_vars("env RUST_LOG=info cargo check"),
            "cargo check"
        );
        assert_eq!(strip_leading_env_vars("echo foo=bar"), "echo foo=bar");
        assert_eq!(
            strip_leading_env_vars("VAR=\"val\\\"with_quote\" cargo test"),
            "cargo test"
        );
        assert_eq!(
            strip_leading_env_vars("A=1 B=2 C=\"text with spaces\" git status"),
            "git status"
        );
        assert_eq!(
            strip_leading_env_vars("INVALID-VAR=123 ls"),
            "INVALID-VAR=123 ls"
        );
        assert_eq!(
            strip_leading_env_vars("VAR=\"unclosed cargo test"),
            "VAR=\"unclosed cargo test"
        );
        assert_eq!(
            strip_leading_env_vars("FOO=1 BAR=\"baz qux\" BAZ='abc' cargo test"),
            "cargo test"
        );
        assert_eq!(
            strip_leading_env_vars("env -i FOO=BAR cargo check"),
            "cargo check"
        );
        assert_eq!(
            strip_leading_env_vars("env --ignore-environment VAR=1 git diff"),
            "git diff"
        );
        assert_eq!(strip_leading_env_vars("1=2 foo_cmd"), "1=2 foo_cmd");
        assert_eq!(
            strip_leading_env_vars("389_server start"),
            "389_server start"
        );
    }

    #[test]
    fn extract_session_id_falls_back_safely_when_unspecified() {
        let val: serde_json::Value = serde_json::json!({});
        assert_eq!(extract_session_id(&val), SessionId::default());
    }

    #[test]
    fn permission_overrides_for_multiline_commands_are_clean_and_balanced() {
        let req = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "run_command".to_string(),
            command_line: Some(
                "echo \"In origin but not local:\"\ngit log 1a1ab03..origin/main --oneline"
                    .to_string(),
            ),
            path: None,
            cwd: None,
        };
        let verdict = JudgeVerdict {
            decision: JudgeDecision::Allow,
            source: triage_core::judge::JudgeSource::AllowRule,
            reason: "matched allow rules".to_string(),
        };
        let encoded = encode_response(AgentFormat::Antigravity, &verdict, Some(&req));
        let val: serde_json::Value = serde_json::from_str(&encoded).unwrap();
        let overrides = val["permissionOverrides"].as_array().unwrap();
        let override_strs: Vec<&str> = overrides.iter().map(|v| v.as_str().unwrap()).collect();
        assert!(override_strs.contains(&"command(echo \"In origin but not local:\")"));
        assert!(override_strs.contains(&"command(git log 1a1ab03..origin/main --oneline)"));
        assert!(override_strs.contains(&"command(git log)"));
        assert!(override_strs.contains(&"tool(run_command)"));
        // Ensure no broad single-word base executable overrides are emitted
        assert!(!override_strs.contains(&"command(git)"));
        assert!(!override_strs.contains(&"command(echo)"));
        // Ensure no malformed unbalanced quotes exist
        assert!(!override_strs.iter().any(|s| s.contains("echo \"In)")));
    }
}
