/// Grouping and ordering for the session rail.
///
/// Kept out of `main.dart` so the ordering rules can be unit-tested against
/// plain data instead of a pumped widget tree — this is the logic that decides
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

  /// Daemon-local session id. Also the tie-break, so ordering is total.
  final String sessionId;

  /// Absolute git repository root, or null when the session's working directory
  /// is outside any repository. Linked worktrees report their *parent* repo here
  /// (the daemon resolves it via `git rev-parse --git-common-dir`), so a repo and
  /// its worktrees group together without special-casing.
  final String? repoRoot;

  /// Milliseconds since the Unix epoch of the session's most recent output.
  /// 0 means unknown — no output yet, or a daemon predating activity tracking.
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

  /// The most recent activity among [sessionIds] — what the group is ordered by.
  /// 0 when no member has known activity.
  final int lastActivityMs;

  /// True for the catch-all group of repo-less sessions.
  bool get isOther => repoRoot == null;
}

/// Groups [sessions] by repository and orders both the groups and the sessions
/// within each by most recent activity.
///
/// Ordering is a *total* order: ties on activity — including the all-zero case
/// where no session has a known stamp — fall back to the session id's creation
/// sequence. Without that, equal timestamps would leave the order down to the
/// input sequence, which is precisely the arbitrary ordering this replaces.
///
/// Sessions with no repository collect into a single trailing-by-activity group
/// (`repoRoot == null`) rather than one group each, so a handful of stray shells
/// can't push real repositories off the screen.
List<SessionGroup> groupSessionsByRepo(List<SessionOrderingInput> sessions) {
  final byRepo = <String?, List<SessionOrderingInput>>{};
  for (final session in sessions) {
    // Normalize so a trailing slash doesn't split one repository in two.
    final key = _normalizeRepoRoot(session.repoRoot);
    byRepo.putIfAbsent(key, () => []).add(session);
  }

  final groups = <SessionGroup>[];
  for (final entry in byRepo.entries) {
    final members = [...entry.value]..sort(_compareSessions);
    groups.add(
      SessionGroup(
        repoRoot: entry.key,
        sessionIds: members.map((s) => s.sessionId).toList(),
        // Max, not min or mean: a group is as recent as its most recent session,
        // so one active worktree surfaces its whole repository.
        lastActivityMs: members.fold<int>(
          0,
          (best, s) => s.lastActivityMs > best ? s.lastActivityMs : best,
        ),
      ),
    );
  }

  groups.sort((a, b) {
    if (a.lastActivityMs != b.lastActivityMs) {
      return b.lastActivityMs.compareTo(a.lastActivityMs); // newest first
    }
    // Tie-break on the earliest member id so group order is total and stable —
    // the common case being a fresh daemon where every stamp is 0.
    return _compareSessionIds(a.sessionIds.first, b.sessionIds.first);
  });
  return groups;
}

/// Flattens [groups] back into a single rail order.
List<String> flattenGroups(List<SessionGroup> groups) => [
  for (final group in groups) ...group.sessionIds,
];

int _compareSessions(SessionOrderingInput a, SessionOrderingInput b) {
  if (a.lastActivityMs != b.lastActivityMs) {
    return b.lastActivityMs.compareTo(a.lastActivityMs); // newest first
  }
  return _compareSessionIds(a.sessionId, b.sessionId);
}

/// Orders session ids the way the daemon does: generated `session-N` ids by
/// ascending sequence, then custom ids lexicographically.
///
/// Comparing the raw strings would put `session-10` before `session-2`, so a
/// daemon past its tenth session would show a visibly wrong fallback order.
int _compareSessionIds(String a, String b) {
  final seqA = _sessionSequence(a);
  final seqB = _sessionSequence(b);
  if (seqA != null && seqB != null) return seqA.compareTo(seqB);
  if (seqA != null) return -1; // generated ids before custom ones
  if (seqB != null) return 1;
  return a.compareTo(b);
}

int? _sessionSequence(String sessionId) {
  const prefix = 'session-';
  if (!sessionId.startsWith(prefix)) return null;
  return int.tryParse(sessionId.substring(prefix.length));
}

String? _normalizeRepoRoot(String? repoRoot) {
  if (repoRoot == null || repoRoot.isEmpty) return null;
  if (repoRoot.length > 1 && repoRoot.endsWith('/')) {
    return repoRoot.substring(0, repoRoot.length - 1);
  }
  return repoRoot;
}
