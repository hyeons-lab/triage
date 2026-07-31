/// Grouping and ordering for the session rail.
///
/// Kept out of `main.dart` so the ordering rules can be unit-tested against
/// plain data instead of a pumped widget tree: this is the logic that decides
/// what the user sees first, and it has several edge cases (unknown activity,
/// repo-less sessions, ties) that are tedious to reach through the UI.
library;

/// The one input the ordering needs from a session.
///
/// Deliberately not `SessionVm`: ordering depends on exactly these three fields,
/// and depending on the full view-model would drag the widget layer into every
/// test.
class SessionOrderingInput {
  const SessionOrderingInput({
    required this.sessionId,
    required this.repoRoot,
    required this.lastActivityMs,
  });

  /// Daemon-local session id. Identity only: ties are broken on the session's
  /// position in the input, which is the daemon's own creation order, rather
  /// than on anything derived from this.
  final String sessionId;

  /// Absolute git repository root, or null when the session's working directory
  /// is outside any repository. Linked worktrees report their *parent* repo here
  /// (the daemon resolves it via `git rev-parse --git-common-dir`), so a repo and
  /// its worktrees group together without special-casing.
  final String? repoRoot;

  /// Milliseconds since the Unix epoch of the session's most recent output.
  /// 0 means unknown: no output yet, or a daemon predating activity tracking.
  final int lastActivityMs;
}

/// One repository's sessions, in display order.
class SessionGroup {
  const SessionGroup({
    required this.repoRoot,
    required this.sessionIds,
    required this.lastActivityMs,
  });

  /// Null for the catch-all group holding sessions outside any repository.
  final String? repoRoot;

  /// This group's sessions, most recently active first.
  final List<String> sessionIds;

  /// The most recent activity among [sessionIds]: what the group is ordered by.
  /// 0 when no member has known activity.
  final int lastActivityMs;

  /// Stable key for this group in persisted pin lists. Repository roots are
  /// absolute paths, so the sentinel used for the repo-less group cannot collide
  /// with a real one.
  String get pinKey => repoRoot ?? otherGroupPinKey;
}

/// Pin key standing in for the repo-less ("Other") group, which has no root.
const otherGroupPinKey = '<other>';

/// Which groups and sessions the user has placed by hand.
///
/// Pins are a *top block*, not absolute positions: pinned entries occupy the
/// leading slots in their pinned relative order, and everything unpinned flows
/// below them by activity. Absolute-index pinning has no well-defined answer
/// once groups start appearing and vanishing (a repo pinned to index 2 has
/// nowhere meaningful to sit when the repo above it closes its last session),
/// whereas a leading block stays coherent under any change to the set.
///
/// The cost is that a group cannot be pinned *below* an unpinned one. That is
/// the deliberate trade: "keep this where I put it" is expressible, "keep this
/// exactly third" is not.
class SessionPins {
  const SessionPins({this.groupKeys = const [], this.sessionIds = const []});

  /// Empty pins: everything orders by activity.
  static const none = SessionPins();

  /// Pinned group keys (see [SessionGroup.pinKey]), in display order.
  final List<String> groupKeys;

  /// Pinned session ids, in display order. Flat across groups: a session belongs
  /// to exactly one group, so each group's pinned run is this list filtered to
  /// its members, and no per-group bookkeeping is needed.
  final List<String> sessionIds;

  bool get isEmpty => groupKeys.isEmpty && sessionIds.isEmpty;

  SessionPins copyWith({List<String>? groupKeys, List<String>? sessionIds}) =>
      SessionPins(
        groupKeys: groupKeys ?? this.groupKeys,
        sessionIds: sessionIds ?? this.sessionIds,
      );
}

/// Pins whatever it takes to put [key] at [index] of [displayOrder].
///
/// Shared by group and session drags because both mean the same thing: "put this
/// here and keep it there".
///
/// Because pins are a leading block, an entry can only hold a position if
/// everything above it is pinned too, so landing [key] at [index] means pinning
/// the whole prefix through it, in the order the drop produces. Inserting into
/// the pinned list alone cannot express a downward drag: with nothing yet
/// pinned, every target clamps to 0 and the item springs back to the top, which
/// silently ate half of the rail's drag gesture.
///
/// Existing pins are never released as a side effect: the prefix taken is at
/// least as long as the set already pinned, so dragging one entry cannot unpin
/// another.
List<String> pinPrefixTo(
  List<String> pinned,
  List<String> displayOrder,
  String key,
  int index,
) {
  final reordered = [...displayOrder]..remove(key);
  reordered.insert(index.clamp(0, reordered.length), key);

  // The block has to grow to hold [key] *on top of* what was already pinned.
  // Taking `max(index + 1, alreadyPinned)` looks equivalent but is one short
  // whenever [key] is newly pinned: dropping a third entry into a block of two
  // would push the bottom one out and silently release it.
  final alreadyPinned = pinned.where(displayOrder.contains).length;
  final needed = alreadyPinned + (pinned.contains(key) ? 0 : 1);
  final take = index + 1 > needed ? index + 1 : needed;
  final head = reordered.take(take.clamp(0, reordered.length)).toList();

  // A pin naming a group or session with no live session right now is invisible
  // to [displayOrder], so it cannot survive a rebuild that reads from it: the
  // next drag anywhere in the rail would drop it. Splice those back at the index
  // they held, which is what makes the "keeps its slot for when one starts
  // again" promise hold through a drag and not just through a re-group.
  final result = [...head];
  for (var i = 0; i < pinned.length; i++) {
    final absent = pinned[i];
    if (absent != key && !displayOrder.contains(absent)) {
      result.insert(i.clamp(0, result.length), absent);
    }
  }
  return result;
}

