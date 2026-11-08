# Plan: Fix Terminal Auto-Refit and Post-Resize Redraw Clobbering

## Thinking

Users regularly have to tap the header Refit button because the terminal renders with a mismatched grid width or a garbled pre-redraw frame across several common workflows:

1. **`postResizeHttpReplay` in `_refreshSessionSnapshot` clobbers live `SIGWINCH` redraws**:
   - In `_refreshSessionSnapshot` (`main.dart:6198-6230`), whenever `_client.resizeSession` resizes a primary-screen session (`resizedHost && useHttpHistory && !session.terminal.isUsingAltBuffer`), `postResizeHttpReplay` forces `_fetchAndMergeSessionHistory(..., forceFullWindow: true)` and `_applySnapshotToSession(..., replayHistory: true, forceFullReplay: true)` even on metadata-only refreshes (`includeHistory == false`, `session.loaded == true`, such as `_selectSession` and `_onSessionViewFit`).
   - On `triaged`, `ActorState::resize` sends `SIGWINCH` to the PTY child and immediately calls `wezterm_term::Terminal::resize` before the child process (Claude Code, Gemini CLI, Codex inline mode, or a shell) has woken up to redraw for `SIGWINCH`.
   - Meanwhile, while `_fetchAndMergeSessionHistory` is reading/decompressing `.tlog` segments and transferring over HTTP, `session.store.isPagingHistory` is `false`. The child process's actual `SIGWINCH` redraw arrives over the WebSocket `Output` stream and is applied directly to `session.terminal` without being saved in `_pendingLive`.
   - When `_fetchAndMergeSessionHistory` returns the pre-`SIGWINCH` (or mid-`SIGWINCH`) `styled_rows` snapshot, `session.applyHistory(..., preservePendingLive: true)` dispatches `Attach(preservePendingLive: true)` (wiping `_appliedLiveSeq = null`) and `HistoryBytes` (`_sink.clear()`), which erases the live `SIGWINCH` redraw and leaves the pre-`SIGWINCH` frame on screen.
   - Tapping Refit (`_refitActiveSession`) fixes it because Refit jiggles `rows - 1` -> `rows` and deliberately skips history replay.

2. **Initial attach (`_loadDaemonSession`) resizes live sessions to an inaccurate `_estimatedTerminalRestoreSize` before first layout**:
   - On connect, `_loadDaemonSessions` calls `setState` to mount `TerminalPane` and immediately invokes `_loadDaemonSessionInto`. Over loopback WebSocket, `snapshotSession` returns in `< 1ms`, before Flutter lays out the first frame, so `knownTargetSize` is `null`.
   - On native (`!kIsWeb`), `_loadDaemonSession` (`main.dart:4438`) falls back to `_estimatedTerminalRestoreSize`, which uses hardcoded `averageCellWidth = 9.92`, `headerHeight = 68`, `padding = 44`, and `sidebarWidth = 320`. Actual `JetBrains Mono` 15pt cell width is ~`9.0`px with `28`px padding, so the estimate is off by 10-35 columns.
   - As a result, `_loadDaemonSession` resizes even a healthy, already-correctly-sized PTY to the wrong column count before `subscribeSessionEvents` is called, captures `styled_rows` at that wrong width, and then resizes again milliseconds later when the first frame lays out.
   - Additionally, while the placeholder `SessionVm` (`widget.isLoading == true`) is mounted, `_TerminalPaneState._scheduleResizeOut` / `_sendResizeOutNow` records `_sessionLastResizeOutCols[widget.terminalId] = cols` against a controller with no resize listener or before the real `SessionVm` swaps in, suppressing the real session's resize-out.

3. **Stale per-session cached grid size (`getCachedTerminalSize`) preferred over current workspace size (`getLastFittedWorkspaceSize`)**:
   - `_loadDaemonSessionInto` (`main.dart:4309`), `_loadDaemonSession` (`main.dart:4425`), and `_currentReplayTerminalSize` (`main.dart:4680`) all prefer `TerminalPane.getCachedTerminalSize(session.title)` over `TerminalPane.getLastFittedWorkspaceSize()`.
   - Because all sessions share the single `SessionWorkspace` viewport, if the user resizes the window or collapses/expands the sidebar while viewing Session B, `getLastFittedWorkspaceSize()` reflects the current workspace geometry, whereas `getCachedTerminalSize('triage / session-a')` still holds Session A's old pre-resize dimensions.
   - Selecting Session A then refreshes and resizes the daemon PTY (and replays `HistoryBytes` via `_applyResizeToSink`) at Session A's stale size.

4. **`RenderTerminal` and `TerminalPane` size synchronization gaps on Native**:
   - `RenderTerminal._updateViewportSize()` in `package:xterm2` only calls `_resizeTerminalIfNeeded()` when `_viewportSize` changes. If `session.terminal.resize` is called with a different size (e.g. from `HistoryBytes` or `SessionVm._flushPendingHistory`) or if `RenderTerminal` laid out while `autoResize` was `false` (`_metricsResizeSettling == true` during `didChangeMetrics`), `RenderTerminal` never resizes `_terminal` back until the window size changes.
   - `_onFit()` and `_onRefit()` in `terminal_pane_stub.dart` only called `setState(() {})` without calling `_syncTerminalSizeToRender()`, so `session.terminal.viewWidth` and `viewHeight` were not reconciled with `RenderTerminal` when `controller.fit()` or `controller.refit()` ran.
   - When a `Snapshot` event or attach snapshot reports that another client resized the PTY, `_sessionLastResizeOutCols` / `_sessionLastResizeOutRows` in `terminal_pane_stub.dart` was not invalidated, and `_selectSession` only scheduled a post-frame `fit()` on Web (`if (kIsWeb)`).

