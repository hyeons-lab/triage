# Plan: fix terminal shift-click selection extension

## Thinking

User: "there is no way to select more text than is shown on the screen. shift +
click doesn't seem to work to extend the selection." (macOS desktop client.)

Investigated xterm 4.0.0's gesture stack:
- `terminal_pane_stub.dart` wired shift-click to `TerminalView.onTapUp`.
- In xterm 4.0.0, `TerminalGestureDetector`'s `TapGestureRecognizer` routes tap-up to
  `_handleTapUp`, which only calls `widget.onSingleTapUp`. `TerminalView` does NOT pass an
  `onSingleTapUp` and instead supplies `onTapUp`, which the detector never invokes. So
  `TerminalView.onTapUp` is dead code — our shift-click handler never ran. That is the
  whole "shift-click does nothing" bug.
- Drag-select uses `RenderTerminal.selectCharacters(from, to)` with NO auto-scroll, so a
  drag can't reach beyond the visible viewport. The intended way to grab off-screen text
  is therefore: drag-select something visible, scroll, then shift-click to extend — which
  needs shift-click working.

`RenderTerminal.getCellOffset(localOffset)` is reachable via the public
`TerminalViewState.renderTerminal` getter and already adds the scroll offset, so it maps a
pointer position to the correct buffer line even when scrolled. `_xtermController` +
`buffer.createAnchorFromOffset` set the selection; anchors are buffer-line based so they
survive scrolling.

Fix: stop using the dead `onTapUp`. Drive shift-click from the existing `Listener` (raw
pointer events bypass the gesture arena, so xterm's normal drag-select is untouched):
record shift+primary-button on pointer-down, and on pointer-up — if it was a click, not a
drag — hit-test the position to a cell and extend the selection from the recorded anchor.

Scope: native pane only (`terminal_pane_stub.dart`); that is the macOS app. Drag-edge
auto-scroll is a larger, riskier change (it conflicts with xterm's own drag handling) and
is deferred — shift-click already restores the select→scroll→shift-click workflow.

Verification limit: under `FLUTTER_TEST` the pane renders a plain Container fallback, not
the real `TerminalView`, so this gesture path cannot be widget-tested. Needs a device test.

## Plan

1. `terminal_pane_stub.dart`:
   - Add `GlobalKey<xt.TerminalViewState> _terminalViewKey`; set it on the `TerminalView`.
   - Add pointer-context fields (`_pointerDownPosition`, `_shiftAtPointerDown`, slop const).
   - `_handlePointerDown`: focus + record shift&primary + position.
   - `_handlePointerUp`: if shift-click within slop, `getCellOffset(globalToLocal(pos))` →
     `_extendSelectionTo(target)`.
   - Wire the `Listener` to both handlers; remove the dead `onTapUp` from `TerminalView`.
   - Import `kPrimaryButton`.
2. `flutter analyze` + `flutter test` clean (existing 71 pass; gesture path needs device).
