# Plan 000186-01: MCP Worker Lifecycle, Blocking Wait, and Input Guards

Created: 2026-11-15T14:58-0800

## Thinking

### Goals and Boundaries

Today `triaged` has flat sessions, a side inbox with best-effort `wake`, and `wait_for_session_message` for inbox polling. Coordinators lack:
1. Dependency-ordered teardown (killing a coordinator leaves its child workers running unless `outlive_parent` is requested).
2. Automatic failure/block escalation from child workers to their parent inbox.
3. A multi-worker blocking barrier (`wait_for_sessions`) so a coordinator doesn't burn tokens polling snapshots in a loop.
4. Safety guards preventing `wake` (and any automated PTY input) from sending `\r` into an active `[y/N]` / judge confirmation dialog or clobbering an unsubmitted human draft typed at the prompt.

### Architecture Notes

1. **Wire types and FlatBuffers compatibility:**
   - Append `parent_session_id`, `outlive_parent`, `pending_approval`, and `pending_approval_reason` to the end of `table SessionSnapshot` in `crates/triage-core/schema/triage.fbs`, and `parent_session_id` + `outlive_parent` to `StartSessionRequestTable`, plus optional `automated` / `force` on `WriteInputRequestTable`. Appending preserves all existing FlatBuffer vtable field IDs.
   - Regenerate Dart FlatBuffer bindings via `scripts/generate-dart-flatbuffers.sh` so workspace checks stay clean across Rust and Flutter.
   - Add `WaitForSessionsMode`, `SessionWaitOutcome`, `WaitForSessionsRequest`, `WaitedSessionStatus`, and `WaitForSessionsResponse` to `crates/triage-core/src/session.rs` and add `SessionApi::wait_for_sessions` with a default unsupported error.

2. **Daemon actor and manager state (`triaged/src/session.rs`, `handover.rs`):**
   - `SessionActor` / `ActorState` tracks:
     - `draft_updated_ms: Arc<AtomicU64>`: updated to current unix ms when non-mouse human input bytes do not terminate a line (`\r`, `\n`, `\x03`, `\x04`, `\x15`) and cleared to `0` when those submit/cancel bytes arrive. Backspace/characters after text keep the draft active.
     - `wake_for_inbox()` checks:
       1. Not exited / not output closed / not root shell in foreground.
       2. Screen is not showing a confirmation/approval prompt (`looks_like_confirmation_prompt(&rows)`) and manager has not marked `pending_approval`.
       3. Human draft guard: `draft_updated_ms` is `0` or older than `HUMAN_DRAFT_GUARD_WINDOW_MS` (60 seconds).
       4. Existing `is_session_ready_for_wake_nudge` check.
     - `WriteInputRequest`: when `automated && !force`, reject with an explicit error if the session has `pending_approval` (either judge-flagged or confirmation prompt visible) or an active human draft (`< 60s`). Normal interactive `WriteInputRequest` (`automated: false`) continues unimpeded and clears `pending_approval` once input submits/responds (`\r`, `\n`, `y`, `Y`, `n`, `N`, etc.) or output advances past the prompt.
   - `ManagedSession::Live`, `PersistedSession`, and `HandoverSession` carry `parent_session_id` and `outlive_parent`, plus manager tracks `pending_approvals: Mutex<HashMap<SessionId, String>>`.
   - `judge_tool_call`: when `verdict.decision == JudgeDecision::Ask` and `verdict.source != JudgeSource::Fallback` (explicit rule ask or non-fallback ask, plus option to surface `Model`? Only `Ask` actually prompts the user!) sets `pending_approvals` for that session, notifies lifecycle waiters, and sends an inbox alert to `parent_session_id` (if live). Note: judge disabled / fallback still relies on `looks_like_confirmation_prompt(&rows)` on the live actor screen!
   - Exit notifications and parent cascade:
     - Actors hold `exit_notify_tx: Option<Sender<SessionId>>` + `state_signal: Option<Arc<SessionStateSignal>>`.
     - On `OutputClosed` / exit broadcast, actor pushes its `SessionId` to `exit_notify_tx` and wakes `state_signal`.
     - `SessionManager::start_lifecycle_monitor(self: &Arc<Self>)` drains `exit_notify_rx`, alerts `parent_session_id` if the exited session was a non-shutdown child (and also alerts if judge/prompt blocks), and recursively shuts down live children with `parent_session_id == Some(&exited_id) && !outlive_parent`.
     - `shutdown_session` cascades to live/restoring children with `!outlive_parent` and removes/wakes waiters cleanly, and `wait_for_sessions` / `list_sessions` / `receive_session_messages` opportunistically process any pending `exit_notify_rx` events when the background monitor thread was not started (such as stack-allocated `SessionManager` tests).

3. **Blocking `wait_for_sessions`:**
   - Validates `timeout_ms <= SESSION_MESSAGE_MAX_WAIT_TIMEOUT_MS` and non-empty `session_ids` (all known, or exited historical sessions immediately satisfy `Exited`).
   - Polls condition synchronously on wakeups from `state_signal` (driven by actor output/exit, approval updates, session shutdown, and `inbox_signal` / message send) with bounded `wait_timeout` (e.g. up to remaining idle threshold / 200ms slices) so idle timers (`quiet_ms >= idle_ms`) fire promptly without busy looping.

4. **MCP (`triage-mcp`):**
   - Expose `parent_session_id` and `outlive_parent` on `start_session` tool schema and handler.
   - Add `wait_for_sessions` tool schema and handler.
   - Include `pending_approval`, `pending_approval_reason`, `parent_session_id`, and `outlive_parent` in `snapshot_session` text/JSON summary.

## Plan

1. Update `crates/triage-core/schema/triage.fbs`, `crates/triage-core/src/session.rs`, and `crates/triage-core/src/flatbuffers_proto.rs`.
2. Regenerate Dart FlatBuffer bindings via `scripts/generate-dart-flatbuffers.sh`.
3. Update `crates/triage-transport-ws` (`flatbuffers_proto.rs`, `lib.rs`, `benches/protocol_bench.rs`) and `crates/triage` (`main.rs`, `lib.rs`) for the new request/snapshot fields.
4. Implement draft guard, blocked-prompt detection, `pending_approvals`, parent-child cascade/alerts, and `wait_for_sessions` in `crates/triaged` (`handover.rs`, `session.rs`, `ipc.rs`, `main.rs`, `http.rs`, `handover_tests.rs`).
5. Update `crates/triage-mcp/src/main.rs` (`start_session`, `wait_for_sessions`, `snapshot_session`) and add MCP tests.
6. Run `cargo fmt --all -- --check`, `TRIAGE_SKIP_FLUTTER_BUILD=1 cargo clippy --all-targets --all-features -- -D warnings`, and `TRIAGE_SKIP_FLUTTER_BUILD=1 cargo test --workspace`; fix any issues; update devlog `000186` and commit.
