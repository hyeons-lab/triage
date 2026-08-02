# 000114 fix/rail-group-drag

**Agent:** Claude (claude-opus-5, 1M context) @ triage branch fix/rail-group-drag

Numbered 000114 rather than 000113: that number was taken by the
`fix/web-clipboard` branch, which was still open when this one started and has
since merged as #132.

## Intent

Dragging a group header looked like it detached the label from the rows it
names. Reported as "I shouldn't be able to drag just the header without the
associated rows also moving."

The drop was never wrong: `resolveRailReorder` already moves the whole group,
and `dragging a header pins its whole group` covers it. What was wrong was the
*feedback*, which showed a lone header travelling while its rows sat still.

## What Changed

2026-08-01T19:05-0700 `flutter/triage_client/lib/main.dart`: added
`_draggingRailGroup` to the app state, set on a header drag and cleared on drop,
on drag end, and alongside the `cancelReorder` in `_regroupRail`. `SessionRail`
takes it as `draggingGroupKey` plus `onRailDragStart` / `onRailDragEnd`, wires
the list's `onReorderStart` / `onReorderEnd`, and draws the dragged group's rows
at 40% opacity.

2026-08-01T19:12-0700 `flutter/triage_client/test/widget_test.dart`: three
tests: the lift appears and is scoped to the dragged group, a row drag lifts
nothing, and a mid-drag re-group releases the lift.

2026-08-01T22:05-0700 `flutter/triage_client/lib/main.dart`: wrapped the rail's
`ReorderableList` in a `Listener` with `onPointerCancel`, so a drag the platform
takes back ends the treatment. Found in review; see Issues.

2026-08-01T22:10-0700 `flutter/triage_client/lib/main.dart`: the row's `Opacity`
is now unconditional (1.0 when not lifted) instead of being inserted only during
a drag. Also found in review; see Decisions.

2026-08-01T22:14-0700 `flutter/triage_client/test/widget_test.dart`: added
`a cancelled pointer releases the lift`, and the `lifted` helper now asserts the
row it is asked about actually renders.

2026-08-01T22:55-0700 `flutter/triage_client/lib/main.dart`: the same `Listener`
also takes `onPointerUp`, which covers a fourth way a drag ends. Found in the
second review round; see Issues.

2026-08-01T23:20-0700 `flutter/triage_client/lib/main.dart`: the dead
`_railDragEnded()` at the top of `_reorderRail` is gone. From the third review
round; see Issues.

## Decisions

2026-08-01T19:02-0700 Put `_draggingRailGroup` on the app state rather than
inside `SessionRail`. Reasoning: clearing it is the same invariant as cancelling
the drag, and `_regroupRail` is what cancels. A copy owned by the rail could not
be reached from there, so a re-group arriving mid-drag would leave it set over a
drag the list had already killed.

2026-08-01T19:08-0700 Dimmed the rows in place rather than moving them.
Reasoning: `ReorderableList` lifts exactly one child, and reordering the rest
mid-drag is what duplicates its per-child `GlobalKey` and throws. That is the
same constraint `_regroupRail` already documents. Opacity also leaves row
heights alone, which matters because the drop targets *are* the row geometry:
collapsing or removing a row would move the landing slots out from under the
gesture choosing between them.

2026-08-01T19:10-0700 Left the drop behaviour untouched. Reasoning: it was
already correct, and the report was about what the drag looked like.

2026-08-01T22:10-0700 Made the `Opacity` unconditional rather than conditional.
Reasoning: swapping between `Opacity(child: tile)` and a bare `tile` changes the
shape of the tree, which hands `SessionListTile` a new element on drag start and
another on drop. The tile is stateful and owns an `OverlayPortalController` and
a `LayerLink`, so an unrelated header drag was silently remounting it twice.
A constant `Opacity` whose value moves between 1.0 and 0.4 renders identically;
at 1.0 the layer is skipped, so it costs nothing when nothing is being dragged.

## Issues

2026-08-01T19:09-0700 **A count badge on the dragged header does not work.**
Labelling the lifted header with "2 sessions" was written, and rendered nothing:
`ReorderableList` builds the floating proxy from the child captured when the
drag began, so it does not rebuild when the state driving that label changes.
`onReorderStart` cannot get ahead of it either, since the capture happens in the
same frame. Removed rather than shipped dead, and the constraint is documented
on `draggingGroupKey`: anything that must react during a drag has to live in the
list body, which is why the dimming works and the badge could not.

2026-08-01T22:05-0700 **A cancelled pointer left a group dimmed with no drag in
flight.** Found by the review loop. The first version cleared the treatment on
`onReorderEnd` and alongside the `cancelReorder` in `_regroupRail`, which is two
of the ways a drag ends. `SliverReorderableListState._dragCancel` calls only
`_dragReset()`, raising neither callback, so a pointer the platform takes back
(a system gesture over the touch rail, a lost capture) left the flag set until
the next drag start or re-group. The irony is that `_regroupRail`'s own doc
already named the pointer-cancel path as callback-free; only the `cancelReorder`
half of that sentence had been acted on. Fixed with an `onPointerCancel`
`Listener` around the list, which sees the cancel because it is dispatched along
the hit-test path recorded at pointer-down.

2026-08-01T22:14-0700 **Two of the assertions were guarding nothing.** Also from
the review loop. `lifted()` reads `widgetList<Opacity>` under a row finder, and
an empty match returns false, so `a row drag lifts nothing` (all `isFalse`) would
have passed just as happily if the rows had stopped rendering entirely. The
helper now asserts the row is present first, with `findsOneWidget`:
`_ReorderableItemState.build` returns a `SizedBox` for the item being carried, so
the carried child is drawn in the proxy and nowhere else, never twice.

