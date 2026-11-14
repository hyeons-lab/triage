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

## Managed cross-runtime delegation

The daemon owns durable parent/topic groups and worker task records. The calling
agent chooses native helpers when they support the requested provider/model and
have capacity; otherwise it uses a configured Triage worker profile. This routing
is documented in the portable
[`agent-teamwork`](../../skills/agent-teamwork/SKILL.md) coordinator workflow,
[`triage-coordination`](../../skills/triage-coordination/SKILL.md), and tool metadata.

Configure profiles in `~/.config/triage/config.toml`. Confirm each installed CLI's
interactive startup syntax before enabling a profile; add only supported model
and effort flags for that version. Use absolute executable
paths when the daemon's PATH differs from your shell. Authentication and permission
configuration belong to each CLI and remain in force.

```toml
[workers.profiles.agy]
command = "agy"
args = ["--prompt-interactive", "{prompt}"]

[workers.profiles.muse]
command = "muse"
args = ["{prompt}"]

[workers.profiles.codex]
command = "codex"
args = ["{prompt}"]

[workers.profiles.claude]
command = "claude"
args = ["{prompt}"]
```

Each profile requires exactly one `{prompt}` occurrence in its argv. The daemon
substitutes a bootstrap containing the group topic, task, immediate parent, root,
and worker/session IDs. It passes argv literally, without shell expansion. Model
selection is part of the profile; there is no built-in model-name translation.
Profiles are read on demand, so editing them does not require a daemon restart.
Saved launch intentions retain the original profile arguments across retries.

| Tool | Required arguments | Behavior |
| ---- | ------------------ | -------- |
| `list_worker_profiles` | none | Configured executable/argv templates. |
| `create_worker_group` | `parent_session_id`, `key`, `topic` | Durable group; a helper inherits its existing group. Repeat a root/key/topic to recover the same group. |
| `list_worker_groups` | none | Open and closed groups, parent links, task state, and results. |
| `get_worker_group` | `group_id` | One group with observed worker liveness. |
| `spawn_worker` | `group_id`, `parent_session_id`, `key`, `profile`, `cwd`, `task` | Launch or reconcile one helper. `cwd` must be absolute. An identical retry returns the same task/session. Changed requests with the same key fail. |
| `update_worker` | `group_id`, `task_id`, `session_id`, `phase` | Report `ready`, then `running`, then `succeeded` or `failed`; terminal updates require `result`. |
| `cleanup_worker_group` | `group_id` | Cancel unfinished tasks and stop group workers; optional `subtree_session_id` limits cleanup to a worker and its descendants. |

The root is never stopped by group cleanup. Stable incarnation IDs are persisted
in the session manifest and transferred during handover, so an old worker number
cannot authorize shutting down a replacement. Group cleanup retains all working
directories and results, including unintegrated worktrees. Inspect cleanup `errors`
and retry failures. Closed groups remain available through the read tools.

Workers need either Triage MCP configured in their runtime or the `triage-mcp`
binary on PATH. The CLI fallback runs inside the worker, derives its session ID
from `TRIAGE_SESSION_ID`, and submits an update over local IPC:

```bash
triage-mcp worker-update GROUP_ID TASK_ID ready
triage-mcp worker-update GROUP_ID TASK_ID running
triage-mcp worker-update GROUP_ID TASK_ID succeeded --result-file result.md
```

Add `--socket PATH` for a custom daemon socket. Task and result bodies are limited
to 64 KiB each; oversized results should summarize findings and point to retained
artifacts. There are at most 128 workers per group, 256 retained groups, and a
32 MiB registry budget (1 MiB reserved for cleanup transitions). An explicit null
subtree is rejected; omit the field for full-group cleanup. Corrupt registries fail closed; ordinary terminal sessions
remain usable. No registry entries or worktrees are automatically pruned.

`launched` means a process started. Only worker updates establish readiness and
completion. An absent/exited process without a terminal result is interrupted work.
Group/task state persists across cold restart and handover; direct mail does not.
The orchestrator must poll, supervise, retry with bounded attempts, and integrate
results. There is no independent model scheduler, automatic worktree creation, or
authentication bypass. Raw `start_session` remains available for basic launches
without managed retry/ownership guarantees.
