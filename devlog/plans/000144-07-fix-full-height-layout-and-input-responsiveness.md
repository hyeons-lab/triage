# Plan 000144-07: Fix Full-Height Layout and Terminal Input Responsiveness

## Thinking

### Problem Analysis
1. **Half-Height Layout (19 Rows / 380px)**:
   - When connecting or loading a session, `_loadDaemonSession` calculated an estimated restore size using `_estimatedTerminalRestoreSize`. On initial load or under certain window sizes, this computed (19 rows, 101 cols).
   - `_loadDaemonSession` issued a `resizeSession` to the daemon with 19 rows before the terminal DOM elements mounted.
   - `TerminalPane` mounted, fit to the full height of the viewport (~40 rows), and called `sendResizeOut(101, 40)`.
   - In `main.dart`, `addResizeOutListener` guarded forwarding with `session.status == 'attached'`. Because the session status was `'loading'`, the resize event was silently dropped.
   - In `_TerminalPaneState`, `_lastFittedRows` was updated to 40. Subsequent layout passes saw `_lastFittedRows == fittedRows` (`sizeChanged == false`), so `sendResizeOut` was never re-emitted.
   - The daemon PTY remained at 19 rows while the UI container was 40 rows. Full-screen TUI apps like Codex only rendered the top 19 rows, leaving the bottom half blank.

2. **Input Not Responding / Dropped Keystrokes**:
   - `triaged::session::write_input` enforces input lease authorization: `ensure!(holder.client_id == request.client_id)`.
   - If the lease holder is not the current web client, the daemon rejects `write_input` with an error message: `"client ... does not hold input lease for session ..."`.
   - In `triage_websocket_client.dart`, `writeInput` is fire-and-forget; it returns immediately and does not await the response. Any error returns asynchronously on the WebSocket event stream.
   - In `main.dart`, `_processWebSocketEvent` reacted to the error by asynchronously calling `attachSession(mode: 'InteractiveController')`. However, the typed keystrokes (such as Enter `\r` or characters typed in a burst) were already dropped.
   - Interacting with the terminal pane (clicking, focusing) did not proactively assert or verify lease ownership.
   - In `terminal_pane_web.dart`, `attachCustomKeyEventHandler` did not filter by event type, allowing `keyup` events to duplicate handled keys.

### Core Solution Principles
- For Layout:
  1. Remove the restrictive `session.status == 'attached'` check in `addResizeOutListener`, forwarding resizes whenever the session is active and not exited.
  2. If a session already has a known fit from this client, use it in `_loadDaemonSession`. For live sessions without a prior fit, do not shrink the daemon PTY to an estimate before mounting.
  3. In `_loadDaemonSessionInto`, if the session's fitted rows/cols differ from the host's reported size, synchronize immediately with `resizeSession`.
  4. Ensure DOM and Flutter containers expand fully with `minHeight = '100%'` and `SizedBox.expand`.
- For Input:
  1. Add an interaction listener on `TerminalController` so tapping or focusing the terminal immediately triggers `_ensureSessionInputLease`.
  2. Track `hasInputLease` on `SessionVm`, updating it on attach, `LeaseChanged` events, and lease errors.
  3. Buffer keystrokes when the lease is unconfirmed or being acquired, flushing them immediately upon lease acquisition so zero keystrokes are lost.
  4. Filter `attachCustomKeyEventHandler` to `keydown` events only.

## Plan

1. **Update `flutter/triage_client/lib/widgets/terminal_pane.dart`**:
   - Add interaction listener support (`addInteractionListener`, `removeInteractionListener`, `notifyInteraction`) on `TerminalController`.
   - Add `notifyInteraction` on `TerminalSessionInputRouter`.

2. **Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart`**:
   - Set `minHeight = '100%'` on `_container` and `_terminalWrapper`.
   - Wrap `terminal` in `SizedBox.expand` with `width: double.infinity, height: double.infinity`.
   - Call `widget.controller.notifyInteraction()` in `_activateTerminal()`, `onTapDown`, and `onFocusChange(true)`.
   - Filter `attachCustomKeyEventHandler` to `type == 'keydown'`.

3. **Update `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`**:
   - Keep interface parity for non-web builds.

4. **Update `flutter/triage_client/lib/main.dart`**:
   - Add `hasInputLease` property on `SessionVm`.
   - Implement `_pendingInputBytes` buffer and `_acquireInputLeaseAndFlush` helper.
   - In `addResizeOutListener`, allow forwarding whenever `sessionId != null && !session.isExited && session.status != 'exited'`.
   - In `_setupSessionInputListener`, listen for interaction notifications and buffer/flush input safely.
   - In `_loadDaemonSession`, respect known fitted sizes and avoid shrinking live sessions to estimates.
   - In `_loadDaemonSessionInto`, check for size drift after attach and issue `resizeSession` if needed.
   - In `_processWebSocketEvent`, process `LeaseChanged` envelopes and retry pending input on lease recovery.

5. **Validate**:
   - Run `flutter analyze` and `flutter test`.
   - Build release binary: `cargo build --release -p triaged`.
   - Codesign on ARM64 macOS: `codesign -s - -f ~/.cargo/bin/triaged`.
   - Zero-downtime reload: `~/.cargo/bin/triaged reload`.
   - Verify snapshot and input in live daemon.

6. **Devlog & Commit**:
   - Update `devlog/000144-fix-web-terminal-focus-lifecycle.md` following HEAD commit rule and no em dashes.
   - Commit and push.
