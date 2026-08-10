# 000117 fix/mobile-copy

**Agent:** Claude (claude-opus-5, 1M context) @ triage branch fix/mobile-copy

## Intent

Give the touch clients a way to copy a selection. Selecting text on Android
worked, but nothing could act on the result. Plan:
[plans/000117-01-mobile-copy.md](plans/000117-01-mobile-copy.md).

## What Changed

2026-08-09T17:36-0700 `flutter/triage_client/lib/terminal/copy_button_layout.dart`
(new): `placeCopyButton`, the pure geometry for the floating button. Prefers a
position above the selection so it never covers the text it acts on, flips below
when it starts too near the top, and clamps horizontally so a selection at
either edge still gets a fully visible button. It anchors to the selection's
first *visible* line, so a long selection scrolled off the top keeps its button,
and hides when no part of the selection's span is on screen or the viewport is
too small to hold the button in either axis.

2026-08-09T17:36-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
tracks the selection the button is offering (`_copyTarget`) from a second
listener on the xterm controller, renders the button as a `Stack` sibling of the
terminal, and copies through `terminalSelectionText` + `Clipboard.setData`
before clearing the selection. The offered range is dropped on a terminal swap,
repositioned on scroll, and the rebuild is deferred when the notification
arrives mid-frame. The `Stack` is `StackFit.expand`. Adds the `_CopyButton`
widget, styled off the accessory bar rather than the ambient Material theme.

2026-08-09T17:37-0700 `flutter/triage_client/test/terminal/copy_button_layout_test.dart`
(new): 12 cases over the placement helper, covering both flips (including the
exact boundary), both horizontal edges, both scroll-away directions, a viewport
too small in each axis, and a multi-line selection scrolled off the top.

## Decisions

2026-08-09T17:20-0700 A floating button over the selection rather than a copy
key in the accessory bar. Reasoning: chosen by the user from three options. It
is what the platform does elsewhere, so it is what a selection leads a user to
expect; the accessory bar alternative was simpler but scrolls horizontally, so
the key could sit off-screen exactly when needed.

2026-08-09T17:25-0700 Copy goes through `terminalSelectionText`, not
`Buffer.getText`. Reasoning: it is the same path the hardware chord already
takes, so a phone and a keyboard produce identical text. Calling xterm's own
getText here would silently drop blank cells and concatenate the columns of any
TUI that lays out by moving the cursor, which is the bug that helper was written
to fix.

2026-08-09T17:26-0700 A `Stack` sibling rather than an `OverlayEntry`.
Reasoning: it is torn down with the pane, so it cannot outlive a session swap or
leak an entry; and it sits outside the `Listener` that drives selection, so
tapping the button cannot enter the pointer paths that would alter the selection
it is about to copy. An overlay would have needed manual insert/remove against
every one of those lifecycles.

2026-08-09T17:30-0700 Placement extracted as a pure function with its own tests.
Reasoning: the widget suite renders a fallback view under `FLUTTER_TEST` and
never builds a real terminal, so the button cannot be exercised there at all.
The geometry is where the real edge cases live, and it can be tested without a
rendered terminal. Matches how `terminal_selection.dart` and
`terminal_scroll_anchor.dart` are already split out.

2026-08-09T17:31-0700 Clearing the selection is the only confirmation.
Reasoning: the highlight and the button both vanish, which is what Android's own
toolbar does on copy. A toast or snackbar would cover the accessory bar directly
below it.

## Issues

2026-08-09T17:15-0700 Root cause, for the record: xterm 4.0.0 implements
`TextInputClient.showToolbar` as an empty stub, and that is the callback Android
raises its own selection toolbar from. Nothing else in the package offers a
context menu, and the pane's only copy path needed a hardware chord a soft
keyboard cannot produce. Selection itself was never broken.

2026-08-09T17:33-0700 Wrapping the terminal in a `Stack` gave it loose
constraints where `Expanded` had previously made them tight, so it would have
shrink-wrapped instead of filling the pane. The grid size is computed from those
pixels, so this would have mis-sized the session rather than just looking wrong.
Fixed with `fit: StackFit.expand`.

2026-08-09T17:34-0700 The scroll listener called `setState` directly, but this
pane drives `jumpTo` itself (cursor follow, anchor re-pin, drag auto-scroll), so
the notification can arrive during layout, where `setState` throws. Both this
and the selection listener now go through `_rebuildForCopyButton`, which defers
to a post-frame callback when it fires inside `persistentCallbacks`.

2026-08-09T17:35-0700 The first version of the placement helper only hid the
button through its does-it-fit check, which is not the same as asking whether
the selection is visible: an anchor just past the bottom edge still leaves room
above it, so the button would have been placed pointing at text off-screen.
Caught by writing the test for it, and fixed with an explicit visibility guard.

2026-08-09T18:05-0700 Review loop, round 1: `dart format lib/ test/` had
reformatted five files this branch never touched, including 2091 lines of the
generated FlatBuffers file that `scripts/generate-dart-flatbuffers.sh` would
revert on its next run. Reverted; formatting is now scoped to the files actually
edited. The same round caught four em dashes this branch introduced, against the
absolute no-em-dash rule.

