# 000176: feat/mcp-session-coordination

## Intent

Enable autonomous multi-model coordination across Triage sessions over `triage-mcp` by adding a blocking `wait_for_session_message` long-poll tool with timeout and an opt-in `wake` nudge on `send_session_message` that wakes idle or waiting-for-input agent sessions (`devlog/plans/000176-01-mcp-session-coordination.md`).

## What Changed

- `2026-11-01T03:59-0800` `crates/triage-core/src/session.rs`: added `SESSION_MESSAGE_DEFAULT_WAIT_TIMEOUT_MS`, `SESSION_MESSAGE_MAX_WAIT_TIMEOUT_MS`, `SendSessionMessageRequest`, `SendSessionMessageResponse`, `WaitForSessionMessagesRequest`, and `SessionApi::{send_session_message_with_options, wait_for_session_messages}`.
- `2026-11-01T03:59-0800` `crates/triaged/src/session.rs`: replaced plain `VecDeque<SessionMessage>` inboxes with `SessionInbox` + `inbox_signal: Condvar` to support blocking `wait_for_session_messages` and wake cooldown coalescing; added `ActorCommand::WakeForInbox` and idle-agent wake nudges that skip bare interactive shells and active turns; added unit tests for blocking waits, timeouts, idle wake nudges, cooldown coalescing, and bare-shell protection.
- `2026-11-01T03:59-0800` `crates/triaged/src/ipc.rs`: wired `SendSessionMessageWithOptions` and `WaitForSessionMessages` over the control socket, extending the client socket read timeout by `request.timeout_ms` so long-polling waits do not hit the 12s default IPC timeout; extended IPC round-trip test coverage.
- `2026-11-01T03:59-0800` `crates/triage-mcp/src/main.rs`, `crates/triage-mcp/README.md`: added optional `wake` parameter to `send_session_message` (returning `{message_id, woke}`), added the `wait_for_session_message` tool (`session_id`, optional `timeout_ms`), and updated MCP tool unit tests and documentation.

## Decisions

- `2026-11-01T03:44-0800` Pair `SessionManager::inboxes` with an `inbox_signal: Condvar` and extend `IpcClient` socket read timeouts for `WaitForSessionMessages`: blocking inside `triaged` on a `Condvar` avoids polling loops across the IPC socket while immediately waking any waiting agent when `send_session_message` enqueues mail or when the session shuts down.
- `2026-11-01T03:44-0800` Gate `wake: true` nudges on: (1) no active `wait_for_session_message` waiter (`active_waiters == 0`), (2) target session not sitting at a bare root login shell (`!(is_interactive_shell && is_root_shell_in_foreground())`), (3) target session not actively mid-turn or streaming output, and (4) per-inbox cooldown cleared on `receive_session_messages`/`wait_for_session_messages`/`ack_session_messages`; deliver the wakeup prompt text followed by a separate `\r` write 25ms later so raw-mode TUI harnesses (Ink/Claude Code, Crossterm/Codex, Antigravity) treat the trailing `\r` as an `Enter` submit event rather than a pasted newline.

## Commits

- `HEAD`: feat(mcp): add wait_for_session_message and wake nudges for cross-session coordination