## Plan

1. **`flutter/triage_client/lib/widgets/terminal_pane_stub.dart` & `terminal_pane_web.dart`**:
   - Add `TerminalPane.invalidateCachedResizeOut(String terminalId)` (clearing `_sessionLastResizeOutCols` and `_sessionLastResizeOutRows` for `terminalId` and its sanitized id on native; no-op on web).
   - In `_scheduleResizeOut` and `_sendResizeOutNow`, always update `_sessionLastGridSize` and `_lastWorkspaceFittedSize`, but do not record `_sessionLastResizeOutCols`/`Rows` or emit `widget.controller.sendResizeOut` while `widget.isLoading` is `true`.
   - Enhance `_syncTerminalSizeToRender({bool sendResizeOut = true})` so it updates `_sessionLastGridSize` and `_lastWorkspaceFittedSize`, resizes `_terminal` when `cols != _terminal.viewWidth || rows != _terminal.viewHeight`, notifies `widget.onViewFit?.call(cols, rows)` via microtask when the terminal was resized or grid cache updated, optionally calls `_sendResizeOutNow(cols, rows)` when `sendResizeOut && !widget.isLoading`, and marks `render` dirty for layout and paint.
   - Call `_syncTerminalSizeToRender(sendResizeOut: true)` in `_onFit()` and `_syncTerminalSizeToRender(sendResizeOut: false)` in `_onRefit()` (after clearing `_sessionLastResizeOutCols`/`Rows` so `_refitActiveSession` reads the live `RenderTerminal` dimensions before performing its `rows - 1` -> `rows` jiggle).
   - Call `_syncTerminalSizeToRender()` in post-frame callbacks from `initState`, `didUpdateWidget` (when `sessionSwapped` or `oldWidget.isLoading && !widget.isLoading`), and `_onHistoryReplayed`.

2. **`flutter/triage_client/lib/main.dart`**:
   - In `_loadDaemonSessionInto`, `_loadDaemonSession`, and `_currentReplayTerminalSize`, prefer `TerminalPane.getLastFittedWorkspaceSize() ?? TerminalPane.getCachedTerminalSize(...)`.
   - In `_loadDaemonSession`:
     - When `!runningUnderFlutterTest() && mounted` and both `getLastFittedWorkspaceSize()` and `getCachedTerminalSize('triage / $sid')` are `null`, await `WidgetsBinding.instance.endOfFrame` (and re-check `_isStale(owningGeneration)`) so the mounted `TerminalPane` lays out its first frame and populates the real cell grid before we query/resize the daemon PTY.
     - Only fall back to `_estimatedTerminalRestoreSize` when `preAttachSnapshot['exited'] == true || (!kIsWeb && runningUnderFlutterTest())`.
     - For live sessions (`preAttachSnapshot['exited'] != true`), subscribe to session events (`_checkedSubscribeSessionEvents(sid)`) *before* calling `_client.resizeSession`, so any `SIGWINCH` redraw emitted during attach is captured on the subscription stream.
   - In `_refreshSessionSnapshot`:
     - Remove `postResizeHttpReplay` for metadata-only refreshes of already-loaded live sessions (`includeHistory == false && session.loaded && !revivedNeedsReplay`), so resizing on session select or view fit does not overwrite the live `SIGWINCH` redraw with a pre-`SIGWINCH` HTTP snapshot.
     - When `_refreshSessionSnapshot` will replay history (`needsHistory`) and resizes the host or fetches HTTP history, bracket the resize + HTTP history fetch with `session.store.beginHistoryPaging()` / `session.store.endHistoryPaging()` so live `SIGWINCH` chunks arriving during the RPCs are shadow-buffered in `_pendingLive` and flushed after `HistoryBytes`.
   - In `_selectSession`:
     - Run the post-frame callback on all platforms: on Web call `_fitOrReclaimActiveSessionOnWeb()`, and on Native call `session.terminalController.fit()` (or `_refitActiveSession()` when `session.hostSizeDriftedFromOwnFit && !_refreshClaims.isInFlight(sid)`).
   - When `Snapshot` events or `_applySnapshotToSession` update `session.hostSizeCols` / `session.hostSizeRows` to a size that differs from `session.ownFittedCols` / `session.ownFittedRows`, call `TerminalPane.invalidateCachedResizeOut(session.title)`.
   - In `SessionVm.applyLiveBytes` and `_loadDaemonSessionInto`, prefer `ownFittedCols` / `ownFittedRows` over `lastFittedCols` / `lastFittedRows` so host-size broadcasts from other devices cannot pre-size the local terminal to another device's dimensions.

3. **Tests & Verification**:
   - Add regression tests in `flutter/triage_client/test/` covering:
     - `_onFit` and `_onRefit` reconciling `terminal.viewWidth` / `viewHeight` with `RenderTerminal` when `terminal.resize` was called with a stale size while `RenderTerminal._viewportSize` remained unchanged.
     - Window resize on Session B followed by selecting Session A using `getLastFittedWorkspaceSize()` rather than Session A's stale cached size.
     - Live `SIGWINCH` output arriving after `_refreshSessionSnapshot` resizes an already-loaded session not being wiped out by a post-resize history replay.
   - Run `flutter analyze` and `flutter test`, commit, push, open PR, and update `/Applications/Triage.app`.
