# Devlog: Fix Terminal Auto-Refit and Post-Resize Redraw Clobbering

- **Agent:** Antigravity @ triage branch fix/auto-refit
- **Intent:** Eliminate the need to manually tap the Refit button by fixing the root causes where initial session attach, session switching, window resizing, and multi-client PTY size drift leave the terminal at a mismatched grid size or clobber live `SIGWINCH` redraws.

## What Changed

- 2026-11-08T13:03-0800 `flutter/triage_client/lib/main.dart`: Stop forcing `postResizeHttpReplay` on metadata-only (`includeHistory == false`) refreshes of already-loaded live sessions so resizing the host PTY does not clobber live `SIGWINCH` redraws with a pre-`SIGWINCH` HTTP `styled_rows` snapshot; bracket `needsHistory` refreshes in `_refreshSessionSnapshot` with `beginHistoryPaging()` / `endHistoryPaging()`; await `WidgetsBinding.instance.endOfFrame` on initial `_loadDaemonSession` when no workspace size is cached yet and subscribe to session events before `resizeSession` on live sessions; prefer `TerminalPane.getLastFittedWorkspaceSize()` over per-session cached dimensions when switching sessions or replaying history; invalidate `TerminalPane`'s resize-out cache when host snapshots report size drift; and trigger `terminalController.fit()` on native session selection.
- 2026-11-08T13:03-0800 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`, `flutter/triage_client/lib/widgets/terminal_pane_web.dart`: Add `TerminalPane.invalidateCachedResizeOut(String terminalId)`, guard `_scheduleResizeOut` and `_sendResizeOutNow` so `isLoading: true` placeholder panes still populate `_lastWorkspaceFittedSize` without poisoning `_sessionLastResizeOutCols`/`Rows`, and reconcile `_terminal` dimensions with `RenderTerminal` via `_syncTerminalSizeToRender` across `_onFit`, `_onRefit`, `_onHistoryReplayed`, `initState`, and `didUpdateWidget`.
- 2026-11-08T13:03-0800 `flutter/triage_client/test/terminal_hardware_key_test.dart`, `flutter/triage_client/test/widget_test.dart`: Add regression tests covering `RenderTerminal` grid reconciliation on `fit()`/`refit()`/`notifyHistoryReplayed()`, placeholder `isLoading` resize-out cache isolation, and preserving live `SIGWINCH` output across metadata-refresh host resizes.

## Decisions

- 2026-11-08T12:51-0800 Do not force a full HTTP history replay (`postResizeHttpReplay`) on metadata-only refreshes (`includeHistory == false`) of already-loaded live sessions in `_refreshSessionSnapshot`: `resizeSession` sends `SIGWINCH` to the child process and immediately reflows the daemon's `wezterm-term` before the child process wakes up to redraw. Fetching HTTP `styled_rows` 1ms later captures the pre-`SIGWINCH` screen while `isPagingHistory` is false, and the subsequent `Attach(preservePendingLive: true)` + `_sink.clear()` wipes out the live `SIGWINCH` redraw that arrived over WebSocket in the meantime. When `_refreshSessionSnapshot` does replay history after resizing (`includeHistory == true` or `!session.loaded`), bracket the resize and history fetch with `session.store.beginHistoryPaging()` / `endHistoryPaging()` so live `SIGWINCH` chunks arriving during the RPCs are buffered in `_pendingLive` and flushed after `HistoryBytes`.
- 2026-11-08T12:51-0800 Await `WidgetsBinding.instance.endOfFrame` in `_loadDaemonSession` when no fitted workspace size is cached yet (outside `FLUTTER_TEST`), and never resize a live production session to `_estimatedTerminalRestoreSize`: `_loadDaemonSessions` calls `setState` to mount `TerminalPane` right before calling `_loadDaemonSessionInto`. Waiting for the end of that frame lets `RenderTerminal` measure the true font and viewport cell grid first, avoiding a bogus intermediate resize (using hardcoded `9.92`px cell width) and subscribing to session events before `resizeSession` on live sessions so no `SIGWINCH` redraw is missed.
- 2026-11-08T12:51-0800 Prefer `TerminalPane.getLastFittedWorkspaceSize()` over `TerminalPane.getCachedTerminalSize(session.title)` when resolving target terminal dimensions: all sessions share the single `SessionWorkspace` viewport, so after a window resize or sidebar toggle on Session B, `getLastFittedWorkspaceSize()` holds the current viewport size whereas `getCachedTerminalSize` for Session A holds Session A's stale pre-resize dimensions.
- 2026-11-08T12:51-0800 Reconcile `session.terminal` with `RenderTerminal` in `_onFit`, `_onRefit`, `initState`, `didUpdateWidget`, and `_onHistoryReplayed`, and invalidate `_sessionLastResizeOutCols`/`Rows` on host size drift: `RenderTerminal._updateViewportSize()` only calls `_resizeTerminalIfNeeded()` when `_viewportSize` changes, so if `terminal.resize` was called with a different size (or while `autoResize` was paused during `didChangeMetrics`), `terminal.viewWidth` and `viewHeight` stay out of sync with `RenderTerminal` until `_syncTerminalSizeToRender()` runs.

## Commits

- `HEAD`: fix(client): auto-reconcile terminal grid size and preserve live SIGWINCH redraws

## Progress

- [x] Diagnose root causes of manual Refit requirement across attach, select, resize, and multi-client flows
- [x] Implement fixes in `flutter/triage_client/lib/main.dart`, `terminal_pane_stub.dart`, and `terminal_pane_web.dart`
- [x] Add regression tests and run full analyzer/test suite
