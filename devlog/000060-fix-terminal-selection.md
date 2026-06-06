# fix/terminal-selection

**Agent:** Claude Code (claude-opus-4-8) @ triage branch fix/terminal-selection

## Intent

Fix terminal text selection on the macOS client: shift-click does not extend the
selection, and there is no way to select more text than is visible on screen.

## Research & Discoveries

- 2026-06-05T20:56-0700 Root cause of shift-click doing nothing: xterm 4.0.0's
  `TerminalGestureDetector` wires its `TapGestureRecognizer.onTapUp` to `_handleTapUp`,
  which only calls `widget.onSingleTapUp`. `TerminalView` supplies `onTapUp` (not
  `onSingleTapUp`), and the detector never invokes its `onTapUp` field — so
  `TerminalView.onTapUp` is dead code. Our shift-click handler was attached to it and
  never fired.
- 2026-06-05T20:56-0700 Drag-select (`RenderTerminal.selectCharacters`) has no auto-scroll,
  so a drag cannot reach beyond the viewport. The viable path to off-screen text is
  drag-select → scroll → shift-click extend, which depends on shift-click working.
- 2026-06-05T20:56-0700 `TerminalViewState.renderTerminal` is public and
  `RenderTerminal.getCellOffset` already includes the scroll offset, so a pointer position
  hit-tests to the correct buffer cell even when scrolled.

## What Changed

- 2026-06-05T20:56-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` —
  Removed the dead `TerminalView.onTapUp` shift-click handler and reimplemented shift-click
  via the wrapping `Listener` (raw pointer events bypass the gesture arena, leaving xterm's
  normal drag-select intact). Added a `GlobalKey<xt.TerminalViewState>` to reach
  `renderTerminal.getCellOffset` for pointer→cell hit-testing. `_handlePointerDown` records
  shift+primary-button and the down position; `_handlePointerUp` extends the selection from
  the recorded anchor to the clicked cell when it was a shift-click (movement within slop).
  Imported `kPrimaryButton`.

## Decisions

- 2026-06-05T20:56-0700 Use raw pointer events (`Listener`) rather than a `GestureDetector`
  tap, to avoid competing with xterm's internal `TapGestureRecognizer`/`PanGestureRecognizer`
  in the gesture arena (which would risk breaking normal drag-select).
- 2026-06-05T20:56-0700 Deferred drag-edge auto-scroll: it conflicts with xterm's own drag
  handling (its drag-start offset goes stale once the buffer scrolls), so it needs to own
  the whole drag. Shift-click already restores the select→scroll→shift-click workflow that
  selects off-screen text; auto-scroll can be a follow-up.
- 2026-06-05T20:56-0700 Native pane only — that is the macOS desktop client the report is
  about; the web pane (`terminal_pane_web.dart`) is a separate path.

## Code review fixes (max-effort /code-review)

- 2026-06-06 `_extendSelectionTo` — apply `+1` to the trailing column when extending
  forward (`target.x >= anchor.x`), matching xterm's own `selectCharacters`
  (render.dart:289-291). Without it a forward shift-click dropped the clicked character
  from the selection/copy. (Finding #1, confirmed.)
- 2026-06-06 `_extendSelectionTo` — bail when `_terminal.buffer` is not identical to the
  buffer the anchor was recorded against, so a shift-click after a main↔alternate screen
  switch doesn't select an unrelated region of the now-active buffer. Capture the buffer in
  `_recordSelectionAnchor`. (Finding #4.)
- 2026-06-06 `_extendSelectionTo` — clamp the anchor's `x` (not just `y`) into the current
  grid, so a stale anchor after a clear / scrollback trim / width-reducing resize can't
  produce an out-of-range column. (Finding #6.)
- 2026-06-06 `_handlePointerUp` — wrap the `state.renderTerminal` access in try/catch:
  the getter asserts the viewport is mounted (`currentContext!`), which can be false if the
  pointer-up lands during a teardown/rebuild. (Finding #2.)
- 2026-06-06 Pointer tracking — key the in-progress shift-click by `event.pointer`
  (`_shiftClickPointer`/`_shiftClickDownPosition`) instead of a single shared slot, so
  concurrent pointers (multi-touch/trackpad) don't cross contexts; add an
  `onPointerCancel` handler and reset the pointer fields on terminal swap in
  `didUpdateWidget`. (Findings #3, #8.)
- 2026-06-06 NOT changed (documented): trackpad `buttons==0` shift-clicks (#7 — keeping the
  primary-button gate so shift+right-click doesn't extend; desktop mouse is fine),
  MediaQuery.padding off-by-padding (#9 — desktop padding is zero, latent), focus on every
  pointer button (#10 — pre-existing/minor), inherited SelectionMode (left as-is to keep
  intentional block-mode selection working), and the cleanup/altitude items
  (#11/#13 — the raw-Listener seam is the pragmatic workaround for xterm's dead onTapUp).
  Refuted: "shift-click pivots on the wrong end" — anchoring on the drag start and moving
  the other end is the standard text-selection model.

## Verification

- `flutter analyze lib/widgets/terminal_pane_stub.dart` — clean.
- `flutter test` — 71 passed.
- LIMITATION: under `FLUTTER_TEST` the pane renders a plain Container fallback, not the real
  `TerminalView`, so the gesture path cannot be widget-tested. Needs a device test: drag to
  select, scroll, shift-click → selection extends to the clicked cell (including into
  scrollback), and plain drag-select still works.

## Commits

- 16bd006 — fix(client): make shift-click extend terminal selection (xterm onTapUp is dead)
- HEAD — fix(client): harden shift-click selection (code-review findings)
