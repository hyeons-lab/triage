import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/main.dart';

/// A session with no seeded rows — enough to reach its live `terminal`, which is
/// the object the reflow flag is set on.
SessionVm _session() => SessionVm(
  title: 'triage / main',
  status: 'attached',
  statusColor: const Color(0xff7fd1c7),
  icon: Icons.terminal,
  rows: const [],
);

/// The trimmed text of the buffer row that currently holds [needle], or null if
/// no row contains it.
String? _rowContaining(SessionVm session, String needle) {
  final lines = session.terminal.buffer.lines;
  for (var i = 0; i < lines.length; i++) {
    final text = lines[i].getText().trimRight();
    if (text.contains(needle)) return text;
  }
  return null;
}

void main() {
  group('session terminal reflow on resize', () {
    test('widening rejoins a soft-wrapped scrollback line', () {
      final session = _session();
      // Narrow enough that a 16-char logical line soft-wraps onto two rows.
      session.terminal.resize(10, 6);

      // No newline: the wrap is xterm's own auto-wrap, which flags the
      // continuation row `isWrapped` — the signal reflow rejoins on.
      session.terminal.write('ABCDEFGHIJKLMNOP');
      expect(
        _rowContaining(session, 'ABCDEFGHIJ'),
        'ABCDEFGHIJ',
        reason: 'precondition: the line is split at width 10',
      );

      // Widen past the logical line's length. With reflow enabled the two rows
      // rejoin; with `reflowEnabled: false` they stay split and this fails.
      session.terminal.resize(20, 6);

      expect(
        _rowContaining(session, 'ABCDEFGHIJKLMNOP'),
        'ABCDEFGHIJKLMNOP',
        reason: 'reflow should rewrap scrollback, not just the visible frame',
      );
    });

    test('narrowing re-splits a line that previously fit', () {
      final session = _session();
      session.terminal.resize(20, 6);
      session.terminal.write('ABCDEFGHIJKLMNOP');
      expect(_rowContaining(session, 'ABCDEFGHIJKLMNOP'), isNotNull);

      session.terminal.resize(10, 6);

      // Sanity check (does NOT by itself distinguish reflow from plain
      // truncation): the full line is no longer on any single row.
      expect(_rowContaining(session, 'ABCDEFGHIJKLMNOP'), isNull);
      // The discriminator: reflow moves the tail onto its own wrapped row. With
      // `reflowEnabled: false`, narrowing only truncates each line in place, so
      // 'KLMNOP' (cells 10-15) is dropped past the shortened length and this
      // fails — which is what the mutation check confirmed.
      expect(_rowContaining(session, 'KLMNOP'), isNotNull);
    });

    test('widening does not rejoin lines split by a hard newline', () {
      final session = _session();
      session.terminal.resize(10, 6);
      // A hard newline (\r\n) is a logical-line boundary, not a soft wrap, so the
      // continuation row is not flagged `isWrapped` and reflow must leave the two
      // lines separate even though they would fit together on the wider grid.
      session.terminal.write('ABCDE\r\nFGHIJ');

      session.terminal.resize(20, 6);

      expect(_rowContaining(session, 'ABCDE'), 'ABCDE');
      expect(_rowContaining(session, 'FGHIJ'), 'FGHIJ');
      expect(_rowContaining(session, 'ABCDEFGHIJ'), isNull);
    });
  });
}
