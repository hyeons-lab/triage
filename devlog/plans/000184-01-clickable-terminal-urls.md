# Plan: Clickable Terminal URLs in Unified GPU Grid Renderer

## Thinking

After migrating the Flutter client to server-side cell sync (`TCG1`) and the unified GPU `RenderTerminalGrid` / `TerminalPane`, terminal output renders directly from `TerminalCellBuffer` cells without `xterm.js` or `xterm2`. Because `TerminalCellLine` already preserves `wrapsNext` (`LINE_FLAG_WRAPS_NEXT`), the client can detect `http://` and `https://` URLs across both single rows and soft-wrapped logical lines directly from visible/target `TerminalCellBuffer` rows—requiring zero wire-protocol or daemon changes.

Key interaction invariants to preserve:
1. **No interference with text selection**: Dragging across a URL (`distance > slop`) or Shift-clicking must select text rather than opening the URL; clicking when a non-collapsed selection is already active should clear the selection rather than launching a link; mobile long-press must select without firing a tap launch on finger lift.
2. **No interference with TUI mouse reporting (`mouseMode > 0`)**: Plain clicks when `mouseMode > 0` must continue forwarding mouse events to the TUI app, while `Ctrl+click` / `Cmd+click` (on desktop/web) bypasses mouse reporting when over a URL to open it.
3. **Strict cell hit-testing**: Clicking/hovering in empty margin padding to the right of `viewWidth * cellWidth` or below `totalLines * cellHeight` must not clamp to the edge cell and falsely trigger a URL.
4. **Safety**: Only `http` and `https` URIs with a non-empty host are recognized and launched via `openExternalUri`.

## Plan

1. **URL Detection & Cell Mapping (`flutter/triage_client/lib/terminal/terminal_links.dart`)**:
   - Define `TerminalLinkSegment` (`virtualRow`, `startCol`, `endCol`) and `TerminalLink` (`url`, `uri`, `segments`, `containsCell`).
   - Implement `detectLinksInRowRange(TerminalCellBuffer buffer, int firstRow, int lastRowExclusive)` and `detectLinkAtCell(TerminalCellBuffer buffer, CellOffset cell)` by grouping contiguous `wrapsNext` rows (bounded to avoid pathological scans and stopping at unloaded `null` scrollback rows), mapping UTF-16 code units back to `(row, col, width)` cell coordinates, matching `https?://` URLs, trimming trailing punctuation and unmatched closing `)` / `]`, and validating via `Uri.tryParse`.
2. **Buffer Revision & GPU Grid Link Rendering (`terminal_cell_buffer.dart`, `terminal_grid_render_box.dart`)**:
   - Add a monotonic `revision` counter on `TerminalCellBuffer` incremented on content mutations.
   - Add strict `hitTestCellOffset(Offset position)` (no edge clamping) and `linkAtOffset(Offset position)` on `RenderTerminalGrid`.
   - Cache visible-row `TerminalLink`s keyed by `(firstRow, lastRowExclusive, buffer.revision, buffer.viewWidth)` and render subtle underlines on URL cells (skipping cells with existing ANSI underline) plus an accentuated underline across all segments of `hoveredLink`.
3. **Pointer Hover & Click/Tap Activation (`terminal_pane.dart`)**:
   - Add `MouseRegion` around the grid to update `_hoveredLink` and switch between `SystemMouseCursors.click`, `SystemMouseCursors.text`, and `SystemMouseCursors.basic`.
   - Track `_linkTapPointer` / `_linkTapDownPosition` / `_linkTapDownLink` in `_handlePointerDown`/`Move`/`Up`/`Cancel`, clearing on drag, multi-touch, active selection dismissal, or mobile long-press, and supporting `Ctrl`/`Cmd` bypass when `mouseMode > 0`.
   - Launch validated URLs via `onOpenUrl ?? openExternalUri`.
4. **Tests & Verification**:
   - Add unit tests in `test/terminal/terminal_links_test.dart` (single-line, soft-wrapped, trailing punctuation, balanced parens, IPv6 brackets, wide CJK prefix, non-http scheme rejection, unloaded scrollback boundary).
   - Add render-box tests in `test/terminal/terminal_grid_render_box_test.dart` (`hitTestCellOffset` strict bounds, `linkAtOffset`, `hoveredLink` painting).
   - Add widget tests in `test/terminal/terminal_pane_links_test.dart` (click opens URL, drag selects instead of opening, active selection dismissal doesn't open, `mouseMode > 0` forwards plain click vs `Ctrl+click` opens URL, mobile tap vs long-press).
   - Run `flutter analyze`, `flutter test`, build & install release `triaged` with the updated web bundle, reload `triaged`, and verify.
