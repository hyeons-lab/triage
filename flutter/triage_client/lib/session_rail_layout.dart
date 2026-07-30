/// Flat-list layout for the grouped session rail, and the mapping from a drag
/// on that flat list back to a pin change.
///
/// The rail is one `ReorderableListView` whose items are group headers
/// interleaved with session rows, rather than a list of nested reorderable
/// lists. Nesting reads more naturally but puts two reorderables in one gesture
/// arena: an inner row's drag can be captured by the outer list, and on touch a
/// long-press on a header is ambiguous between the two levels. One list means
/// one gesture space, at the cost of the index arithmetic here — which is
/// exactly the kind of thing that belongs in tested pure functions rather than
/// inside a widget.
library;

import 'package:triage_client/session_grouping.dart';

/// One row of the flat rail: a group header, or a session belonging to a group.
class RailItem {
  const RailItem.header(this.groupKey) : sessionId = null;
  const RailItem.session(this.groupKey, String this.sessionId);

  /// The group this row belongs to (see [SessionGroup.pinKey]). Headers and
  /// their sessions share it, which is what makes a row's group recoverable
  /// from a flat index.
  final String groupKey;

  /// Null for a header row.
  final String? sessionId;

  bool get isHeader => sessionId == null;
}

/// Builds rail rows covering [sessionIds], in the order given, with a header
/// wherever the repository changes.
///
/// Driven by [sessionIds] rather than by [groups] alone because the two can
/// legitimately disagree: the grouping is recomputed at load, reconnect, and on
/// a drag, while the session list also changes when one is started or closed. A
/// layout read off the groups would silently omit any session added since — so
/// the groups supply repository membership and order, and the session list
/// decides what actually gets a row.
///
/// A session absent from [groups] is rendered ungrouped, under no header.
/// Headers are omitted entirely for a single repository: every row would carry
/// the same label, which is chrome rather than structure, and it keeps the
/// single-repo case looking exactly as it did before grouping.
List<RailItem> buildRailItems(
  List<String> sessionIds,
  List<SessionGroup> groups,
) {
  final groupOf = <String, String>{
    for (final group in groups)
      for (final sessionId in group.sessionIds) sessionId: group.pinKey,
  };
  final distinct = <String>{
    for (final sessionId in sessionIds)
      if (groupOf[sessionId] != null) groupOf[sessionId]!,
  };
  final withHeaders = distinct.length > 1;

  final items = <RailItem>[];
  // Tracked as a set rather than by comparing against the previous key alone:
  // an ungrouped row landing between two rows of one group would otherwise emit
  // that group's header twice, and both headers carry `ValueKey('group:$key')`
  // — a duplicate-key exception inside the `ReorderableListView`. Grouping keeps
  // a group's rows contiguous today, so this is a guard on the invariant rather
  // than a live fix.
  final emitted = <String>{};
  for (final sessionId in sessionIds) {
    final key = groupOf[sessionId];
    if (withHeaders && key != null && emitted.add(key)) {
      items.add(RailItem.header(key));
    }
    items.add(RailItem.session(key ?? '', sessionId));
  }
  return items;
}