/// Groups [sessions] by repository and orders both the groups and the sessions
/// within each by most recent activity.
///
/// Ordering is a *total* order: ties on activity, including the all-zero case
/// where no session has a known stamp, fall back to the session id's creation
/// sequence. Without that, equal timestamps would leave the order down to the
/// input sequence, which is precisely the arbitrary ordering this replaces.
///
/// Sessions with no repository collect into a single trailing-by-activity group
/// (`repoRoot == null`) rather than one group each, so a handful of stray shells
/// can't push real repositories off the screen.
List<SessionGroup> groupSessionsByRepo(
  List<SessionOrderingInput> sessions, {
  SessionPins pins = SessionPins.none,
}) {
  final byRepo = <String?, List<SessionOrderingInput>>{};
  for (final session in sessions) {
    // Normalize so a trailing slash doesn't split one repository in two.
    final key = trimTrailingSlash(session.repoRoot);
    byRepo.putIfAbsent(key, () => []).add(session);
  }

  // Position in the incoming list, used to break activity ties. The daemon
  // already returns sessions in a deterministic creation order, so preserving
  // that is both the right answer and the only one: re-deriving an order from
  // session ids here would duplicate the daemon's sort in a second language and
  // disagree with it for any id that isn't `session-N`.
  final inputIndex = <String, int>{
    for (var i = 0; i < sessions.length; i++) sessions[i].sessionId: i,
  };
  int byActivityThenInput(SessionOrderingInput a, SessionOrderingInput b) {
    if (a.lastActivityMs != b.lastActivityMs) {
      return b.lastActivityMs.compareTo(a.lastActivityMs); // newest first
    }
    return (inputIndex[a.sessionId] ?? 0).compareTo(
      inputIndex[b.sessionId] ?? 0,
    );
  }

  final groups = <SessionGroup>[];
  for (final entry in byRepo.entries) {
    final members = [...entry.value]..sort(byActivityThenInput);
    groups.add(
      SessionGroup(
        repoRoot: entry.key,
        sessionIds: _hoistPinned(
          members.map((s) => s.sessionId).toList(),
          pins.sessionIds,
          (id) => id,
        ),
        // Max, not min or mean: a group is as recent as its most recent session,
        // so one active worktree surfaces its whole repository. Computed from
        // activity alone: pinning changes where a group sits, never how recent
        // it is, so unpinning restores its true activity position rather than
        // leaving it stranded wherever it was pinned.
        lastActivityMs: members.fold<int>(
          0,
          (best, s) => s.lastActivityMs > best ? s.lastActivityMs : best,
        ),
      ),
    );
  }

  // Each group's earliest-listed session, computed once rather than inside the
  // comparator: `sort` calls that O(n log n) times, and the fresh-daemon case
  // where every stamp is 0 is exactly the one that reaches it every time.
  final earliestInput = {
    for (final group in groups)
      group.pinKey: group.sessionIds
          .map((id) => inputIndex[id] ?? 0)
          .reduce((a, b) => a < b ? a : b),
  };

  groups.sort((a, b) {
    if (a.lastActivityMs != b.lastActivityMs) {
      return b.lastActivityMs.compareTo(a.lastActivityMs); // newest first
    }
    // Tie-break on the group's earliest-listed session, so group order is total
    // and stable, the common case being a fresh daemon where every stamp is 0.
    return earliestInput[a.pinKey]!.compareTo(earliestInput[b.pinKey]!);
  });

  return _hoistPinned(groups, pins.groupKeys, (group) => group.pinKey);
}

/// Moves the entries named by [pinned] to the front of [items], in pinned order,
/// leaving everything else in its existing order behind them.
///
/// One implementation for groups and sessions: they differ only in how an
/// element yields its key. The rule that a pin naming something absent from
/// [items] is *skipped rather than dropped* has to hold for both (a repository
/// with no live sessions right now keeps its slot for when one starts again),
/// and stating it twice is how the two would eventually disagree.
List<T> _hoistPinned<T>(
  List<T> items,
  List<String> pinned,
  String Function(T) keyOf,
) {
  if (pinned.isEmpty) return items;
  final byKey = {for (final item in items) keyOf(item): item};
  final head = [
    for (final key in pinned)
      if (byKey.containsKey(key)) byKey[key] as T,
  ];
  if (head.isEmpty) return items;
  final headKeys = head.map(keyOf).toSet();
  return [
    ...head,
    for (final item in items)
      if (!headKeys.contains(keyOf(item))) item,
  ];
}

/// Flattens [groups] back into a single rail order.
List<String> flattenGroups(List<SessionGroup> groups) => [
  for (final group in groups) ...group.sessionIds,
];

/// Drops one trailing `/`, except from the filesystem root itself.
///
/// The rail derives a group key, a group header label, and a session title from
/// the same paths. Three private copies of this rule had already drifted apart
/// (only this one kept `/` intact), so a fix in one silently disagreed with the
/// others.
String? trimTrailingSlash(String? path) {
  if (path == null || path.isEmpty) return null;
  if (path.length > 1 && path.endsWith('/')) {
    return path.substring(0, path.length - 1);
  }
  return path;
}

/// The last path segment of [path], or null when it has none.
String? leafOf(String? path) {
  final trimmed = trimTrailingSlash(path);
  if (trimmed == null) return null;
  final slash = trimmed.lastIndexOf('/');
  final leaf = slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
  return leaf.isEmpty ? null : leaf;
}
