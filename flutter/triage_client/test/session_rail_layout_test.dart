import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/session_grouping.dart';
import 'package:triage_client/session_rail_layout.dart';

SessionOrderingInput session(String id, {String? repo, int activity = 0}) =>
    SessionOrderingInput(
      sessionId: id,
      repoRoot: repo,
      lastActivityMs: activity,
    );

/// Compact view of the rail for assertions: headers as `#key`, rows as the id.
List<String> render(List<RailItem> items) => [
  for (final item in items)
    if (item.isHeader) '#${item.groupKey}' else item.sessionId!,
];

List<RailItem> railFor(
  List<SessionOrderingInput> sessions, {
  SessionPins pins = SessionPins.none,
}) {
  final groups = groupSessionsByRepo(sessions, pins: pins);
  return buildRailItems(flattenGroups(groups), groups);
}

void main() {
  group('pinned ordering', () {
    test('a pinned group leads, others still flow by activity', () {
      final sessions = [
        session('session-1', repo: '/a', activity: 10),
        session('session-2', repo: '/b', activity: 900),
        session('session-3', repo: '/c', activity: 500),
      ];

      final groups = groupSessionsByRepo(
        sessions,
        pins: const SessionPins(groupKeys: ['/a']),
      );

      // /a is pinned to the top despite being the least recent; /b and /c keep
      // their activity order beneath it.
      expect(groups.map((g) => g.repoRoot), ['/a', '/b', '/c']);
    });

    test('pinned groups keep their pinned order relative to each other', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 1),
        session('session-2', repo: '/b', activity: 999),
        session('session-3', repo: '/c', activity: 500),
      ], pins: const SessionPins(groupKeys: ['/c', '/a']));

      expect(groups.map((g) => g.repoRoot), ['/c', '/a', '/b']);
    });

    test('a pinned session leads its group', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 10),
        session('session-2', repo: '/a', activity: 900),
      ], pins: const SessionPins(sessionIds: ['session-1']));

      expect(groups.single.sessionIds, ['session-1', 'session-2']);
    });

    test('pinning does not alter a group\'s activity', () {
      // Activity is what a group reverts to on unpin, so pinning must not
      // overwrite it — otherwise unpinning would strand the group.
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 5),
        session('session-2', repo: '/b', activity: 900),
      ], pins: const SessionPins(groupKeys: ['/a']));

      expect(groups.first.repoRoot, '/a');
      expect(groups.first.lastActivityMs, 5);
    });

    test('a pin naming an absent group is ignored, not fatal', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 1),
      ], pins: const SessionPins(groupKeys: ['/gone', '/a']));

      expect(groups.map((g) => g.repoRoot), ['/a']);
    });

    test('the repo-less group can be pinned via its sentinel key', () {
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 900),
        session('session-2', activity: 1),
      ], pins: const SessionPins(groupKeys: [otherGroupPinKey]));

      expect(groups.first.repoRoot, isNull);
      expect(groups.first.pinKey, otherGroupPinKey);
    });
  });

  group('buildRailItems', () {
    test('omits headers when there is only one group', () {
      final rail = railFor([
        session('session-1', repo: '/a', activity: 2),
        session('session-2', repo: '/a', activity: 1),
      ]);

      expect(render(rail), ['session-1', 'session-2']);
    });

    test('emits a header per group when there are several', () {
      final rail = railFor([
        session('session-1', repo: '/a', activity: 900),
        session('session-2', repo: '/b', activity: 5),
      ]);

      expect(render(rail), ['#/a', 'session-1', '#/b', 'session-2']);
    });

    test('renders a session the grouping has not seen yet', () {
      // The rail's session list and its grouping are recomputed at different
      // times, so a session started since the last grouping must still get a
      // row. Reading the layout off the groups alone dropped it entirely.
      final groups = groupSessionsByRepo([
        session('session-1', repo: '/a', activity: 900),
        session('session-2', repo: '/b', activity: 5),
      ]);

      final rail = buildRailItems([
        ...flattenGroups(groups),
        'session-brand-new',
      ], groups);

      expect(render(rail), [
        '#/a',
        'session-1',
        '#/b',
        'session-2',
        'session-brand-new',
      ]);
    });

    test('renders every session when the grouping is empty', () {
      // A daemon too old to report context yields no groups; the rail must
      // still list its sessions rather than coming up blank.
      final rail = buildRailItems(['session-1', 'session-2'], const []);
      expect(render(rail), ['session-1', 'session-2']);
    });
  });

  group('resolveRailReorder', () {
    // /a (session-1, session-2) then /b (session-3), by activity.
    final sessions = [
      session('session-1', repo: '/a', activity: 900),
      session('session-2', repo: '/a', activity: 800),
      session('session-3', repo: '/b', activity: 100),
    ];

    test('dragging a header pins and moves the whole group', () {
      final rail = railFor(sessions);
      expect(render(rail), [
        '#/a',
        'session-1',
        'session-2',
        '#/b',
        'session-3',
      ]);

      // Drag /b's header (index 3) to the very top.
      final pins = resolveRailReorder(
        items: rail,
        pins: SessionPins.none,
        oldIndex: 3,
        newIndex: 0,
      );

      expect(pins.groupKeys, ['/b']);
      expect(render(railFor(sessions, pins: pins)), [
        '#/b',
        'session-3',
        '#/a',
        'session-1',
        'session-2',
      ]);
    });

    test('dragging a row reorders it within its group', () {
      final rail = railFor(sessions);

      // Drag session-2 (index 2) above session-1 (index 1).
      final pins = resolveRailReorder(
        items: rail,
        pins: SessionPins.none,
        oldIndex: 2,
        newIndex: 1,
      );

      expect(pins.sessionIds, ['session-2']);
      expect(
        railFor(
          sessions,
          pins: pins,
        ).where((i) => !i.isHeader).map((i) => i.sessionId),
        ['session-2', 'session-1', 'session-3'],
      );
    });

    test('a row dropped into another group stays in its own', () {
      final rail = railFor(sessions);

      // Drag session-3 (in /b, index 4) up into /a's rows.
      final pins = resolveRailReorder(
        items: rail,
        pins: SessionPins.none,
        oldIndex: 4,
        newIndex: 1,
      );

      final grouped = groupSessionsByRepo(sessions, pins: pins);
      final b = grouped.firstWhere((g) => g.repoRoot == '/b');
      final a = grouped.firstWhere((g) => g.repoRoot == '/a');
      // Membership follows the working directory, so the drag saturates at /b's
      // first slot instead of moving the session into /a.
      expect(b.sessionIds, ['session-3']);
      expect(a.sessionIds, isNot(contains('session-3')));
    });

    test('dragging a row DOWN moves it down', () {
      // Regression: a top-block pin can only hold a position if everything above
      // it is pinned too, so inserting into the pinned list alone made every
      // downward drag clamp to 0 and spring back to the top. Half the gesture
      // silently did nothing, and every test only ever dragged upward.
      final rail = railFor(sessions);
      expect(render(rail), [
        '#/a',
        'session-1',
        'session-2',
        '#/b',
        'session-3',
      ]);

      // Drag session-1 (index 1) below session-2 (drop index 3).
      final pins = resolveRailReorder(
        items: rail,
        pins: SessionPins.none,
        oldIndex: 1,
        newIndex: 3,
      );

      expect(render(railFor(sessions, pins: pins)), [
        '#/a',
        'session-2',
        'session-1',
        '#/b',
        'session-3',
      ]);
    });

    test('dragging a header DOWN moves that group down', () {
      final rail = railFor(sessions);

      // Drag /a's header (index 0) below /b.
      final pins = resolveRailReorder(
        items: rail,
        pins: SessionPins.none,
        oldIndex: 0,
        newIndex: 4,
      );

      expect(render(railFor(sessions, pins: pins)), [
        '#/b',
        'session-3',
        '#/a',
        'session-1',
        'session-2',
      ]);
    });

    test('a downward drag does not release pins above it', () {
      // Three rows in one group, so there are no headers and a downward drag has
      // somewhere to land. Pin session-1, then drag session-2 past session-3;
      // session-1 must stay pinned rather than being truncated out of the prefix.
      final oneGroup = [
        session('session-1', repo: '/a', activity: 900),
        session('session-2', repo: '/a', activity: 800),
        session('session-3', repo: '/a', activity: 100),
      ];
      final pins0 = const SessionPins(sessionIds: ['session-1']);
      final rail = railFor(oneGroup, pins: pins0);
      expect(render(rail), ['session-1', 'session-2', 'session-3']);

      final pins = resolveRailReorder(
        items: rail,
        pins: pins0,
        oldIndex: 1, // session-2
        newIndex: 3, // past session-3
      );

      expect(pins.sessionIds, contains('session-1'));
      expect(pins.sessionIds, ['session-1', 'session-3', 'session-2']);
    });

    test('a drag that resolves to its own position pins nothing', () {
      // The clamp that keeps a drag from feeling dead also maps plenty of real
      // drags back onto themselves, and every one of them looks to the user like
      // nothing happened. Rail: [#/a, session-1, session-2, #/b, session-3].
      final rail = railFor(sessions);
      expect(render(rail), [
        '#/a',
        'session-1',
        'session-2',
        '#/b',
        'session-3',
      ]);

      // A header dragged down over its own rows never reaches the next header,
      // so its group index does not change.
      expect(
        resolveRailReorder(
          items: rail,
          pins: SessionPins.none,
          oldIndex: 0,
          newIndex: 2,
        ).isEmpty,
        isTrue,
        reason: '/a dragged over its own rows stays first',
      );
      // A header dragged up into the group above, but not past that group's
      // header, likewise. This one is the worst case: a leading block would pin
      // /a as well as /b.
      expect(
        resolveRailReorder(
          items: rail,
          pins: SessionPins.none,
          oldIndex: 3,
          newIndex: 1,
        ).isEmpty,
        isTrue,
        reason: '/b dragged short of /a\'s header stays second',
      );
      // A group's first row dragged onto its own header clamps back to index 0
      // of its group, which is where it already was.
      expect(
        resolveRailReorder(
          items: rail,
          pins: SessionPins.none,
          oldIndex: 1,
          newIndex: 0,
        ).isEmpty,
        isTrue,
        reason: 'session-1 dragged onto its header stays first in /a',
      );
    });

    test('a drag that ends where it started pins nothing', () {
      // `ReorderableListView` reports a row dragged down past its neighbour's
      // midpoint and released back on its own slot as `newIndex == oldIndex + 1`.
      // That is a null gesture, and it used to pin the whole prefix above the
      // row: badges on rows the user never moved, and a reset control offered for
      // a layout they never made.
      final rail = railFor(sessions);
      for (final oldIndex in [1, 2, 4]) {
        expect(
          resolveRailReorder(
            items: rail,
            pins: SessionPins.none,
            oldIndex: oldIndex,
            newIndex: oldIndex + 1,
          ).isEmpty,
          isTrue,
          reason: 'row at $oldIndex did not move',
        );
      }
      // Headers report it the same way, and a group move is the more damaging
      // one — it pins every group above as well.
      for (final headerIndex in [0, 3]) {
        expect(
          resolveRailReorder(
            items: rail,
            pins: SessionPins.none,
            oldIndex: headerIndex,
            newIndex: headerIndex + 1,
          ).isEmpty,
          isTrue,
          reason: 'header at $headerIndex did not move',
        );
      }
    });

    test('an out-of-range drag is a no-op rather than a crash', () {
      final rail = railFor(sessions);
      final pins = resolveRailReorder(
        items: rail,
        pins: SessionPins.none,
        oldIndex: 99,
        newIndex: 0,
      );

      expect(pins.isEmpty, isTrue);
    });

    test('re-dragging an already-pinned group moves it without duplicating', () {
      final rail = railFor(
        sessions,
        pins: const SessionPins(groupKeys: ['/b']),
      );
      // Rail is now: #/b, session-3, #/a, session-1, session-2
      final pins = resolveRailReorder(
        items: rail,
        pins: const SessionPins(groupKeys: ['/b']),
        oldIndex: 0,
        newIndex: 3,
      );

      // /b lands below /a, which means /a has to be pinned too — a leading block
      // cannot hold an entry beneath an unpinned one. The invariant under test is
      // that the entry moves rather than accumulating a second time.
      expect(pins.groupKeys, ['/a', '/b']);
      expect(pins.groupKeys.toSet().length, pins.groupKeys.length);
      expect(render(railFor(sessions, pins: pins)), [
        '#/a',
        'session-1',
        'session-2',
        '#/b',
        'session-3',
      ]);
    });
  });

  group('session drags and absent pins', () {
    test('a pin naming a session with no live row keeps its slot', () {
      // `session-2` is pinned but not running right now — its repository is
      // still on the rail through `session-1` and `session-3`. Its pin has to
      // survive a drag *and* stay ranked where it was, because that slot is the
      // whole promise being made: it is held for when the session comes back.
      final sessions = [
        session('session-1', repo: '/a', activity: 10),
        session('session-3', repo: '/a', activity: 900),
      ];
      final rail = railFor(
        sessions,
        pins: const SessionPins(sessionIds: ['session-1', 'session-2']),
      );

      // Drag session-3 (last row) to the top of its group.
      final pins = resolveRailReorder(
        items: rail,
        pins: const SessionPins(sessionIds: ['session-1', 'session-2']),
        oldIndex: rail.indexWhere((i) => i.sessionId == 'session-3'),
        newIndex: 0,
      );

      expect(
        pins.sessionIds,
        contains('session-2'),
        reason: 'an absent pin is skipped, never dropped',
      );
      // Held at the index it had, rather than collected in front of the live
      // rows: hoisting it would silently promote session-2 to the top of its own
      // group the moment it came back, which is not the slot it was held for.
      expect(pins.sessionIds, ['session-3', 'session-2', 'session-1']);
    });

    test('dragging the only row in a group pins nothing', () {
      // The clamp lands it back on itself: a row alone in its group has no
      // other row to move past. Pinning anyway would record a layout the user
      // never produced, and leave the reset action showing with nothing to
      // reset.
      final sessions = [
        session('session-1', repo: '/a', activity: 900),
        session('session-2', repo: '/b', activity: 10),
      ];
      final rail = railFor(sessions);

      final pins = resolveRailReorder(
        items: rail,
        pins: SessionPins.none,
        oldIndex: rail.indexWhere((i) => i.sessionId == 'session-2'),
        newIndex: 0,
      );

      expect(pins.isEmpty, isTrue);
    });
  });

  group('unpin', () {
    test('returns a group to activity ordering', () {
      const pins = SessionPins(groupKeys: ['/a', '/b']);
      expect(unpin(pins, groupKey: '/a').groupKeys, ['/b']);
    });

    test('returns a session to activity ordering', () {
      const pins = SessionPins(sessionIds: ['session-1', 'session-2']);
      expect(unpin(pins, sessionId: 'session-1').sessionIds, ['session-2']);
    });

    test('leaves the other axis untouched', () {
      const pins = SessionPins(groupKeys: ['/a'], sessionIds: ['session-1']);
      final after = unpin(pins, groupKey: '/a');
      expect(after.groupKeys, isEmpty);
      expect(after.sessionIds, ['session-1']);
    });
  });

  test('clearing all pins restores pure activity order', () {
    final sessions = [
      session('session-1', repo: '/a', activity: 10),
      session('session-2', repo: '/b', activity: 900),
    ];
    final pinned = groupSessionsByRepo(
      sessions,
      pins: const SessionPins(groupKeys: ['/a']),
    );
    expect(pinned.map((g) => g.repoRoot), ['/a', '/b']);

    final reset = groupSessionsByRepo(sessions, pins: SessionPins.none);
    expect(reset.map((g) => g.repoRoot), ['/b', '/a']);
  });
}
