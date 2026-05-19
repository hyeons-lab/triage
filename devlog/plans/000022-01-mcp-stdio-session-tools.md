## Thinking

The daemon already owns session state and exposes the shared API through `UnixSocketClient`. The first MCP slice should avoid a second transport-specific session model. A small stdio server can speak the MCP JSON-RPC lifecycle and translate tool calls into `SessionApi` calls over the local Unix socket.

Write/input tools should wait until the read-only bridge is validated because they need clear lease behavior and approval semantics. The useful first surface is discovery and output inspection: list sessions, fetch a snapshot, and fetch styled rows for a visible range.

## Plan

1. Add `argus-mcp` dependencies on `argus-core`, `argus-daemon`, `anyhow`, `serde`, and `serde_json`.
2. Implement a newline-delimited JSON-RPC stdio loop with handlers for `initialize`, `notifications/initialized`, `tools/list`, and `tools/call`.
3. Add read-only tools backed by `UnixSocketClient`: `list_sessions`, `snapshot_session`, and `styled_rows`.
4. Add unit coverage for request dispatch and tool argument validation.
5. Run formatting and focused validation before updating the branch devlog.
