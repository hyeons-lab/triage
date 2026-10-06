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

    test('null window keeps the platform budgets', () {
      expect(
        historyTrimBudgetsForWindow(null, web: false),
        (maxLines: 1000, maxBytes: 262144),
      );
      expect(
        historyTrimBudgetsForWindow(null, web: true),
        (maxLines: 50000, maxBytes: 1048576),
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
  });
}
