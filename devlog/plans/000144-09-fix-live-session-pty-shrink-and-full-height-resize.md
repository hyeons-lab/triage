# Plan: Fix Live Session PTY Shrink and Full-Height Resize

## Thinking

Live sessions (Codex, Antigravity CLI, Ratatui, etc.) were experiencing two critical UI symptoms:
1. Codex sessions appeared stuck and did not show typed text in the input box at the bottom of the screen.
2. Antigravity sessions rendered in only the top half of the vertical space with black space below, and scrolling only updated the top half.

Empirical socket inspection revealed that `session-218` (Codex) had its PTY clamped to 19 rows by 99 columns on the daemon (`rows: 19, cols: 99`).
Because Codex was told the terminal only had 19 rows, Codex rendered its input prompt at row 17. The user looked at row 40 (the bottom of the screen), which was empty black space.
Similarly, Antigravity CLI rendered in 19 rows, occupying only the top half of the vertical viewport.

Root cause analysis identified the following:
1. In `_loadDaemonSession` (`main.dart`), when loading an unattached session, `knownTargetSize` is `null` because the placeholder `SessionVm` has not recorded fitted dimensions.
2. `replayTargetSize` defaulted to `_estimatedTerminalRestoreSize(preAttachSnapshot['size'])`, which computed 19 rows from narrow initial viewport constraints.
3. For live sessions (`exited != true`), `_loadDaemonSession` sent `_client.resizeSession(rows: 19, cols: 99)` directly to the daemon.
4. The daemon shrank the PTY to 19 rows and dispatched `SIGWINCH` to Codex / Antigravity CLI.
5. In `_loadDaemonSessionInto`, `session.lastFittedCols` was `null`, so the automatic post-load resize synchronization was bypassed.
6. When `TerminalPane.didUpdateWidget` replaced the controller, it only notified `widget.onViewFit`, but never dispatched `sendResizeOut` to the new controller.
7. In `terminal_pane_web.dart`, `_TerminalPaneState` already had `_lastFittedRows = 40`, so `sizeChanged` evaluated to `false` and skipped re-emitting `sendResizeOut`.
8. In `_refitActiveSession`, sessions with status `loading` or not strictly `attached` were aborted, preventing the header refit button from recovering the terminal geometry.

## Plan

1. Expose `TerminalPane.getCachedTerminalSize(terminalId)`:
   - In `terminal_pane_web.dart`: query `_sessionTerms[sanitizedId]` for actual `cols` and `rows` when initialized and `>= 10` cols and `>= 5` rows.
   - In `terminal_pane_stub.dart`: return `null`.
   - In `terminal_pane.dart`: delegate to platform implementation.

2. Prevent Live Session Shrinking in `main.dart`:
   - In `_loadDaemonSession`:
     - Consult `TerminalPane.getCachedTerminalSize('triage / $sid')` in addition to `existing.ownFittedRows`/`lastFittedRows`.
     - For live sessions (`preAttachSnapshot['exited'] != true`), NEVER fall back to `_estimatedTerminalRestoreSize`. If `knownTargetSize` is `null`, leave `replayTargetSize` as `null` so the live process retains its host PTY dimensions.
     - Only exited sessions restoring history may use `_savedOrEstimatedTerminalRestoreSize`.
   - In `_refreshSessionSnapshot`:
     - Avoid resizing live sessions to `_estimatedTerminalRestoreSize` when no fitted size is known.
   - In `_loadDaemonSessionInto`:
     - If `TerminalPane.getCachedTerminalSize(session.title)` is available, immediately set `session.hasFitted`, `lastFittedCols`, `lastFittedRows`, `ownFittedCols`, `ownFittedRows`, and call `session.noteViewFit`.
     - Synchronize the host PTY size immediately if `session.hostSizeRows != session.lastFittedRows || session.hostSizeCols != session.lastFittedCols`.

3. Ensure Reliable Resize Delivery in `terminal_pane_web.dart`:
   - In `didUpdateWidget`: when `oldWidget.controller != widget.controller`, call `_sessionInputRouter.sendResizeOut(_sanitizedId, fittedCols, fittedRows)` and `_onFit()` to notify the newly bound controller.
   - In `_refitAndSend`: ensure `sendResizeOut` jiggle (`rows - 1` followed by `rows`) forces `SIGWINCH` and full-screen repaint.
   - In `_refitActiveSession` (`main.dart`): allow refit when `!session.isExited && session.status != 'exited'`, removing the overly strict `status == 'attached'` check.

4. Validation:
   - Run `flutter analyze` and `flutter test`.
   - Build release binary: `cargo build --release -p triaged`.
   - Ad-hoc codesign on ARM64 macOS: `codesign -s - -f ~/.cargo/bin/triaged`.
   - Perform zero-downtime daemon handover: `~/.cargo/bin/triaged reload`.
   - Inspect live session dimensions via socket script to verify `session-218` and other sessions receive full-height rows (>35 rows).
