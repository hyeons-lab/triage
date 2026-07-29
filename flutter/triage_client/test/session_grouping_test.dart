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
      expect(groups.first.isOther, isTrue);
      expect(groups.first.sessionIds, ['session-2', 'session-3']);
      expect(groups.length, 2);
    });

    test('treats a trailing slash as the same repository', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 10),
        session('session-2', repo: '/a/', activity: 20),
      ]);

      expect(groups.length, 1, reason: 'a trailing slash must not split a repo');
      expect(groups.single.sessionIds, ['session-2', 'session-1']);
    });
  });

  group('tie-breaking', () {
    test('falls back to creation sequence when all activity is unknown', () {
      // The fresh-daemon case: nothing has produced output yet, so every stamp
      // is 0. Without a tie-break this is where arbitrary ordering crept back in.
      final groups = groupSessionsByRepo([
        session('session-10', repo: '/a'),
        session('session-2', repo: '/a'),
        session('session-1', repo: '/a'),
      ]);

      expect(groups.single.sessionIds, [
        'session-1',
        'session-2',
        'session-10', // not before session-2, which a string sort would do
      ]);
    });

    test('breaks group ties on creation sequence', () {
      final groups = groupSessionsByRepo([
        session('session-5', repo: '/b'),
        session('session-2', repo: '/a'),
      ]);

      expect(groups.map((g) => g.repoRoot), ['/a', '/b']);
    });

    test('orders custom ids after generated ones', () {
      final groups = groupSessionsByRepo([
        session('zeta', repo: '/a'),
        session('session-3', repo: '/a'),
        session('alpha', repo: '/a'),
      ]);

      expect(groups.single.sessionIds, ['session-3', 'alpha', 'zeta']);
    });

    test('is independent of input order', () {
      final inputs = [
        session('session-1', repo: '/a', activity: 100),
        session('session-2', repo: '/b', activity: 100),
        session('session-3', repo: '/a', activity: 100),
      ];
      final forward = flattenGroups(groupSessionsByRepo(inputs));
      final reversed = flattenGroups(
        groupSessionsByRepo(inputs.reversed.toList()),
      );

      // Every stamp is equal here, so only a total order makes these agree.
      expect(forward, reversed);
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
}
