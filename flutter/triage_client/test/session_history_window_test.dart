import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:triage_client/main.dart';
import 'package:triage_client/terminal/terminal_intent.dart';
import 'package:triage_client/terminal/terminal_store.dart';

SessionVm _session() {
  return SessionVm(
    title: 'triage / window-probe',
    status: 'attached',
    statusColor: const Color(0xff7fd1c7),
    icon: Icons.terminal,
    rows: const [],
    isRemote: true,
    isExited: false,
  );
}

void main() {
  group('history window tracking', () {
    test('starts at the first-page window with no recorded start', () {
      final session = _session();
      expect(session.historyWindowBytes, kHistoryFirstWindowBytes);
      expect(session.historyStart, isNull);
      expect(session.pagingHistory, isFalse);
    });

    test('applyHistory records the served start for the stop check', () {
      final session = _session();
      session.applyHistory(
        [0x61],
        throughOutputSeq: 1,
        rawOutputStart: 4096,
      );
      expect(session.historyStart, 4096);
    });

    test('applyHistory records the log start so paging stops', () {
      final session = _session();
      session.applyHistory([0x61], throughOutputSeq: 1, rawOutputStart: 0);
      expect(session.historyStart, 0);
    });

    test('applyHistory synchronizes historyWindowBytes', () {
      final session = _session();
      session.applyHistory(
        [0x61],
        throughOutputSeq: 1,
        rawOutputStart: 4096,
        windowBytes: 131072,
      );
      expect(session.historyWindowBytes, 131072);
    });
  });

  group('history trim budgets', () {
    test('first window keeps the first-page budgets', () {
      expect(
        historyTrimBudgetsForWindow(kHistoryFirstWindowBytes, web: false),
        (maxLines: 1000, maxBytes: 65536),
      );
    });

    test('deeper windows scale the budgets with the window', () {
      expect(
        historyTrimBudgetsForWindow(131072, web: false),
        (maxLines: 2000, maxBytes: 131072),
      );
      expect(
        historyTrimBudgetsForWindow(262144, web: false),
        (maxLines: 4000, maxBytes: 262144),
      );
    });

    test('web budgets stay at the platform cap', () {
      expect(
        historyTrimBudgetsForWindow(65536, web: true),
        (maxLines: 50000, maxBytes: 65536),
      );
      expect(
        historyTrimBudgetsForWindow(1048576, web: true),
        (maxLines: 50000, maxBytes: 1048576),
      );
    });

    test('null and non-positive windows keep platform budgets', () {
      for (final w in [null, 0, -1]) {
        expect(
          historyTrimBudgetsForWindow(w, web: false),
          (maxLines: 1000, maxBytes: 262144),
        );
        expect(
          historyTrimBudgetsForWindow(w, web: true),
          (maxLines: 50000, maxBytes: 1048576),
        );
      }
    });

    test('small positive window maintains at least one line', () {
      expect(
        historyTrimBudgetsForWindow(50, web: false),
        (maxLines: 1, maxBytes: 50),
      );
    });
  });

  group('windowed replay', () {
    List<int> numberedLines(int count) {
      final buf = StringBuffer();
      for (var i = 0; i < count; i++) {
        buf.writeln('history line $i');
      }
      return utf8.encode(buf.toString());
    }

    test('a deeper windowed replay grows the terminal buffer', () {
      // A 2000-line tail over the first-page window trims to 1000 lines;
      // the same suffix served for a doubled window must emulate twice
      // the lines, not replay the identical trimmed suffix.
      final session = _session();
      final tail = numberedLines(2000);
      session.applyHistory(
        tail,
        throughOutputSeq: 7,
        rawOutputStart: 50000,
        windowBytes: kHistoryFirstWindowBytes,
      );
      session.noteViewFit(80, 24);
      final firstLines = session.terminal.buffer.lines.length;

      session.store.dispatch(const Attach());
      session.historyWindowBytes = 131072;
      session.applyHistory(
        tail,
        throughOutputSeq: 7,
        rawOutputStart: 50000,
        windowBytes: 131072,
      );
      expect(
        session.terminal.buffer.lines.length,
        greaterThan(firstLines),
      );
    });

    test('an unwindowed replay keeps what the held window would trim', () {
      // 500 lines x 300 B = 150 KiB: the platform budgets (256 KiB) keep
      // all of it, while the 64 KiB held window trims to the newest ~218
      // lines. Server-pushed resync snapshots are served unwindowed at
      // the full cap and must replay at the platform budgets, not the
      // held window (see the `unwindowed` resync call site).
      List<int> wideLines(int count) {
        final buf = StringBuffer();
        for (var i = 0; i < count; i++) {
          buf.writeln('history line $i'.padRight(299));
        }
        return utf8.encode(buf.toString());
      }

      final windowed = _session();
      windowed.applyHistory(
        wideLines(500),
        throughOutputSeq: 50,
        rawOutputStart: 1000000,
        windowBytes: kHistoryFirstWindowBytes,
      );
      windowed.noteViewFit(80, 24);
      final windowedLines = windowed.terminal.buffer.lines.length;

      final unwindowed = _session();
      unwindowed.applyHistory(
        wideLines(500),
        throughOutputSeq: 50,
        rawOutputStart: 1000000,
      );
      unwindowed.noteViewFit(80, 24);
      final unwindowedLines = unwindowed.terminal.buffer.lines.length;

      expect(unwindowedLines, greaterThanOrEqualTo(500));
      expect(unwindowedLines, greaterThan(windowedLines));
    });
  });
}
