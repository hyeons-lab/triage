# 000147-03: Fix Per-Session Resize Tracking, PTY Drift on Session Switch, and Refit Snap to Top

## Thinking

Two interconnected issues were identified from the user report and desktop screenshot (`session-222`, Antigravity CLI composer corrupted by text overwrite, and refit snapping to top):

1. Rendering corruption on session switch (PTY width mismatch):
   - In `terminal_pane_stub.dart`, `_lastResizeOutCols` and `_lastResizeOutRows` were single instance variables on `_TerminalPaneState` rather than tracked per session.
   - When switching sessions in `Triage.app` on macOS desktop (e.g. from Session A to Session B), the terminal window width was already 81 columns. `RenderTerminal.performLayout` saw no viewport dimension change and did not invoke `_onTerminalResize`.
   - Even when `_scheduleResizeOut(81, 24)` was called, it compared against `_lastResizeOutCols == cols && _lastResizeOutRows == rows` from the previous session and returned early without sending `sendResizeOut`.
   - In `main.dart`, `TerminalPane.getCachedTerminalSize(session.title)` always returned `null` on non-web platforms because it was a stub.
   - When `_refreshSessionSnapshot` ran on session selection, `_currentReplayTerminalSize` found `cachedSize == null`, `session.ownFittedCols == null`, and fell back to `_estimatedTerminalRestoreSize`. That helper estimated 97 columns from the window width and estimated cell width (9.92).
   - `_refreshSessionSnapshot` actively told the daemon to resize the remote PTY to 97 columns, even though the desktop window actually rendered at 81 columns.
   - In `_selectSession`, the post-frame refit call was guarded by `if (kIsWeb)`, so macOS native desktop never refitted or re-asserted its size on session selection.
   - Antigravity CLI generated 97-character separator lines. In the 81-column viewport, these wrapped across two physical lines, causing cursor up sequences (`\x1b[2A`) to land two rows lower than expected. Subsequent typing overwrote the separator and status lines.

2. Refit snapping to top:
   - In `terminal_pane_stub.dart`, `_onRefit` evaluated `isScrolledUp` by checking whether `_sessionSavedScrollOffsets.containsKey(widget.terminalId)`. If an earlier layout pass or initial mount saved `0.0` into that map, `isScrolledUp` evaluated to true and `forceBottom` was set to false.
   - In `_scrollToCursor`, `wasScrolledUp` saw `saved != null` (0.0) and jumped to 0.0, snapping the terminal to the top instead of staying at the bottom.
   - In `terminal_pane_web.dart`, `_viewportIsAtBottom` used a strict 3-pixel threshold (`remainingPixels <= 3`). If `viewportY < baseY` by 1 line (or 10-15 pixels of sub-row scroll), `wasAtBottom` evaluated to false. When `_sessionSavedViewportY` had no entry, `xterm.js` defaulted to line 0 on fit, snapping to the top.

## Plan

1. Update `terminal_pane_stub.dart`:
   - Replace single `_lastResizeOutCols` / `_lastResizeOutRows` with static maps:
     - `_sessionLastResizeOutCols = {}`
     - `_sessionLastResizeOutRows = {}`
     - `_sessionLastGridSize = {}`
     - `_lastKnownGridSize` fallback pair
   - Implement `getCachedTerminalSize(String terminalId)` to return the session's recorded grid size or `_lastKnownGridSize`.
   - In `_sendResizeOutNow(int cols, int rows)`:
     - Record dimensions in `_sessionLastGridSize` and `_lastKnownGridSize`.
     - Check `_sessionLastResizeOutCols[widget.terminalId] == cols && _sessionLastResizeOutRows[widget.terminalId] == rows`.
     - Update per-session maps and dispatch `widget.controller.sendResizeOut(cols, rows)`.
   - In `initState()` post-frame callback and `didUpdateWidget()`, if `_terminal.viewWidth > 0 && _terminal.viewHeight > 0`:
     - Record dimensions and invoke `_sendResizeOutNow(_terminal.viewWidth, _terminal.viewHeight)` if not yet dispatched for this session.
   - In `_saveScrollOffset()`:
     - Ignore `position.pixels <= 0.0` when `_suppressScrollSave` is active, preventing `0.0` from polluting the saved map.
   - In `_onRefit()`:
     - Determine `isAtBottom` directly from current scroll position: `pos == null || !pos.hasContentDimensions || pos.maxScrollExtent <= 0 || pos.pixels >= pos.maxScrollExtent - kScrollPinReleaseGraceLines * lh`.
     - When `isAtBottom` is true, clear all saved scroll offsets, distances, and anchors, and invoke `_scrollToCursor(requestFocus: false, forceBottom: true)`.
     - Also re-assert `_sendResizeOutNow(_terminal.viewWidth, _terminal.viewHeight)`.

2. Update `terminal_pane_web.dart`:
   - In `_viewportIsAtBottom`:
     - Allow `viewportY >= baseY - 1` or `remainingPixels <= 30` (within ~1.5 rows).
   - In `getCachedTerminalSize`:
     - Return `_lastKnownGridSize` when `_sessionTerms[sanitizedId]` has not been created yet.
   - Record `_lastKnownGridSize = (fittedRows, fittedCols)` on each fit pass.

3. Update `main.dart`:
   - In `_selectSession(int index)`:
     - When `session.hasFitted` is true, schedule post-frame refit if `kIsWeb || (_clientForeground && session.hostSizeDriftedFromOwnFit)`.
   - In `_refitActiveSession()`:
     - Maintain `session.ownFittedCols = cols`, `session.ownFittedRows = rows`, `session.lastFittedCols = cols`, `session.lastFittedRows = rows`, and `session.hasFitted = true` on native platforms.

4. Validate and Verify:
   - Run `flutter test test/widget_test.dart` and `flutter test`.
   - Run `cargo test --workspace`.
   - Check `git diff` for zero em dashes (em dashes).
   - Update `devlog/000147-fix-session-resume-render-refit.md`.
   - Build, install, reload daemon, and deploy to macOS desktop app and Android.
