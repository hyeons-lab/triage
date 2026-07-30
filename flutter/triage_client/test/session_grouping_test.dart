import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/session_grouping.dart';

SessionOrderingInput session(String id, {String? repo, int activity = 0}) =>
    SessionOrderingInput(
      sessionId: id,
      repoRoot: repo,
      lastActivityMs: activity,
    );

void main() {
  group('groupSessionsByRepo', () {
    test('puts same-repo sessions adjacent', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 100),
        session('session-2', repo: '/b', activity: 90),
        session('session-3', repo: '/a', activity: 80),
      ]);

      expect(flattenGroups(groups), [
        'session-1',
        'session-3', // /a, kept together despite /b being more recent than it
        'session-2',
      ]);
    });

    test('orders groups by their most recent member, not their oldest', () {
      // /b's newest session is older than /a's newest, but /b also holds the
      // single oldest session. Taking the max is what puts /a first.
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 500),
        session('session-2', repo: '/b', activity: 400),
        session('session-3', repo: '/b', activity: 1),
      ]);

      expect(groups.map((g) => g.repoRoot), ['/a', '/b']);
      expect(groups.first.lastActivityMs, 500);
      expect(groups.last.lastActivityMs, 400);
    });

    test('orders sessions within a group by activity, newest first', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 10),
        session('session-2', repo: '/a', activity: 30),
        session('session-3', repo: '/a', activity: 20),
      ]);

      expect(groups.single.sessionIds, ['session-2', 'session-3', 'session-1']);
    });

    test('collects repo-less sessions into one group, ordered by activity', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 100),
        session('session-2', activity: 300), // no repo, but most recent
        session('session-3', activity: 50),
      ]);

      // The "Other" group sorts by activity like any other group rather than
      // being pinned last, so an active stray shell still surfaces.
      expect(groups.first.repoRoot, isNull);
      expect(groups.first.sessionIds, ['session-2', 'session-3']);
      expect(groups.length, 2);
    });

    test('treats a trailing slash as the same repository', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 10),
        session('session-2', repo: '/a/', activity: 20),
      ]);

      expect(
        groups.length,
        1,
        reason: 'a trailing slash must not split a repo',
      );
      expect(groups.single.sessionIds, ['session-2', 'session-1']);
    });
  });

  group('tie-breaking', () {
    test('preserves the daemon order when all activity is unknown', () {
      // The fresh-daemon case: nothing has produced output yet, so every stamp
      // is 0. The daemon already sorts by creation sequence, so the tie-break is
      // simply to leave that order alone — re-deriving one from session ids here
      // would duplicate the daemon's sort and disagree with it for any id that
      // isn't `session-N`.
      final groups = groupSessionsByRepo([
        session('session-10', repo: '/a'),
        session('session-2', repo: '/a'),
        session('session-1', repo: '/a'),
      ]);

      expect(groups.single.sessionIds, [
        'session-10',
        'session-2',
        'session-1',
      ]);
    });

    test('preserves daemon order for custom ids too', () {
      final groups = groupSessionsByRepo([
        session('zeta', repo: '/a'),
        session('alpha', repo: '/a'),
      ]);

      expect(groups.single.sessionIds, ['zeta', 'alpha']);
    });

    test('breaks group ties on the earliest-listed session', () {
      final groups = groupSessionsByRepo([
        session('session-5', repo: '/b'),
        session('session-2', repo: '/a'),
      ]);

      // /b holds the first-listed session, so it leads.
      expect(groups.map((g) => g.repoRoot), ['/b', '/a']);
    });

    test('an all-tied set falls back to the order the daemon listed', () {
      // Every stamp is equal, so this is entirely decided by the tie-break —
      // the case a fresh daemon hits, where nothing has produced output yet.
      // Asserting the concrete order rather than that two identical calls agree
      // with each other: `List.sort` is deterministic for identical input
      // whether or not the comparator is a total order, so self-agreement is
      // true even of the arbitrary ordering this replaces.
      expect(
        flattenGroups(
          groupSessionsByRepo([
            session('session-1', repo: '/a', activity: 100),
            session('session-2', repo: '/b', activity: 100),
            session('session-3', repo: '/a', activity: 100),
          ]),
        ),
        ['session-1', 'session-3', 'session-2'],
      );

      // The same three sessions listed differently order differently, and that
      // is correct rather than a wobble: the tie-break is the daemon's own
      // creation order, which it sorts before sending. Re-deriving an order from
      // the ids here would duplicate that sort in a second language and disagree
      // with it for any id that is not `session-N`.
      expect(
        flattenGroups(
          groupSessionsByRepo([
            session('session-3', repo: '/a', activity: 100),
            session('session-2', repo: '/b', activity: 100),
            session('session-1', repo: '/a', activity: 100),
          ]),
        ),
        ['session-3', 'session-1', 'session-2'],
      );
    });
  });

  group('unknown activity', () {
    test('sorts sessions with unknown activity last within a group', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a'), // unknown
        session('session-2', repo: '/a', activity: 5),
      ]);

      // 0 means "unknown", not "the epoch" — but since any real stamp is
      // greater, unknown naturally lands last.
      expect(groups.single.sessionIds, ['session-2', 'session-1']);
    });

    test('sorts an all-unknown group after one with known activity', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/quiet'),
        session('session-2', repo: '/busy', activity: 1),
      ]);

      expect(groups.map((g) => g.repoRoot), ['/busy', '/quiet']);
    });
  });

  test('handles an empty session list', () {
    expect(groupSessionsByRepo([]), isEmpty);
    expect(flattenGroups([]), isEmpty);
  });

  group('pinPrefixTo', () {
    test('pins the whole prefix through the drop position', () {
      expect(
        pinPrefixTo(const [], const ['/a', '/b', '/c'], '/c', 1),
        equals(['/a', '/c']),
      );
    });

    test('a downward drag pins rather than springing back to the top', () {
      // With nothing pinned, inserting into the pinned list alone clamps every
      // target to 0, which silently ate half the drag gesture.
      expect(
        pinPrefixTo(const [], const ['/a', '/b', '/c'], '/a', 2),
        equals(['/b', '/c', '/a']),
      );
    });

    test('dropping a new entry into the block does not release the last pin', () {
      // Regression: the prefix was sized `max(index + 1, alreadyPinned)`, one
      // short whenever the dragged key was not already pinned — so this dropped
      // '/b' out of the block and back into activity order.
      expect(
        pinPrefixTo(const ['/a', '/b'], const ['/a', '/b', '/c'], '/c', 0),
        equals(['/c', '/a', '/b']),
      );
    });

    test('re-dragging an already-pinned entry does not grow the block', () {
      expect(
        pinPrefixTo(const ['/a', '/b'], const ['/a', '/b', '/c'], '/b', 0),
        equals(['/b', '/a']),
      );
    });

    test('a pin whose sessions are all gone survives a drag elsewhere', () {
      // `displayOrder` cannot contain a group with no live sessions, so a naive
      // rebuild drops it — losing the slot the rail promises to hold for it.
      expect(
        pinPrefixTo(const ['/gone', '/a'], const ['/a', '/b'], '/b', 0),
        equals(['/gone', '/b', '/a']),
      );
    });
  });
}
