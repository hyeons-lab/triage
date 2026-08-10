# 000117-01 mobile selection copy

## Thinking

Reported from the Android client: text selects (the highlight appears) but no
copy menu ever follows, so a selection cannot be acted on.

The selection half works. xterm's gesture handler selects a word on long-press
and extends it on long-press-drag and drag, which is the highlight being seen.
What is missing is any route from a selection to the clipboard on touch:

- `TextInputClient.showToolbar`, the callback Android raises its own floating
  selection toolbar from, is an empty stub in xterm 4.0.0
  (`custom_text_edit.dart`, body a commented-out `print`). Nothing else in the
  package offers a selection toolbar or context menu.
- The pane's only copy path is `_handleTerminalKeyEvent`, which fires on the
  hardware copy chord (control+shift+C, meta+C on Apple). A soft keyboard cannot
  produce it.
- The accessory bar has no copy key.

So the gap is complete rather than a misconfiguration, and it is touch-only:
desktop has had a working copy path all along.

The affordance to add is a floating Copy button over the selection, matching
what the platform does elsewhere and what the report expected. The copy itself
must go through `terminalSelectionText`, the same helper the chord uses, or the
button would re-introduce the dropped-blank-cell bug that helper exists to fix
(a TUI that lays out columns by moving the cursor would copy with its columns
concatenated).

Two structural choices worth stating. The button is a sibling of the terminal
inside a `Stack` rather than an `OverlayEntry`: it is then torn down with the
pane, cannot outlive a session swap, and sits outside the `Listener` that drives
selection, so tapping it cannot perturb the selection it is about to copy. And
its placement is a pure function in its own file, because the interesting part
is the edge cases (no room above, either horizontal edge, scrolled out of view)
and those are worth testing without a rendered terminal.

The `Stack` has one trap: it hands non-positioned children loose constraints,
where the terminal previously sat under `Expanded` and filled the pane. The grid
size is derived from those pixels, so it needs `StackFit.expand` to keep the
old layout exactly.

## Plan

1. Worktree `fix/mobile-copy` from `origin/main`, upstream cleared.
2. `lib/terminal/copy_button_layout.dart`: `placeCopyButton`, preferring above
   the selection, flipping below when cramped, clamping horizontally, and
   returning null when the anchored cell is not visible.
3. Unit-test that helper directly, including both edges and both flips.
4. `terminal_pane_stub.dart`: track the offered range from the xterm controller,
   position the button through the helper, copy via `terminalSelectionText` +
   `Clipboard.setData`, then clear the selection as the confirmation.
5. Drop the offered range on a terminal swap; reposition on scroll; defer the
   rebuild when the notification lands mid-frame.
6. `dart format`, `flutter analyze`, `flutter test`, then build and install to
   the device, since the widget suite renders a fallback and cannot reach this.
7. Devlog, commit, push once, open the PR.
