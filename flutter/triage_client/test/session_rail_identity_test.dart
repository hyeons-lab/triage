import 'package:flutter/material.dart' show Icons, MaterialApp, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:triage_client/main.dart';

SessionVm _session({
  String title = 'triage / abc',
  String? branch,
  String? repoRoot,
  String? worktreeRoot,
  String? cwd,
}) {
  return SessionVm(
    title: title,
    status: 'attached',
    statusColor: const Color(0xff7fd1c7),
    icon: Icons.terminal,
    rows: const [],
    branch: branch,
    repoRoot: repoRoot,
    worktreeRoot: worktreeRoot,
    cwd: cwd,
  );
}

void main() {
  group('railTitle', () {
    test('leads with the branch, not the repo', () {
      final session = _session(
        branch: 'feat/rail-row-identity',
        repoRoot: '/Users/me/dev/triage',
        worktreeRoot: '/Users/me/dev/triage/worktrees/rail-row-identity',
      );
      expect(session.railTitle, 'feat/rail-row-identity');
      // The header keeps its repo-first form.
      expect(session.displayTitle, 'triage · rail-row-identity');
    });

    test('falls back to the worktree when there is no branch', () {
      final session = _session(
        repoRoot: '/Users/me/dev/triage',
        worktreeRoot: '/Users/me/dev/triage/worktrees/detached-work',
      );
      expect(session.railTitle, 'detached-work');
    });

    test('falls back to the repo in a main checkout with no branch', () {
      final session = _session(
        repoRoot: '/Users/me/dev/triage',
        worktreeRoot: '/Users/me/dev/triage',
      );
      expect(session.railTitle, 'triage');
    });

    test('falls back to the cwd leaf outside a repo', () {
      final session = _session(cwd: '/Users/me/scratch');
      expect(session.railTitle, 'scratch');
    });

    test('falls back to the stable title with no context at all', () {
      expect(_session().railTitle, 'triage / abc');
    });

    test('ignores a whitespace-only branch', () {
      final session = _session(
        branch: '   ',
        repoRoot: '/Users/me/dev/triage',
        worktreeRoot: '/Users/me/dev/triage/worktrees/thing',
      );
      expect(session.railTitle, 'thing');
    });
  });

  group('worktreeEchoesBranch', () {
    test('matches the branch flattened whole', () {
      expect(worktreeEchoesBranch('feat-rail-row', 'feat/rail-row'), isTrue);
    });

    test("matches the branch's last segment", () {
      // What `git worktree add worktrees/<name> -b <type>/<name>` produces.
      expect(worktreeEchoesBranch('rail-row', 'feat/rail-row'), isTrue);
    });

    test('matches an exact branch name', () {
      expect(worktreeEchoesBranch('main', 'main'), isTrue);
    });

    test('does not match a genuinely different worktree name', () {
      expect(worktreeEchoesBranch('scratch', 'feat/rail-row'), isFalse);
    });

    test('does not match when there is no branch', () {
      expect(worktreeEchoesBranch('rail-row', null), isFalse);
      expect(worktreeEchoesBranch('rail-row', '   '), isFalse);
    });
  });

  group('indistinguishableRailRows', () {
    test('flags rows sharing a title and repo', () {
      final sessions = [
        _session(branch: 'feat/x', repoRoot: '/dev/triage'),
        _session(branch: 'feat/x', repoRoot: '/dev/triage'),
        _session(branch: 'feat/y', repoRoot: '/dev/triage'),
      ];
      expect(indistinguishableRailRows(sessions), {0, 1});
    });

    test('does not flag the same branch in different repos', () {
      final sessions = [
        _session(branch: 'main', repoRoot: '/dev/triage'),
        _session(branch: 'main', repoRoot: '/dev/other'),
      ];
      expect(indistinguishableRailRows(sessions), isEmpty);
    });

    test('flags context-less rows that render the same title', () {
      // Two sessions with no git context and the same stable title are just as
      // indistinguishable as two on one branch.
      final sessions = [_session(), _session()];
      expect(indistinguishableRailRows(sessions), {0, 1});
    });

    test('is empty for a single session', () {
      expect(indistinguishableRailRows([_session()]), isEmpty);
    });
  });

  group('formatRelativeActivity', () {
    final now = DateTime(2026, 7, 21, 12, 0);

    test('is null without a stamp — the client has no history to backfill', () {
      expect(formatRelativeActivity(null, now), isNull);
    });

    test('reads "now" under a minute', () {
      expect(
        formatRelativeActivity(now.subtract(const Duration(seconds: 59)), now),
        'now',
      );
    });

    test('steps to minutes, hours, then days at each boundary', () {
      expect(
        formatRelativeActivity(now.subtract(const Duration(minutes: 1)), now),
        '1m',
      );
      expect(
        formatRelativeActivity(now.subtract(const Duration(minutes: 59)), now),
        '59m',
      );
      expect(
        formatRelativeActivity(now.subtract(const Duration(hours: 1)), now),
        '1h',
      );
      expect(
        formatRelativeActivity(now.subtract(const Duration(hours: 23)), now),
        '23h',
      );
      expect(
        formatRelativeActivity(now.subtract(const Duration(days: 1)), now),
        '1d',
      );
    });

    test('treats a future stamp as clock skew, not time travel', () {
      expect(
        formatRelativeActivity(now.add(const Duration(minutes: 5)), now),
        'now',
      );
    });
  });

  group('SessionListTile', () {
    Widget host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 320, child: child),
        ),
      ),
    );

    testWidgets('same-repo sessions differ on their leading line', (
      tester,
    ) async {
      final a = _session(
        branch: 'feat/one',
        repoRoot: '/dev/triage',
        worktreeRoot: '/dev/triage/worktrees/one',
      );
      final b = _session(
        branch: 'feat/two',
        repoRoot: '/dev/triage',
        worktreeRoot: '/dev/triage/worktrees/two',
      );

      await tester.pumpWidget(
        host(
          Column(
            children: [
              SessionListTile(
                title: a.railTitle,
                subtitle: a.status,
                statusColor: a.statusColor,
                icon: a.icon,
                branch: a.branch,
                repoName: a.repoName,
                worktreeName: a.worktreeName,
                onTap: () {},
              ),
              SessionListTile(
                title: b.railTitle,
                subtitle: b.status,
                statusColor: b.statusColor,
                icon: b.icon,
                branch: b.branch,
                repoName: b.repoName,
                worktreeName: b.worktreeName,
                onTap: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.text('feat/one'), findsOneWidget);
      expect(find.text('feat/two'), findsOneWidget);
      // The shared repo appears as context on each row, never as the lead.
      expect(find.text('triage'), findsNWidgets(2));
    });

    testWidgets('the meta line never repeats the title', (tester) async {
      await tester.pumpWidget(
        host(
          SessionListTile(
            title: 'feat/rail-row',
            subtitle: 'attached',
            statusColor: const Color(0xff7fd1c7),
            icon: Icons.terminal,
            branch: 'feat/rail-row',
            repoName: 'triage',
            // Echoes the branch's last segment, so it is not repeated.
            worktreeName: 'rail-row',
            onTap: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('feat/rail-row'), findsOneWidget);
      expect(find.text('triage'), findsOneWidget);
      expect(find.text('rail-row'), findsNothing);
    });

    testWidgets('a distinct worktree name still earns its place', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          SessionListTile(
            title: 'feat/rail-row',
            subtitle: 'attached',
            statusColor: const Color(0xff7fd1c7),
            icon: Icons.terminal,
            branch: 'feat/rail-row',
            repoName: 'triage',
            worktreeName: 'scratch',
            onTap: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('triage  ·  scratch'), findsOneWidget);
    });

    testWidgets('indistinguishable rows give the snippet a second line', (
      tester,
    ) async {
      const snippet =
          'fixing the handover adoption timeout in the daemon restart path';

      Future<int> maxLinesFor({required bool indistinguishable}) async {
        await tester.pumpWidget(
          host(
            SessionListTile(
              title: 'feat/x',
              subtitle: 'attached',
              statusColor: const Color(0xff7fd1c7),
              icon: Icons.terminal,
              branch: 'feat/x',
              repoName: 'triage',
              snippet: snippet,
              indistinguishable: indistinguishable,
              onTap: () {},
            ),
          ),
        );
        await tester.pump();
        return tester.widget<Text>(find.text(snippet)).maxLines!;
      }

      expect(await maxLinesFor(indistinguishable: false), 1);
      expect(await maxLinesFor(indistinguishable: true), 2);
    });

    testWidgets('renders a relative activity stamp, and nothing without one', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          SessionListTile(
            title: 'feat/x',
            subtitle: 'attached',
            statusColor: const Color(0xff7fd1c7),
            icon: Icons.terminal,
            repoName: 'triage',
            activityAt: DateTime.now().subtract(const Duration(minutes: 4)),
            onTap: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('4m'), findsOneWidget);

      await tester.pumpWidget(
        host(
          SessionListTile(
            title: 'feat/x',
            subtitle: 'attached',
            statusColor: const Color(0xff7fd1c7),
            icon: Icons.terminal,
            repoName: 'triage',
            onTap: () {},
          ),
        ),
      );
      await tester.pump();
      // Not just the absence of '4m': a regression that invents a stamp for a
      // null activityAt would render some other label, and blank is the rule.
      expect(find.textContaining(RegExp(r'^(now|\d+[mhd])$')), findsNothing);
    });
  });

  group('the split between rail and header', () {
    Widget host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 420, height: 600, child: child),
        ),
      ),
    );

    testWidgets('the workspace header still leads with the repo', (
      tester,
    ) async {
      // Regression guard on the deliberate split: the header is the sole
      // statement of where you are and has no sibling to disambiguate against,
      // so it keeps displayTitle. Pointing it at railTitle would drop the repo.
      final session = _session(
        branch: 'feat/x',
        repoRoot: '/src/triage',
        worktreeRoot: '/src/triage',
      );
      // The two must actually differ, or the guard proves nothing.
      expect(session.displayTitle, isNot(session.railTitle));

      await tester.pumpWidget(host(WorkspaceHeader(session: session)));
      await tester.pump();

      // Not asserting railTitle's absence: the header also shows the branch in
      // its own right, so only the title line is the guard here.
      expect(find.text(session.displayTitle), findsOneWidget);
    });

    testWidgets('the tile announces the repo-first name to a screen reader', (
      tester,
    ) async {
      // The visible title is a bare branch and there is no meta line for a
      // screen reader to fall back on, so the label carries the full name.
      // Nothing visual catches this if it regresses to widget.title.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          SessionListTile(
            title: 'feat/x',
            glanceTitle: 'triage · feat/x',
            subtitle: 'attached',
            statusColor: const Color(0xff7fd1c7),
            icon: Icons.terminal,
            branch: 'feat/x',
            repoName: 'triage',
            onTap: () {},
          ),
        ),
      );
      await tester.pump();

      // The tile's label merges with its descendants, so match the
      // repo-first name within it rather than as the whole string.
      expect(find.bySemanticsLabel(RegExp(r'triage · feat/x')), findsOneWidget);
      handle.dispose();
    });

    testWidgets(
      'a repo session with an empty meta line is not shown as pathless',
      (tester) async {
        // railTitle falls back to the repo for a detached HEAD in a main
        // checkout, which leaves _gitMeta with nothing left to say, so the whole
        // meta row is skipped. What must not happen is the tile claiming the
        // session has no git context: the folder icon and the absolute cwd are
        // that signal, and both belong to sessions outside a repo.
        await tester.pumpWidget(
          host(
            SessionListTile(
              title: 'triage',
              subtitle: 'attached',
              statusColor: const Color(0xff7fd1c7),
              icon: Icons.terminal,
              repoName: 'triage',
              cwd: '/src/triage',
              onTap: () {},
            ),
          ),
        );
        await tester.pump();

        expect(find.byIcon(Icons.folder_outlined), findsNothing);
        expect(find.text('/src/triage'), findsNothing);
        // ...and the row it does render is the title, not a degraded fallback.
        expect(find.text('triage'), findsOneWidget);
      },
    );
  });
}