/// Interprets a drag on the flat rail as a pin change.
///
/// Dragging is how a pin is created: moving something is a statement that it
/// belongs where it was put, so it stops flowing with activity from then on.
///
/// Dragging a header moves its whole group. Dragging a row moves it within its
/// own group only — repository membership follows the session's directory, so a
/// row dropped over another group's rows is clamped back into its own span
/// rather than changing repository. Clamping rather than rejecting keeps the
/// gesture from feeling dead: the row still moves, just as far as it can go.
///
/// [newIndex] is taken in `ReorderableListView`'s pre-removal coordinate space,
/// as its `onReorder` reports it.
///
/// A drag that resolves to the position its subject already holds pins nothing.
/// That is not just the released-where-it-started case: the clamping above means
/// plenty of real drags land back on themselves, and every one of them looks to
/// the user like nothing happened. The cost is that the top group cannot be
/// pinned by dragging it onto itself — to hold it there, drag the group below it
/// up past it, which pins both.
SessionPins resolveRailReorder({
  required List<RailItem> items,
  required SessionPins pins,
  required int oldIndex,
  required int newIndex,
}) {
  if (oldIndex < 0 || oldIndex >= items.length) return pins;
  // A row with no group is a local session — it has no daemon session id, so it
  // never appears in a group and a pin naming it could never match anything. Left
  // unpinned rather than stored, which would otherwise accumulate dead keys in
  // this server's prefs and keep the reset action permanently visible.
  if (!items[oldIndex].isHeader && items[oldIndex].groupKey.isEmpty) {
    return pins;
  }
  // Convert to post-removal space, matching how the list itself will settle.
  final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
  final moved = items[oldIndex];
  final remaining = [...items]..removeAt(oldIndex);
  final landing = target.clamp(0, remaining.length);

  if (moved.isHeader) {
    // Group move: its position among groups is the number of *other* group
    // headers landing above it.
    final groupIndex = remaining
        .take(landing)
        .where((item) => item.isHeader)
        .length;
    final displayOrder = [
      for (final item in items)
        if (item.isHeader) item.groupKey,
    ];
    // The drop resolved to the slot this group already holds, so nothing was
    // reordered and there is nothing to pin. Checked at the *group* level rather
    // than on the flat index: a header dragged down over its own rows, or up
    // into the group above without passing that group's header, moves a real
    // distance in flat coordinates and still lands back on itself. Pinning there
    // put badges on groups the user never moved and offered a reset for a layout
    // they never made — and because pins are a leading block, it pinned every
    // group above as well.
    if (groupIndex == displayOrder.indexOf(moved.groupKey)) return pins;
    return pins.copyWith(
      groupKeys: pinPrefixTo(
        pins.groupKeys,
        displayOrder,
        moved.groupKey,
        groupIndex,
      ),
    );
  }

  // Session move: its position is counted only among its own group's rows, so a
  // drop past the group boundary saturates at that group's first or last slot.
  final withinGroup = remaining
      .take(landing)
      .where((item) => !item.isHeader && item.groupKey == moved.groupKey)
      .length;

  final displayOrder = [
    for (final item in items)
      if (!item.isHeader && item.groupKey == moved.groupKey) item.sessionId!,
  ];
  // Same no-op test one level down, which also subsumes the lone-row case: a row
  // alone in its group, or dragged onto its own group's header, resolves to the
  // index it already has.
  if (withinGroup == displayOrder.indexOf(moved.sessionId!)) return pins;
  // The whole flat list goes through `pinPrefixTo` against this group's rows.
  // Relative order *between* groups carries no meaning — groups are positioned
  // by [SessionPins.groupKeys], and each group reads only its own members back
  // out — so every pin that is not a row of this group is "absent" as far as
  // this call is concerned, and `pinPrefixTo` already keeps those at the index
  // they held. Splitting the list up first and re-joining it instead gave that
  // rule a second implementation, which disagreed: it collected the untouched
  // pins in front, silently promoting a pinned-but-not-running session to the
  // top of its own group the moment it came back.
  return pins.copyWith(
    sessionIds: pinPrefixTo(
      pins.sessionIds,
      displayOrder,
      moved.sessionId!,
      withinGroup,
    ),
  );
}

/// Removes a group or session from [pins], returning it to activity ordering.
SessionPins unpin(SessionPins pins, {String? groupKey, String? sessionId}) =>
    SessionPins(
      groupKeys: groupKey == null
          ? pins.groupKeys
          : ([...pins.groupKeys]..remove(groupKey)),
      sessionIds: sessionId == null
          ? pins.sessionIds
          : ([...pins.sessionIds]..remove(sessionId)),
    );
