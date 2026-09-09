# 000144-05: Fix Codex Session Deadlock and Input Lease Recovery

## Thinking

OpenAI Codex runs in raw mode (-echo, -icrnl) and uses DEC Mode 2026 (Synchronized Output). In the Flutter web client, several issues compounded to render Codex sessions unresponsive when opened or switched to:

1. Terminal display history deadlock in `_loadDaemonSessionInto`:
   When `_loadDaemonSessionInto` replaces a placeholder session with an attached session, if `oldSession.hasFitted` was true, the dimensions were carried over, but `session.noteViewFit(...)` was omitted. As a result, `_viewReady` remained false, staged history remained unflushed in `_pendingHistory`, and `TerminalStore` remained stuck in `AttachPhase.awaitingHistory`. In `AttachPhase.awaitingHistory`, `_reduceLive` diverts all incoming live output from Codex into `_pendingLive`, so none of the echoed characters or frame redraws were written to xterm.js.

2. Cached container initial content notification:
   When switching to a session that was already mounted and cached in `_sessionContainers`, `initState()` reuses the cached container and sets `_initialContentWritten = true`. However, it did not immediately call `_writeInitialContent()` with the cached dimensions right after `_bindController()`. Calling `_writeInitialContent()` immediately ensures the controller and session are notified of the fitted dimensions without waiting for an async post-frame callback.

3. Broadening input lease error recovery:
   In `main.dart`, `writeInput` error detection previously looked specifically for `does not hold input lease` or `no input lease holder`. Rejections from `triaged` can take several forms depending on the session state. Broadening the pattern matching to check `errStr.contains('input lease')` and `msg.contains('input lease')` in both `_setupSessionInputListener` and `_processWebSocketEvent` guarantees that any lease rejection automatically triggers an `attachSession(mode: 'InteractiveController')` call to acquire the lease.

4. Ensuring direct session target in `SessionWorkspace`:
   In `SessionWorkspace`, `onViewFit` should directly invoke `session.noteViewFit(cols, rows)` before calling the parent callback, ensuring the specific session instance owned by the workspace is updated even during state transitions.

## Plan

1. In `flutter/triage_client/lib/main.dart`:
   - In `_loadDaemonSessionInto`, if `oldSession._viewReady` is true, call `session.noteViewFit(oldSession._viewCols, oldSession._viewRows)`. Else if `oldSession.lastFittedCols != null && oldSession.lastFittedRows != null`, call `session.noteViewFit(oldSession.lastFittedCols!, oldSession.lastFittedRows!)`.
   - In `_setupSessionInputListener`, update `writeInput.catchError` to check `errStr.contains('input lease')`.
   - In `_processWebSocketEvent`, update `type == 'error'` handler to check `msg.contains('input lease')`.
   - In `SessionWorkspace`, invoke `session.noteViewFit(cols, rows)` inside `onViewFit`.

2. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - In `initState()`, inside the `cachedContainer != null` branch, call `_writeInitialContent(overrideCols: _lastFittedCols, overrideRows: _lastFittedRows)` right after `_bindController()` if fitted dimensions exist.

3. Validate:
   - Run `flutter analyze` and `flutter test`.
   - Build Flutter release web bundle.
   - Run `cargo check --workspace` and `cargo test --workspace`.
   - Recompile `triaged` release binary and re-sign via `codesign -s - -f ~/.cargo/bin/triaged`.
   - Reload daemon using zero-downtime handover protocol (`triaged reload` or `triaged --handover`).
   - Verify `session-218` on the daemon.
