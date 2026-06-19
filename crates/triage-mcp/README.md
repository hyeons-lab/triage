# triage-mcp

Model Context Protocol (MCP) server for **Triage**, exposing terminal session context and supervisor controls to local AI agents (such as Claude Desktop, Cursor, etc.).

## Installation

```bash
cargo install triage-mcp
```

## Prerequisite: a running daemon

`triage-mcp` is a thin client — it connects to the `triaged` daemon over the
local control transport (a Unix domain socket on macOS/Linux, a named pipe on
Windows). Make sure the daemon is running first, either in the foreground
(`triaged`) or as a per-user login service (`triaged service install`). See the
[`triaged`](https://crates.io/crates/triaged) docs for details.

## Setup Configuration

Add the following configuration block to your local Claude Desktop config (e.g. `~/AppData/Roaming/Claude/claude_desktop_config.json` on Windows):

```json
{
  "mcpServers": {
    "triage": {
      "command": "triage-mcp"
    }
  }
}
```

## Available Tools

*   `list_sessions`: List active Triage terminal sessions.
*   `create_session`: Spawn a new PTY session.
*   `write_session_input`: Inject keyboard inputs.
*   `get_session_scrollback`: Retrieve formatted terminal content.
