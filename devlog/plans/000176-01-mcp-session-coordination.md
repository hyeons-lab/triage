# Plan 000176-01: Cross-Session Multi-Model Coordination via MCP

## Thinking

Triage already exposes `send_session_message`, `receive_session_messages`, and `ack_session_messages` over `triage-mcp`, allowing agents running in separate Triage sessions (including different models/harnesses such as Claude Code, Codex/Muse, and Antigravity/Gemini) to exchange messages via per-session inboxes in `triaged`.

Two gaps prevent autonomous multi-model back-and-forth across sessions:

1. **No blocking long-poll tool (`wait_for_session_message`)**:
   - Today, `receive_session_messages` returns immediately. When Model A sends a request to Model B and wants to wait for Model B's response within a single turn, Model A has to spin-poll `receive_session_messages` or stop its turn and wait for the user to prompt it again.
   - Adding `wait_for_session_messages` to `SessionApi`, `IpcClient`, `SessionManager`, and `triage-mcp` (`wait_for_session_message`) lets a caller block on a `Condvar` until at least one unacked message is present in `session_id`'s inbox or `timeout_ms` expires (up to 300,000 ms, default 30,000 ms).
   - On the IPC client side (`crates/triaged/src/ipc.rs`), `transport::connect` configures a 12-second read timeout (`CLIENT_READ_TIMEOUT`) on Unix domain sockets. For `WireRequest::WaitForSessionMessages`, `IpcClient` must extend the socket read timeout by `Duration::from_millis(timeout_ms) + CLIENT_READ_TIMEOUT` so a 30s-300s wait does not fail early with `WouldBlock`/`TimedOut` on the client socket.

2. **No opt-in wakeup nudge (`wake: true` on `send_session_message`)**:
   - When Model B is sitting idle at its input prompt, placing a message in its side inbox does not wake it up unless something prompts Model B to call `receive_session_messages`.
   - Adding an optional `wake: bool` parameter (default `false`) to `send_session_message` (via `SendSessionMessageRequest` / `SendSessionMessageResponse { message_id, woke }`) allows the sender to opt in to nudging the target session when it is idle or waiting for input:
     - If the target session already has an active waiter blocked in `wait_for_session_message` (`active_waiters > 0`), `inbox_signal.notify_all()` delivers the message directly to that blocked tool call (`woke = true`) without injecting any terminal bytes.
     - Otherwise, if `wake` is `true` and the inbox is not within its wakeup cooldown (`WAKE_NUDGE_COOLDOWN`, cleared immediately whenever `receive_session_messages`, `wait_for_session_messages`, or `ack_session_messages` runs), `SessionManager` sends `ActorCommand::WakeForInbox` to the target session's actor.
     - `ActorState::wake_for_inbox` verifies that:
       1. The session is live and not exited (`!self.exited && !self.output_closed`).
       2. The session is not sitting at a bare root login shell (`!(is_interactive_shell && self.is_root_shell_in_foreground())`), avoiding typing a natural-language prompt into `zsh`/`bash` when no foreground agent or child process is running.
       3. The session is idle or waiting for input (not actively mid-turn with `"esc to interrupt"` / `"esc to cancel"` / `"ctrl+c to interrupt"` / Braille spinner frames and recent output, and not actively streaming output without a prompt).
     - When eligible, `ActorState::wake_for_inbox` sends `WAKE_INBOX_PROMPT_TEXT` (`"Check your Triage inbox with receive_session_messages and process any new messages."`) to `writer_tx` and schedules a separate `\r` write 30ms later so raw-mode TUI harnesses (Ink/Claude Code, Crossterm/Codex, Antigravity) treat the trailing `\r` as a distinct `Enter` key press rather than a pasted newline.

## Plan

1. **`crates/triage-core/src/session.rs`**:
   - Add `SESSION_MESSAGE_DEFAULT_WAIT_TIMEOUT_MS` (`30_000`), `SESSION_MESSAGE_MAX_WAIT_TIMEOUT_MS` (`300_000`), `SendSessionMessageRequest`, `SendSessionMessageResponse`, and `WaitForSessionMessagesRequest`.
   - Add `SessionApi::send_session_message_with_options` and `SessionApi::wait_for_session_messages` with default implementations and `Arc<T>` forwarding.
2. **`crates/triaged/src/session.rs`**:
   - Replace `inboxes: Mutex<HashMap<SessionId, VecDeque<SessionMessage>>>` with `inboxes: Mutex<HashMap<SessionId, SessionInbox>>` and `inbox_signal: Condvar`.
   - Implement `send_session_message_with_options` and `wait_for_session_messages` on `SessionManager`, waking `inbox_signal` on message enqueue and session shutdown, tracking `active_waiters` and `last_wake_at`, and clearing `last_wake_at` on `receive_session_messages`, `wait_for_session_messages`, and `ack_session_messages`.
   - Add `ActorCommand::WakeForInbox` and `ActorState::wake_for_inbox` with root-shell protection, idle/waiting-for-input detection, and split text + `\r` delivery.
   - Add unit tests covering `wait_for_session_messages` (immediate return, blocking until arrival, timeout expiration) and `send_session_message_with_options` (`wake: true` on idle agent process, suppression on bare root shell, suppression when busy streaming, coalescing within cooldown, and direct wakeup of blocked `wait_for_session_messages` waiters without PTY injection).
3. **`crates/triaged/src/ipc.rs`**:
   - Add `WireRequest::SendSessionMessageWithOptions`, `WireRequest::WaitForSessionMessages`, and `WireSuccess::SendSessionMessageResponse` while keeping `WireRequest::SendSessionMessage` for wire compatibility.
   - Extend `IpcClient` with `round_trip_with_read_timeout` so `wait_for_session_messages` sets the client socket read timeout to `timeout_ms + CLIENT_READ_TIMEOUT`.
   - Add IPC round-trip tests.
4. **`crates/triage-mcp/src/main.rs` & `crates/triage-mcp/README.md` & `SKILL.md`**:
   - Add optional `wake: bool` parameter to `send_session_message` (returning `message_id` and `woke`).
   - Add `wait_for_session_message` tool (`session_id`, optional `timeout_ms`).
   - Update `crates/triage-mcp/README.md`, `crates/triage-mcp/src/main.rs` unit tests, and `/Users/dberrios/.gemini/config/skills/triage-coordination/SKILL.md`.
