# 000176: fix-codex-fullscreen-scroll-chip

## Agent

Antigravity @ triage branch fix/codex-fullscreen-scroll-chip

## Intent

Fix two issues in native and remote TUI sessions:
1. In Codex fullscreen TUI mode, clicking the bottom "scroll to bottom" chip (or any mouse-clickable UI element) does nothing, and wheel scrolling on a session with scrollback emits scroll-adjusted buffer coordinates instead of viewport-relative coordinates.
2. Primary-screen session history mixes lines when paging or attaching and remains narrow on a wide laptop layout.

## What Changed

- `2026-11-03T11:27-0800` `crates/triaged/src/storage.rs`: Increase the backward segment scan in `read_multi_segment_replay_tail` from 16 to 32 segments and only stop early on `last_newline_segment_bytes` once `initial_alt` is resolved or mouse tracking is not active, so cold-restored fullscreen TUI sessions recover `?1049h` and mouse tracking modes across long output streams.
- `2026-11-03T11:27-0800` `crates/triaged/src/session.rs`, `crates/triaged/src/http.rs`: Include `styled_rows`, `styled_rows_start`, and `cursor` in `SessionHistoryCoordinates`, `SessionHistoryResponse`, and the `/api/sessions/{id}/history` `THS1` metadata JSON; serve journaled scrollback up to `logged_tail_bytes` in `fetch_session_history` when a scrollback journal is active so split-history replays pair the full scrollback journal prefix with the daemon's rewrapped visible viewport; reset `scroll_seq_baseline` on row or column changes in `ActorState::resize`.
- `2026-11-03T11:27-0800` `flutter/triage_client/lib/terminal/terminal_store.dart`: Preserve `cursorUpDebt` across `CSI J` (`Erase Below`) and increment `cursorUpDebt` on `CSI Ps F` (`CPL`) in `_collectGenuineNewlineIndices`, and use `effectiveViewport` (`styled_rows`) whenever `rawOutputPrefix` and `effectiveViewport` are both non-empty so split-history sessions render clean journaled scrollback plus the rewrapped viewport instead of replaying width-dependent raw `.tlog` cursor jumps.
- `2026-11-03T11:27-0800` `flutter/triage_client/lib/main.dart`: Reset DEC mouse/private modes in `SessionVm`'s clear listener; in `_refreshSessionSnapshot`, overlay `size`, `styled_rows`, `styled_rows_start`, `visible_rows`, and `cursor` from the `resizeSession` response and trigger a full-window HTTP history fetch and full replay when the host PTY is resized on the primary screen (`_onSessionViewFit` / `_selectSession`).
- `2026-11-03T11:27-0800` `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`, `flutter/triage_client/test/terminal_hardware_key_test.dart`: Add `_viewportCellAtGlobal` to convert pointer positions into 0-based viewport cell coordinates `(col, row)`, use it in `_emitAltScrollDelta`, and forward primary mouse button press, drag, and release events to `_terminal.mouseInput` when `_terminal.mouseMode != xt.MouseMode.none` and `Shift` is not held.
- `2026-11-04T07:47-0800` `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`, `flutter/triage_client/test/terminal_hardware_key_test.dart`: Track single-finger mobile tap candidates (`_mobileTapPointer`, `_mobileTapDownPosition`, `_mobileTapDownCell`) in `_handlePointerDown` when `_terminal.mouseMode != xt.MouseMode.none`, cancel the tap candidate if the pointer moves beyond `kTouchSlop` or emits an alternate-scroll step, and emit left mouse button press and release at the tapped viewport cell on `_handlePointerUp` so tapping TUI controls such as the Codex bottom scroll chip works on Android and iOS without interfering with touch swipe scrolling.

## Decisions

- `2026-11-03T11:27-0800` Populate `styled_rows`, `styled_rows_start`, and `cursor` in `fetch_session_history` / `serve_session_history` and use `effectiveViewport` whenever `rawOutputPrefix` and `effectiveViewport` are non-empty: when `useHttpHistory` is enabled, `attachSession` probes with `kHistoryLeaseProbeBytes` (`1024`), which omits `styled_rows`, and `/api/sessions/{id}/history` previously omitted `styled_rows` as well. That left `rawOutputViewport` empty on every HTTP attach and backward page, forcing `TerminalStore._reduceHistory` to replay raw `.tlog` cursor-up redraws (`\x1b[<N>A`) recorded at earlier PTY widths and mix lines across the buffer.
- `2026-11-03T11:27-0800` Re-fetch and full-replay HTTP history when `_refreshSessionSnapshot` resizes a primary-screen host PTY: on initial macOS startup before `TerminalPane` lays out, `_loadDaemonSession` resizes the session to `_estimatedTerminalRestoreSize`, and the subsequent `_onSessionViewFit` calls `_refreshSessionSnapshot(includeHistory: false)`. Re-fetching the full window and replaying with `preservePendingLive: true` after `resizeSession` ensures the terminal immediately reflows to the wide fitted viewport.

## Commits

- `d9e163b` - fix: forward desktop TUI mouse clicks and reflow HTTP split history
- `HEAD` - fix(mobile): emit TUI mouse click on single-finger tap