2026-08-01T22:55-0700 **A fourth callback-free exit, found in the second review
round.** `SliverReorderableListState.didUpdateWidget` calls `cancelReorder()`
whenever `itemCount` changes, and like the other cancel paths it raises neither
callback. A session closing or a reconnect reloading the rail mid-drag therefore
killed the drag with the treatment still on, and the pointer-cancel `Listener`
added earlier does not rescue it: `_dragReset` disposes the recognizer, and
`MultiDragPointerState.dispose` does not forward a cancel to its client, so no
synthetic cancel follows.

Answered by adding `onPointerUp` to the same `Listener` rather than by chasing
the callers that can change the rail's length. The raw pointer events keep
arriving whatever the list has done with its own state, because the hit-test path
is recorded at pointer-down and held until the pointer lifts. What it does not do
is clear the treatment at the moment the drag dies; it clears when the finger
comes up. That leaves the dim showing over a drag that is already dead for the
rest of the gesture, which is visible but self-correcting, against a dim that
previously outlived the gesture entirely.

2026-08-01T23:20-0700 **A fifth exit, and a wrong fix for it, both caught in
review.** The third round pointed out that the rail can be unmounted under a held
drag, when a pairing challenge or a dropped connection swaps it for another
screen, and that `SliverReorderableListState.dispose` resets the drag silently.
Believing the `Listener` died with the list it wraps, the two call sites that
swap the rail out were made to clear the treatment themselves.

The fourth round said that premise was false, and it was right. A probe settled
it: a `Listener` removed from the tree between pointer-down and pointer-up still
receives `onPointerUp`, because `GestureBinding` dispatches along the hit-test
path recorded at pointer-down and never checks that the targets are still
mounted. Both clears were dead code and are gone; the pointer listener covers
this case as it does the others.

Worth noting how nearly this was missed. The first attempt at the probe wrapped a
childless `SizedBox`, which does not hit test, so the listener never received
pointer-down either and the result read as "0 ups, the claim holds". It agreed
with what had already been written, which is exactly when a result deserves the
least trust. Adding an `onPointerDown` counter is what exposed it.

So: five ways for the drag to end, four of them silent, all four covered by
watching the pointer rather than the list. The count went two, three, four, five
across the review rounds, which is the honest summary of this widget:
`ReorderableList` reports its happy path and nothing else.

2026-08-01T23:35-0700 **Trimmed a vacuous assertion.** `a row drag lifts nothing`
also asserted on the row being dragged, which cannot fail: the list builds the
carried item as a `SizedBox` and renders only the proxy, captured before
`onReorderStart` runs. The neighbour assertion is the one with teeth.

2026-08-01T23:20-0700 **Removed the belt-and-braces clear in `_reorderRail`.**
Two reviewers flagged it and a mutation confirmed it: `onReorderEnd` and the
listener's `onPointerUp` both fire at pointer-up, ahead of `onReorderItem`, so it
could never be the thing that cleared. It was defending an ordering Flutter
guarantees while the paths that genuinely had no guard went unnoticed, which is
roughly the opposite of belt and braces.

## Verification

- `flutter analyze`: 4 issues, all pre-existing on `main`, none in the touched code.
- `flutter test`: 284 passed (280 before this branch, plus the 4 added here).

Mutation-tested, all four killed:

| Mutation | Test that caught it |
| --- | --- |
| Drop the clear paired with `cancelReorder` | a re-group during a header drag releases the lift |
| Dim every row, not just the dragged group's | a header drag lifts its own rows and no others |
| Set the group on row drags too | a row drag lifts nothing |
| Drop the `onPointerCancel` handler | a cancelled pointer releases the lift |

2026-08-01T23:35-0700 Probed separately, in a throwaway test since deleted: a
`Listener` unmounted between pointer-down and pointer-up still counts one
`onPointerUp`. That is what licenses the pointer listener to cover the rail being
unmounted mid-drag, and what made the clears at the swap-out call sites dead.

2026-08-01T22:58-0700 `onPointerUp` has no test of its own, because the path it
exists for (a mid-drag `itemCount` change killing the drag) needs a session to
close while a gesture is held, and the fake client has no push for it. What was
verified instead: with `onReorderEnd` deleted, so the `Listener` is the only
thing left that can clear, `a header drag lifts its own rows and no others`
still passes its post-drop assertion. That proves the pointer events reach it and
release the treatment; the rest of the reasoning is read off the Flutter source
cited above.

2026-08-01T20:10-0700 Built and installed from an integration worktree merging
this branch with `fix/web-clipboard`, so the running daemon kept the paste fix
rather than regressing it. Handover to PID 62556, PPID 1, running inode matching
the installed binary, HTTP 200 in 1.1ms, served bundle sha256 `071c7005d721f6c6`
matching the freshly built `main.dart.js`.

**The dimming itself is not confirmed on screen.** Seeing it requires holding a
drag mid-gesture, and the available tooling cannot: the screenshot tool's drag is
atomic, and synthetic `PointerEvent`s dispatched into the page do not drive
Flutter web's drag gesture (tried, the rail rendered normally). The behaviour
rests on the mutation-tested widget tests above.

## Next Steps

- Eyeball the dimming against the real rail by hand.
- Give the fake client a session-closed push, so the `itemCount` cancel path can
  be tested rather than argued.

## Commits

- a2440fa: fix(triage_client): show a dragged group's rows travelling with its header
- HEAD: fix(triage_client): release the dragged-group lift however the drag ends

Rebased onto `origin/main` at c6ad0d5, which is where `fix/web-clipboard` landed
as #132, so the hash above is the post-rebase one. Pre-rebase it was 008c0c4.
