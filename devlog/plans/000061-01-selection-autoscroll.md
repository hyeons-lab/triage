# Plan: drag-edge auto-scroll for terminal selection (+ web parity assessment)

## Thinking

Follow-up to #67 (shift-click). Two asks: (1) native drag-to-edge auto-scroll that
extends the selection into off-screen content; (2) web-pane parity.

### Native (the real gap)

xterm.dart 4.0.0's built-in drag-select (`RenderTerminal.selectCharacters(from, to)`
driven by its PanGestureRecognizer) pins the selection START to a viewport PIXEL and
recomputes it every update via `getCellOffset`, which folds in the scroll offset. So if
the view scrolls during a drag, the start pixel maps to a different buffer cell — the
start drifts. There is also no auto-scroll when the pointer reaches the edge. There is
no TerminalView flag to disable the built-in selection.

Seams verified in xterm 4.0.0 source:
- TerminalView builds a `Scrollable` with our `scrollController`; `RenderTerminal._scrollOffset`
  == `_offset.pixels` of that scrollable. So driving `_scrollController.position` moves
  exactly the offset `getCellOffset` reads. `getCellOffset` returns an ABSOLUTE buffer
  cell (pixel + scrollOffset), clamped to the grid.
- `TerminalViewState.renderTerminal` is public; `getCellOffset`/`globalToLocal`/`size`
  are usable. `renderTerminal` asserts the viewport is mounted (currentContext!), so
  guard the access.

Approach: own the drag from raw pointer events (the existing Listener), so the start is
an ABSOLUTE buffer cell captured at pointer-down (survives scrolling). Apply the
selection in a microtask so it runs after xterm's own onDragUpdate in the same frame and
deterministically wins (no flicker, no gesture-arena fight). When the pointer is within
an edge zone, run a periodic ticker that scrolls `_scrollController` (scaled by edge
depth) and re-extends to the held pointer's now-different cell, growing the selection.
Keep the +1 forward-inclusive rule (from #67) and reuse the same apply/hit-test helpers.

### Web parity

The web pane uses xterm.js, whose drag-select ALREADY auto-scrolls — so the auto-scroll
feature has web parity for free (verify on device). xterm.js's public selection API is
only `select(col,row,length)` (single row) and `selectLines(start,end)` (whole lines),
with no public arbitrary multi-row range and no public pixel->cell hit-test, so a
char-precise shift-click extend on web would require the private `_core._selectionService`
(version-fragile). Decision: do NOT add a fragile private-API hack; document the gap and
let the user decide. (Shift-click was the #67 native-only item; web drag+autoscroll
already covers selecting off-screen text.)

## Plan

1. `terminal_pane_stub.dart` (native):
   - Add drag state (`_dragPointer`, `_dragDownPosition`, `_dragLastPosition`,
     `_dragAnchorCell`, `_dragSelecting`, `_dragExtendScheduled`) and auto-scroll state
     (`_autoScrollTimer`, `_autoScrollVelocity`, edge/tick/step consts).
   - Extract `_applySelection(anchorCell, targetCell)` (clamp + +1 forward) and
     `_cellAtGlobal(global)` (guarded hit-test); have shift-click reuse them.
   - Pointer-down starts a drag (non-shift primary) capturing the anchor cell;
     pointer-move crosses slop -> drag mode, updates auto-scroll, schedules a microtask
     extend; ticker scrolls + re-extends; up/cancel/terminal-swap end the drag.
   - Wire `onPointerMove`; cancel the timer in dispose; `_endDrag()` in didUpdateWidget.
2. Web: no code change for auto-scroll (xterm.js native). Document shift-click gap.
3. `flutter analyze` + `flutter test` clean; gesture path needs device verification.
