# 000111-02, Rail pinning (Phase 2)

Written after the fact, reconstructing the design from the work as it landed.
Phase 2 was deferred in `000111-01` and then pulled forward into the same branch
once it became clear the two could not ship separately, see the Decisions entry
in the devlog.

## Thinking

Phase 1 makes the rail order derived: repository grouping, then activity, with a
deterministic tie-break. That is strictly better than the `HashMap` order it
replaces, but it takes something away, the old rail could be reordered by hand
and the order persisted, and a derived order has no room for that.

Worse, the two changes could not be separated. Landing group headers means the
rail is no longer a flat list, and the existing drag implementation reorders a
flat list; keeping both would have meant a nested `ReorderableListView`, which
puts two reorderables in one gesture arena. So headers were briefly landed *with
drag removed*, which broke two widget tests and made the real constraint obvious:
the drag replacement is not a follow-up, it is the other half of the same change.

So the question is what "put this here" should mean when everything else is
flowing by activity.

**Absolute-index pinning**, "this repo is always third", has no defined answer
under a changing set. If the repo above it closes its last session, third place
means something different; if a new repo becomes active, the pinned one has to be
displaced or the new one has nowhere to go. Every rule for resolving that is
arbitrary.

**A leading block**, pinned entries occupy the top slots in their pinned order,
everything unpinned flows below by activity, stays coherent under any change to
the set. Adding, removing, or reordering unpinned entries never disturbs the
block, and removing a pinned entry just shortens it.

The cost is real and worth stating: a group cannot be pinned *below* an unpinned
one. "Keep this where I put it" is expressible; "keep this exactly third" is not.
That is the right trade for a rail whose whole point is that recent work surfaces
itself.

Two consequences fall out of the block model:

- A drag to position *N* has to pin the whole prefix through *N*, not just the
  dragged item. Pinning only the dragged item cannot express a downward drag at
  all: with nothing yet pinned, every target clamps to 0 and the row springs back
  to the top.
- A group's activity must stay computed from its sessions regardless of pinning.
  If pinning also froze the activity value, unpinning would strand the group
  wherever it had been pinned instead of returning it to its true position.

Pins also need an exit. Two, in fact: a global reset for "put it all back", and a
per-item release for "just this one". The per-item control is the pin indicator
itself rather than a context menu, on touch the rail's long-press is already the
drag trigger, so a menu would compete with the gesture that creates pins in the
first place.

## Plan

1. `SessionPins` (group keys + session ids, both flat and ordered) with
   `SessionPins.none`, persisted per server, repository paths and session ids
   are both daemon-local.
2. `pinPrefixTo(pinned, displayOrder, key, index)`: the drag→pin mapping, shared
   by group and row drags since both mean the same thing. Must never release a
   pin as a side effect, and must preserve pins naming entries that have no live
   session right now.
3. Order pinned entries ahead of unpinned ones in `groupSessionsByRepo`, at both
   levels, computing group activity from members irrespective of pinning.
4. `session_rail_layout.dart`: a flat `RailItem` list with headers interleaved,
   one gesture arena, plus `resolveRailReorder` mapping a drop index back to a
   pin change. Index arithmetic lives in pure functions, not the widget, because
   that is the part that will be wrong.
5. Rows clamp to their own group's span: repository membership follows the
   session's directory, so a row dropped over another group moves as far as it
   can rather than changing repository. Clamping rather than rejecting keeps the
   gesture from feeling dead.
6. `main.dart`: pins state, headers as drag handles, pin indicators that double
   as release controls, and a reset shown only while something is pinned.
7. Keep the selection on the same *session* across a re-group, not the same
   index.
