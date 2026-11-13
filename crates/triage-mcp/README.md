# triage-mcp

Model Context Protocol (MCP) server for **Triage**, exposing terminal session context to local AI agents (such as Claude Code, Claude Desktop, or Cursor).

It lets an agent *read* what is happening in your terminals, including which sessions exist, what is on screen, and how it is styled, so it can reason about a build, a test run, or a stuck prompt without you pasting output by hand. It also starts and stops terminal sessions and lets agents in different sessions coordinate through direct messaging.

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

The lifecycle tools start executables and stop sessions through the existing
daemon API. Commands receive literal argv entries; no shell interpolation is
performed. The observation tools are **read-only**: they never spawn sessions, write
input, or otherwise mutate the daemon. The messaging tools queue, wait for, and
acknowledge coordination mail between sessions; when `send_session_message` is
called with `wake: true`, the daemon can also send a single-line inbox check
nudge to an idle agent session so cross-session delegation does not require
manual user prompting.

| Tool | Arguments | Returns |
| ---- | --------- | ------- |
| `list_sessions` | none | Every daemon-owned session, each with its custom label (if set) and current snapshot. |
| `start_session` | `command`, `cwd`, optional `args`, `rows`, `cols` | `{session_id}` for the new session. `cwd` must be absolute on the daemon host. PTY size defaults to 24 rows and 80 columns. |
| `shutdown_session` | `session_id` | `{session_id, completed}`; `completed` contains `output_seq`, `bytes_logged`, and `visible_rows`. Stops the session and its running work. |
| `snapshot_session` | `session_id` | The current daemon snapshot for one session. |
| `styled_rows` | `session_id`, `start`, `end` | Styled cells for a visible row range (`start` inclusive, `end` exclusive). |
| `send_session_message` | `from_session_id`, `to_session_id`, `body`, `wake` (optional) | `{message_id, woke}`. When `wake: true`, wakes a blocked `wait_for_session_message` call or nudges an idle agent prompt to check its inbox. |
| `receive_session_messages` | `session_id` | Unacked inbox mail, oldest first. Unacked mail is returned again on the next call. |
| `wait_for_session_message` | `session_id`, `timeout_ms` (optional, default 30000, max 300000) | Blocks until unacked inbox mail is available or `timeout_ms` elapses, then returns the unacked messages (`[]` on timeout). |
| `ack_session_messages` | `session_id`, `message_ids` | `{ok: true}`. Unknown ids are ignored. |

## Delegating work to agent sessions

`start_session` can launch `agy`, `claude`, `muse`, `codex`, or another
executable. The coordinator supplies that runtime's documented argv, including
any initial prompt. For example, this tool argument object starts a fresh
Codex session in an existing worktree (replace the example path):

```json
{
  "command": "codex",
  "args": [],
  "cwd": "/absolute/path/to/worktree",
  "rows": 40,
  "cols": 120
}
```

Executable lookup uses the daemon's environment; use an absolute executable
path when its PATH differs from the coordinator's. Triage does not translate
model, effort, or permission flags, configure the child's MCP connection, or
create worktrees. Each child receives its own `TRIAGE_SESSION_ID`.

Keep the returned session ID together with a unique run/task identity in
the run's durable state. Return success means
the daemon created a PTY child; it does not mean the agent is ready, connected
to MCP, or finished. Bootstrap inbox polling in the initial prompt or wait
for a worker-ready message before dispatching an assignment. Use the existing
messaging tools to send work (`wake: true` can nudge a recognized idle agent),
wait for results, and acknowledge processed messages. Waiting blocks this
stdio connection, so bound waits and use another connection if concurrent
control is needed.

Store reports and run metadata outside mailboxes: mailboxes are in memory
and mail can be lost when the daemon restarts. Acknowledge a result only after
recording it. Terminal output from `snapshot_session` or `shutdown_session`
is diagnostic output, not a structured review report.

Before calling `shutdown_session`, re-establish that the current session
is still the intended worker using a fresh roster/snapshot and the worker's
unique run/task handshake. Numeric session IDs can be reused after a cold
daemon restart, so a persisted ID alone is not proof of ownership. If the
worker's identity cannot be confirmed, leave it running and report the
uncertainty. The local session API does not enforce a parent-child
relationship. Never stop an unrelated user session.

Both lifecycle tools are non-idempotent; a lost
response can leave an operation completed without the caller knowing, so
reconcile with session state before retrying. There is no automatic retry
or cancellation of a launch when its MCP connection closes.
