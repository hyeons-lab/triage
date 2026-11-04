# Plan 000176-01: Fix Codex Fullscreen Scroll Chip and Wide History Reflow

## Thinking

1. **Codex fullscreen bottom chip click and wheel coordinates**:
   - On desktop (`!_isMobile`), `TerminalPane` in `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` intercepts primary pointer down/move/up events to manage cell-anchored drag selection (`_dragPointer`), and `package:xterm`'s `TerminalView` does not forward mouse taps or clicks to `Terminal.mouseInput`.
   - Furthermore, `_cellAtGlobal` calls `render.getCellOffset`, which adds ` RenderTerminal._scrollOffset` (`lineOffset`) to `row`, returning an absolute buffer row rather than a 0-based viewport row. When a session has scrollback lines in its main buffer and enters mouse reporting without switching to the alternate buffer (or when scrollback exists), `_cellAtGlobal` clamps `rawCell.y` to `viewHeight - 1`, pinning every click and wheel report to the bottom row.
   - Adding `_viewportCellAtGlobal` (computing 0-based viewport `(col, row)` directly from `render.globalToLocal(globalPosition)` and `render.charSize`) and forwarding primary button down/move/up to `_terminal.mouseInput` when `_terminal.mouseMode != xt.MouseMode.none` and `Shift` is not pressed fixes both clicking the bottom scroll chip and wheel coordinates.

2. **History line mixing and narrow layout on wide laptops**:
   - When `useHttpHistory` is true, `attachSession` uses `historyBytes: 1024` (`LEASE_PROBE_HISTORY_BYTES`), which returns `metadata_snapshot()` with `styled_rows: []`.
   - The subsequent `GET /api/sessions/{id}/history` (`fetch_session_history` in `crates/triaged/src/session.rs` and `serve_session_history` in `crates/triaged/src/http.rs`) omitted `styled_rows`, `styled_rows_start`, and `cursor` from the `THS1` JSON metadata, and truncated `raw_output_prefix` at `seam` instead of serving journaled scrollback up to `logged_tail_bytes`.
   - Because `styled_rows` was missing from HTTP history responses, `rawOutputViewportFromSnapshot` always returned `Uint8List(0)`, and `useViewportForRaw` in `TerminalStore._reduceHistory` was always `false`. Even when `styled_rows` was present, `_collectGenuineNewlineIndices` reset `cursorUpDebt = 0` on `CSI J` (`0x4a`, Erase Below), which appears immediately after `CSI <N> A` in TUI redraws, causing `TerminalStore` to replay raw `.tlog` cursor-addressed redraws recorded at earlier PTY widths (`47` or `98` cols) onto the wider viewport and mix lines.
   - In addition, when `TerminalPane` first laid out at the wide laptop size and called `_onSessionViewFit` -> `_refreshSessionSnapshot(includeHistory: false)`, `_refreshSessionSnapshot` resized the host PTY to the wide size but discarded the `resizeSession` snapshot and skipped history replay because `includeHistory` was `false`.

## Plan

1. **Daemon (`crates/triaged/src/storage.rs`, `crates/triaged/src/session.rs`, `crates/triaged/src/http.rs`)**:
   - In `storage.rs`, increase the backward segment scan in `read_multi_segment_replay_tail` to 32 segments and only break on `last_newline_segment_bytes` when `initial_alt.is_some()` or mouse tracking is not active.
   - In `session.rs`, add `styled_rows`, `styled_rows_start`, and `cursor` to `SessionHistoryCoordinates` and `SessionHistoryResponse`, populate them in `HistoricalSession::history_coordinates` and `ActorState::history_coordinates`, serve journaled scrollback up to `logged_tail_bytes` in `fetch_session_history` when the journal is non-empty, and reset `scroll_seq_baseline` when `rows` or `cols` changes in `ActorState::resize`.
   - In `http.rs`, serialize `styled_rows`, `styled_rows_start`, and `cursor` in `serve_session_history` `meta` JSON and add assertions to `history_http_tests`.

2. **Flutter client (`terminal_store.dart`, `main.dart`, `terminal_pane_stub.dart`)**:
   - In `terminal_store.dart`, update `_collectGenuineNewlineIndices` to handle `CSI Ps F` and only reset `cursorUpDebt` on `CSI 2 J` / `CSI 3 J` (`firstParam >= 2`), and enable `useViewportForRaw` whenever `rawOutputPrefix.isNotEmpty && effectiveViewport.isNotEmpty`.
   - In `main.dart`, reset DEC mouse/private modes in `SessionVm`'s clear listener, capture `resizedSnapshot` in `_refreshSessionSnapshot`, and trigger a full-window HTTP history fetch and full replay (`preservePendingLive: true`) when `resizeSession` resizes a primary-screen session.
   - In `terminal_pane_stub.dart`, add `_viewportCellAtGlobal`, use it in `_emitAltScrollDelta`, and forward desktop primary mouse button press/move/release when `_terminal.mouseMode != xt.MouseMode.none` and `Shift` is not pressed.
   - Add widget and unit tests in `terminal_hardware_key_test.dart`.