2026-08-09T18:20-0700 Review loop, round 1, correctness: the button positioned
itself from a stored `BufferRange`, but `TerminalController.selection` recomputes
its rows from live buffer line indices that shift as scrollback trims, and
trimming emits no notification. The stored range silently de-anchored from its
own highlight, and when the anchor line was trimmed away entirely the controller
returned null while the button stayed on screen doing nothing. Position and text
now both read the live controller through `_liveCopySelection`.

2026-08-09T18:25-0700 Review loop, round 1: repositioning was driven only by
`ScrollController` notifications, but xterm's stick-to-bottom moves the viewport
through `ScrollPosition.correctBy` during layout, which does not notify. Output
growth, the ordinary case, never repositioned the button. Also hooked to
`_onTerminalContentChanged`.

2026-08-09T18:30-0700 Review loop, round 2: that content hook then leaked. A
selection whose anchor line trims away detaches without notifying, so
`_copyTarget` stayed set while the button was no longer drawn, and every
subsequent write rebuilt the pane subtree for the life of the session. The hook
now retires a target whose live selection has gone. The deferred rebuild is also
latched, matching the existing `_repinScheduled` pattern, so a burst of writes
collapses to one rebuild.

2026-08-09T18:35-0700 Review loop, round 2: three comments described behaviour
the code no longer had, including one justifying a guard with a claim about when
`TerminalController` notifies that is not true of xterm 4.0.0 (the real reason is
that a drag re-sets the selection on every pointer move). Corrected against the
code. Worth noting as a repeat of an earlier lesson: a wrong comment is worse
than none, because it is read as verified.

2026-08-09T18:55-0700 Review loop, round 3: retiring the copy target on any
`_liveCopySelection == null` was too broad. A full-screen program switching to
the alternate screen made that true, and returning to the main screen emits no
controller notification, so the target never re-armed: the highlight stayed
painted with no way to copy it, which is the exact failure this change exists to
remove. Retirement now tests the controller's own selection, and the alternate
screen is treated as the temporary visibility condition it is. The two screen
buffers are fixed objects, so the identity guard re-matches by itself on return.

2026-08-09T19:00-0700 Review loop, round 3: the tap-time buffer guard was a
second copy of the one `_liveCopySelection` already applies, behind a bool
parameter. Folded into the button's own callback.

2026-08-09T19:20-0700 Review loop, round 4: the round 3 fix traded one leak for
another. Retiring only on a dead selection meant a selection made *on* the
alternate screen was never retired at all (leaving the alt screen does not
detach its lines), so the per-write rebuild ran indefinitely. The two concerns
are now separated: retire when the selection is gone, rebuild only when the
offered selection belongs to the screen on show, and otherwise do neither. That
also removes the rebuild-per-frame while a full-screen program is running with a
main-screen selection held, which no amount of waiting could have ended, since
the main buffer is not written while the alt screen is up.

2026-08-09T19:25-0700 Not fixed, noted: xterm's `Buffer.clearScrollback` (what
`ESC[3J` reaches) trims lines without detaching them or advancing the absolute
start index, so anchors into scrollback survive a `clear` pointing at the wrong
rows. A selection held across a `clear` can therefore misplace the button. This
is an xterm 4.0.0 defect that predates this change and affects the existing
shift-click anchor path the same way; fixing it belongs upstream or in a
dedicated change, not here.

## Verification

- `flutter analyze lib/`: no new issues (3 pre-existing warnings in `main.dart`
  and `triage_websocket_client.dart`, both untouched here).
- `flutter test`: 296 passing, including the 12 new placement cases.
- Built and installed to a Pixel 10 Pro Fold, since the widget suite cannot
  reach this path. Confirmed working on the device.
- Review loop at high effort, two rounds, two reviewers per round.

## Research & Discoveries

2026-08-09T19:40-0700 This gap is filed upstream as TerminalStudio/xterm.dart
issue 217, "Add selection handles and context menu on mobile" (open since
2026-02-26), which describes the same symptom in the same terms: selection works
and highlights, but there is no way to copy it without a hardware keyboard. Its
only replies are two "+1" comments with no maintainer response, and the latest
xterm release is two years old, so waiting for an upstream fix was never viable.
The related `TerminalView.onTapUp` dead callback this pane already works around
is issue 178, open since 2023. Worth knowing: the workaround circulating in that
thread is `buffer.getText(range)`, which is exactly the call that drops blank
cells, so `terminalSelectionText` is already better than the advice there.

## Next Steps

- Upstream 217 asks for selection *handles* as well as a menu. This change
  delivers the menu half; handles (draggable ends to adjust a selection before
  copying) are agreed as a follow-up branch.
- The mobile web client shares the accessory bar but has its own pane; whether
  its touch selection can reach the clipboard is unverified and worth a look.

## Commits

- HEAD: fix(triage_client): let a touch selection reach the clipboard
