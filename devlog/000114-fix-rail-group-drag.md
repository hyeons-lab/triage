# 000114 fix/rail-group-drag

**Agent:** Claude (claude-opus-5[1m]) @ triage branch fix/rail-group-drag

Numbered 000114 rather than 000113: that number is taken by the unmerged
`fix/web-clipboard` branch (PR #132).

## Intent

Dragging a group header looked like it detached the label from the rows it
names. Reported as "I shouldn't be able to drag just the header without the
associated rows also moving."

The drop was never wrong: `resolveRailReorder` already moves the whole group,
and `dragging a header pins its whole group` covers it. What was wrong was the
*feedback*, which showed a lone header travelling while its rows sat still.

## What Changed

2026-08-01T19:05-0700 `flutter/triage_client/lib/main.dart` — added
`_draggingRailGroup` to the app state, set on a header drag and cleared on drop,
on drag end, and alongside the `cancelReorder` in `_regroupRail`. `SessionRail`
takes it as `draggingGroupKey` plus `onRailDragStart` / `onRailDragEnd`, wires
the list's `onReorderStart` / `onReorderEnd`, and draws the dragged group's rows
at 40% opacity.

2026-08-01T19:12-0700 `flutter/triage_client/test/widget_test.dart` — three
tests: the lift appears and is scoped to the dragged group, a row drag lifts
nothing, and a mid-drag re-group releases the lift.

## Decisions

2026-08-01T19:02-0700 Put `_draggingRailGroup` on the app state rather than
inside `SessionRail` — reasoning: clearing it is the same invariant as
cancelling the drag, and `_regroupRail` is what cancels. A copy owned by the
rail could not be reached from there, and re-grouping fires on ordinary session
output, so it would routinely be left set over a drag the list had already
dropped. That is a group dimmed for the rest of the session.

2026-08-01T19:08-0700 Dimmed the rows in place rather than moving them —
reasoning: `ReorderableList` lifts exactly one child, and reordering the rest
mid-drag is what duplicates its per-child `GlobalKey` and throws. That is the
same constraint `_regroupRail` already documents. Opacity also leaves row
heights alone, which matters because the drop targets *are* the row geometry:
collapsing or removing a row would move the landing slots out from under the
gesture choosing between them.

2026-08-01T19:10-0700 Left the drop behaviour untouched — reasoning: it was
already correct, and the report was about what the drag looked like.

## Issues

2026-08-01T19:09-0700 **A count badge on the dragged header does not work.**
Labelling the lifted header with "2 sessions" was written, and rendered nothing:
`ReorderableList` builds the floating proxy from the child captured when the
drag began, so it does not rebuild when the state driving that label changes.
`onReorderStart` cannot get ahead of it either, since the capture happens in the
same frame. Removed rather than shipped dead, and the constraint is documented
on `draggingGroupKey`: anything that must react during a drag has to live in the
list body, which is why the dimming works and the badge could not.

## Verification

- `flutter analyze` — 4 issues, all pre-existing on `main`, none in the touched files.
- `flutter test` — 283 passed (280 before, plus the 3 added here).

Mutation-tested, all three killed:

| Mutation | Test that caught it |
| --- | --- |
| Drop the clear paired with `cancelReorder` | a re-group during a header drag releases the lift |
| Dim every row, not just the dragged group's | a header drag lifts its own rows and no others |
| Set the group on row drags too | a row drag lifts nothing |

**Not verified in a real client.** The daemon serves the web bundle embedded at
build time, so seeing this on screen means rebuilding and reinstalling `triaged`.
The behaviour is driven entirely through the widget tree by the tests above.

## Next Steps

- Rebuild and install to eyeball the dimming against the real rail.

## Commits

- HEAD — fix(triage_client): show a dragged group's rows travelling with its header
