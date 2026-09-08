# Plan: Refactor Terminal Input Pipeline and Lease Management

## Thinking

Recent investigations revealed multiple interacting root causes for the terminal input failures reported in OpenAI Codex, Antigravity CLI (`agy`), and new test sessions:

1. **Daemon Input Lease Rejection (`triaged`):**
   In `crates/triaged/src/session.rs`, `write_input()` requires `lease.holder.as_ref()` to match `request.client_id`. Across 29 live sessions on the running daemon, 18 sessions had `holder: None`. When a session has `holder: None` (such as after daemon startup, process handover, or session restore), any incoming `write_input` is rejected with `session {} has no input lease holder`. The client was attempting to type, but the daemon silently rejected every keystroke.
   When `lease.holder.is_none()`, there is no conflicting writer. The daemon should auto-acquire the `Interactive` input lease for the writing client and broadcast `LeaseChanged`.

2. **Client Lease Acquisition on Selection (`lib/main.dart`):**
   When the user switches sessions via `_selectSession()`, `attachSession(mode: 'InteractiveController')` was previously deferred inside `_refreshSessionSnapshot()`, which was guarded by `_refreshInFlight.add(sessionId)` and `session.hasFitted`. If `_refreshInFlight` was already populated or the session had not yet fitted, the lease was never acquired. Selecting a session must directly and reliably assert `InteractiveController` lease ownership on the daemon.
   Additionally, if `writeInput()` ever fails with a lease error, the client should automatically re-acquire the lease and retry the write.

3. **Duplicate Input Listeners on `SessionVm.terminalController`:**
   `_setupSessionInputListener(session)` was called repeatedly for the same session (during `_loadDaemonSessions`, `_loadDaemonSessionInto`, and session creation). Because `TerminalController._inputListeners` is an unbound `List`, every keystroke fired multiple identical write calls. Adding an `inputListenerBound` guard ensures a session's controller is wired to the WebSocket client exactly once.

4. **Web Terminal Dueling Input Listeners & Deduplication Collisions (`terminal_pane_web.dart`):**
   Commit `ab3e213` removed `!_isActiveElementInTerminal()` from `_windowKeyDownListener`. This caused the window capture listener to intercept every keystroke, invoke a custom 100+ line `_keyboardEventToInput()` switch statement, call `event.preventDefault()` on every keydown, and deduplicate against `term.onData` using a 50ms timestamp window (`_sessionInputDedupe`).
   This broke native xterm.js input:
   - xterm.js never received native keydowns in its textarea because default was prevented.
   - Fast typing (less than 50ms per key) or repeating keys were dropped by timestamp deduplication.
   - Alternate screen TUIs (Codex, agy) that rely on full terminal escape sequences received partial or corrupted inputs.
   xterm.js is the authoritative terminal emulator in the browser. When `_isActiveElementInTerminal()` is true, the window keydown listener must not intercept or prevent default. All native keystrokes, shortcuts, modifiers, IME, and paste must flow through xterm.js directly to `term.onData`. The window keydown listener is only a fallback when the textarea is not yet focused: it focuses the textarea and routes the initial key.

## Plan

1. **Update Daemon Input Lease Handling (`crates/triaged/src/session.rs`):**
   - In `write_input()`: If `lease.holder.is_none()`, acquire `InputControllerKind::Interactive` for `request.client_id`, broadcast `SessionEvent::LeaseChanged`, and proceed with writing to the actor PTY.
   - Run `cargo test -p triaged` to ensure all existing lease tests and invariant tests pass.

2. **Harden WebSocket Client `writeInput` (`flutter/triage_client/lib/services/triage_websocket_client.dart`):**
   - In `writeInput()`: Include an `'id'` field on the JSON request payload and track the request so errors returned by the daemon are captured and thrown rather than dropped.

3. **Eliminate Duplicate Listeners & Enforce Lease Acquisition (`flutter/triage_client/lib/main.dart`):**
   - Add `bool inputListenerBound = false;` to `SessionVm`.
   - In `_setupSessionInputListener()`: Return early if `session.inputListenerBound` is true. Set it to true on binding.
   - Use `_sessionIdFor(session)` to ensure custom-labeled sessions resolve the valid daemon session ID.
   - In `_setupSessionInputListener()` error handling: If `writeInput` fails with a lease error, call `_client.attachSession(mode: 'InteractiveController')` and retry.
   - In `_selectSession()`: When selecting a remote session, unconditionally send `_client.attachSession(mode: 'InteractiveController')` to claim the lease.

4. **Simplify Web Terminal Input Pipeline (`flutter/triage_client/lib/widgets/terminal_pane_web.dart`):**
   - In `_windowKeyDownListener`: Check `if (_isActiveElementInTerminal()) return;`. Do not intercept or prevent default when the terminal is already focused.
   - Let xterm.js handle all focused keystrokes natively through `term.onData`.
   - Remove the fragile 50ms timestamp deduplication in `onDataCallback` and `_sendInput`.
   - Maintain robust focus on the xterm helper textarea during mount, selection, and clicks.

5. **Validation and Handover:**
   - Run `cargo test --workspace` and `cargo clippy`.
   - Run `flutter analyze` and `flutter test`.
   - Build the release web client bundle.
   - Re-sign `triaged` on macOS and perform zero-downtime daemon handover with `triaged reload`.
   - Verify typing, Backspace, Enter, arrows, and commands in Codex, agy, and standard shell sessions.
