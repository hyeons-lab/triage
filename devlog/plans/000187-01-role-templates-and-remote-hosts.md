# Plan 000187-01: Markdown Role Templates and Remote Host Delegation

## Thinking

- `triage-mcp` currently requires callers to spell out raw `command`, literal `args`, and `cwd` on every `start_session` call, and assumes all workers run on the single local `triaged` Unix socket / named pipe.
- Role templates stored as plain Markdown files with minimal YAML-like frontmatter (`command`, `args`, `cwd`, `outlive_parent`, `task_flag`, plus body prompt with optional `{{task}}` / `{task}`) keep worker definitions versionable and readable without pulling in a full YAML engine.
- For cross-host delegation, `triaged` already exposes an HTTP/WS listener protected by `manager.authenticate(&client_id, token)` (`Authorization: Bearer <token>` + `X-Triage-Client-Id`), and `triaged::ipc` already defines `WireRequest` / `WireResponse` covering every `SessionApi` call including `WaitForSessions` and session inbox messaging. Exposing `POST /rpc` on `triaged`'s HTTP server lets any paired remote `triage-mcp` instance route all session/inbox/wait tools to another host over the same paired credentials.

## Plan

1. Expose `pub enum WireRequest` / `WireResponse` helper `handle_wire_request_json` from `crates/triaged/src/ipc.rs` for synchronous RPC calls, and add `POST /rpc` to `crates/triaged/src/http.rs` using `tokio::task::spawn_blocking` and the existing pairing auth checks.
2. Create `crates/triage-mcp/src/templates.rs` supporting `$TRIAGE_TEMPLATES_DIR`, `$XDG_CONFIG_HOME/triage/templates`, and `~/.config/triage/templates` `.md` role files, and wire `list_templates` plus optional `template` / `task` fields into `start_session`.
3. Create `crates/triage-mcp/src/hosts.rs` parsing `$TRIAGE_HOSTS_PATH`, `$XDG_CONFIG_HOME/triage/hosts.toml`, and `~/.config/triage/hosts.toml`, add `list_hosts`, implement a `SessionApi` HTTP `/rpc` client using `reqwest::blocking` (or existing workspace HTTP deps), and route optional `host` arguments in `McpServer::call_tool`.
4. Add unit and integration tests for template parsing/resolution, `/rpc` HTTP auth & round-trip, `hosts.toml` parsing, `list_hosts`, `list_templates`, and `host` dispatch in `triage-mcp`, then run formatting, clippy, and workspace tests.
