# triage-mcp

Model Context Protocol (MCP) server for **Triage**, exposing terminal session context to local AI agents (such as Claude Code, Claude Desktop, or Cursor).

It lets an agent *read* what is happening in your terminals — which sessions exist, what is on screen, and how it is styled — so it can reason about a build, a test run, or a stuck prompt without you pasting output by hand.

## Installation

```bash
cargo install triage-mcp
```

> On **aarch64**, this builds `triaged` as a dependency and so needs a nightly
> toolchain — 1.99.0-nightly or newer (`nightly-2026-07-08`+) — because `triaged`'s
> `cera` inference dependency uses unstable NEON intrinsics. Use
> `cargo +nightly install triage-mcp`, or take a prebuilt binary from a
> [release](https://github.com/hyeons-lab/triage/releases).

## Prerequisite: a running daemon

`triage-mcp` is a thin client — it connects to the `triaged` daemon over the
local control transport (a Unix domain socket on macOS/Linux, a named pipe on
Windows). Make sure the daemon is running first, either in the foreground
(`triaged`) or as a per-user login service (`triaged service install`). See the
[`triaged`](https://crates.io/crates/triaged) docs for details.

## Setup

`triage-mcp` speaks MCP over stdio, so it needs no arguments — point your client
at the binary.

Claude Code:

```bash
claude mcp add triage -- triage-mcp
```

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`
on macOS, `%APPDATA%\Claude\claude_desktop_config.json` on Windows):

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

The server is **read-only**: every tool observes session state, and none of them
spawn sessions, write input, or otherwise mutate the daemon. An agent can watch
your terminals; it cannot drive them.

| Tool | Arguments | Returns |
| ---- | --------- | ------- |
| `list_sessions` | — | Every daemon-owned session, each with its current snapshot. |
| `snapshot_session` | `session_id` | The current daemon snapshot for one session. |
| `styled_rows` | `session_id`, `start`, `end` | Styled cells for a visible row range (`start` inclusive, `end` exclusive). |
