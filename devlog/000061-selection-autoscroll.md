# feat/selection-autoscroll

**Agent:** Claude Code (claude-opus-4-8) @ triage branch feat/selection-autoscroll

## Intent

Follow-up to #67: add drag-to-edge auto-scroll for terminal text selection (drag to the
top/bottom edge scrolls the view and extends the selection into off-screen content), and
assess web-pane parity.

## Research & Discoveries

- 2026-06-06T06:55-0700 xterm.dart 4.0.0's built-in drag-select pins the selection start
  to a viewport PIXEL (`selectCharacters(dragStartPixel, currentPixel)`), recomputed each
  update via `getCellOffset` which folds in the scroll offset — so the start drifts if the
  view scrolls mid-drag. No auto-scroll on edge, and no flag to disable the built-in
  selection.
- 2026-06-06T06:55-0700 Seams confirmed in xterm source: TerminalView's `Scrollable` uses
  our `scrollController`, and `RenderTerminal._scrollOffset == _offset.pixels` of that
  scrollable — so `_scrollController.position` is the same offset `getCellOffset` reads.
  `getCellOffset` returns an ABSOLUTE buffer cell. `TerminalViewState.renderTerminal` is
  public (asserts the viewport is mounted, so guard it).
- 2026-06-06T06:55-0700 Web pane uses xterm.js, whose drag-select already auto-scrolls
  (auto-scroll parity is free). xterm.js public selection API is only single-row `select`
  and whole-line `selectLines`, with no public arbitrary range or pixel->cell — so a
  char-precise web shift-click would need the private `_selectionService`.

## What Changed

- 2026-06-06T06:55-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` —
  Native drag-select with edge auto-scroll, owned from the wrapping `Listener` so the
  selection start is an absolute buffer cell (survives scrolling). Pointer-down captures
  the anchor cell; pointer-move past the slop enters drag mode, sets the auto-scroll
  velocity from edge depth, and schedules a microtask that re-applies the selection
  (overriding xterm's own per-frame selection). A periodic ticker scrolls
  `_scrollController` and re-extends to the held pointer's cell. Extracted
  `_applySelection` (clamp + +1 forward) and `_cellAtGlobal` (guarded hit-test), reused by
  shift-click. Wired `onPointerMove`; end the drag on up/cancel/terminal-swap; cancel the
  timer in dispose.

## Decisions

- 2026-06-06T06:55-0700 Own the drag and apply selection in a microtask rather than
  fighting xterm's PanGestureRecognizer in the gesture arena (which favours the deeper,
  built-in recognizer) — the microtask runs after xterm's update in the same frame, so our
  buffer-pinned selection deterministically wins without flicker.
- 2026-06-06T06:55-0700 Anchor as an absolute buffer cell (not a pixel or a tracking
  CellAnchor): `getCellOffset` already returns absolute coords, so a fixed CellOffset stays
  pinned to the right line as the view scrolls.
- 2026-06-06T06:55-0700 No web auto-scroll code (xterm.js native). Did NOT add web
  shift-click — it needs xterm.js private internals; documented as a separate item rather
  than shipping a fragile version-coupled hack.

## Verification

- `flutter analyze lib/widgets/terminal_pane_stub.dart` — clean.
- `flutter test` — 71 passed.
- LIMITATION: the gesture/auto-scroll path can't be widget-tested (the pane renders a
  Container fallback under FLUTTER_TEST). Needs a device test: drag-select toward the
  top/bottom edge — the view should auto-scroll and the selection should grow into
  scrollback; release to stop; normal in-viewport drag and shift-click still work.

## Commits

- HEAD — feat(client): drag-edge auto-scroll for terminal selection
