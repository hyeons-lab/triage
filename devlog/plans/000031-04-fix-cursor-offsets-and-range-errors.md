## Thinking

We are addressing the misplaced cursor regression in the remote terminal sessions:
1. When Wezterm's snapshot is retrieved, the daemon returns an absolute cursor row `initialCursorRow`.
2. On the client side, `_mergeVisibleAndStyledRows` constructs the `fallbackRows` list.
   - If the client fetches history, `fallbackRows` starts at absolute row 0.
   - If the history fetch is skipped or fails, `fallbackRows` starts at `styled_rows_start` (e.g., 50).
3. The client has been using the absolute `widget.initialCursorRow` directly in `_writeInitialContent()`. If history is not merged, `widget.initialCursorRow` (e.g. 50) is greater than `fallbackRows.length` (24), throwing a RangeError in the rendering loop, which silently aborts the entire `_onFit()` execution and leaves the terminal misplaced.
4. Furthermore, as new WebSocket output arrives, it is written directly to xterm.js and appended to `session.rows`. However, the backup `session.initialCursorRow` is never updated. When the terminal pane is rebuilt (e.g. on resize or switching tabs), it re-renders the expanded list of rows with a stale cursor position.
5. In addition, our previous attempt to trim trailing blank lines from the viewport created desynchronization with Wezterm's screen rows. If the browser viewport is smaller than Wezterm's viewport (e.g. `fittedRows = 20` but Wezterm has 24 rows), writing all 24 rows causes xterm.js to scroll by 4 lines, pushing the active cursor/prompt at row 0 out of view.

To solve this:
1. **Relative Cursor Coordinates**: Map `initialCursorRow` to be relative to `fallbackRows` directly in `lib/main.dart` when creating the remote `SessionVm` instances:
   `relativeCursorRow = initialCursorRow - (visibleRowsJson.length - rows.length)`
   This ensures `initialCursorRow` is always between `0` and `fallbackRows.length - 1` and never throws a RangeError.
2. **Windowed Initial Write**: Instead of scrolling xterm.js arbitrarily, select a window of `fallbackRows` of length exactly `fittedRows` (or fewer, if `L <= fittedRows`) to write to xterm.js. This guarantees xterm.js never scrolls on initial write.
   Align the window dynamically so that the cursor row `C` is always visible in the viewport:
   `int startRow = L - fittedRows;`
   `if (C < startRow) startRow = C; else if (C >= startRow + fittedRows) startRow = C - fittedRows + 1;`
3. **Cursor Positioning**: Position the cursor relative to the written slice: `C - startRow + 1`. This aligns the cursor exactly with the prompt and content.

## Plan

1. **Modify Main Entrypoint**: Update `lib/main.dart` in `flutter/triage_client/lib/main.dart` (lines 535 and 751) to compute and pass the relative cursor row.
2. **Modify Web Terminal View**: Update `_writeInitialContent` in `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to implement windowed writing and relative cursor positioning.
3. **Update Unit Tests**: Update `flutter/triage_client/test/cursor_position_test.dart` to verify the relative cursor calculation and windowing logic.
4. **Validate**:
   - Run `flutter test` across the client codebase to make sure tests pass.
   - Verify layout and cursor alignment in the client.
5. **Devlog Update**: Document everything in `devlog/000031-feat-zero-downtime-handover.md`.
