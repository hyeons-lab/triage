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
      session.applyHistory([0x61], throughOutputSeq: 1, rawOutputStart: 4096);
      expect(session.historyStart, 4096);
    });

    test('applyHistory records the log start so paging stops', () {
      final session = _session();
      session.applyHistory([0x61], throughOutputSeq: 1, rawOutputStart: 0);
      expect(session.historyStart, 0);
    });

    test(
      'historyStart survives delta-merge snapshots and empty refreshes after noteViewFit',
      () {
        final session = _session();
        session.noteViewFit(80, 24);

        // Initial windowed attach serves bytes [4096..4100).
        session.applyHistory(
          const [0x61, 0x62, 0x63, 0x64],
          throughOutputSeq: 1,
          rawOutputStart: 4096,
        );
        expect(session.historyStart, 4096);

        // A later reconnect or refresh serves an overlapping sliding tail
        // [4098..4104) that delta-merges into the store without resetting the
        // buffer; the oldest byte in the terminal is still 4096.
        session.applyHistory(
          const [0x63, 0x64, 0x65, 0x66, 0x67, 0x68],
          throughOutputSeq: 2,
          rawOutputStart: 4098,
        );
        expect(session.historyStart, 4096);

        // A same-end snapshot [4100..4104) is a store no-op and also preserves
        // the original 4096 start.
        session.applyHistory(
          const [0x65, 0x66, 0x67, 0x68],
          throughOutputSeq: 2,
          rawOutputStart: 4100,
        );
        expect(session.historyStart, 4096);

        // An empty snapshot does not overwrite historyStart with 0.
        session.applyHistory(const [], throughOutputSeq: 2, rawOutputStart: 0);
        expect(session.historyStart, 4096);

        // Explicit Attach reset clears appliedHistoryStart so the next paged
        // replay records the newly served start offset.
        session.store.dispatch(const Attach());
        expect(session.historyStart, isNull);
        session.applyHistory(
          const [0x30, 0x31, 0x61, 0x62, 0x63, 0x64],
          throughOutputSeq: 2,
          rawOutputStart: 0,
        );
        expect(session.historyStart, 0);
      },
    );

    test(
      'empty snapshot before noteViewFit does not clobber staged pending history',
      () {
        final session = _session();
        session.applyHistory(
          const [0x61, 0x62],
          throughOutputSeq: 1,
          rawOutputStart: 2048,
        );
        expect(session.historyStart, 2048);

        session.applyHistory(const [], throughOutputSeq: 1, rawOutputStart: 0);
        expect(session.historyStart, 2048);

        session.noteViewFit(80, 24);
        expect(session.historyStart, 2048);
      },
    );
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

    test('null or non-positive window keeps the platform budgets', () {
      expect(
        historyTrimBudgetsForWindow(null, web: false),
        (maxLines: 1000, maxBytes: 262144),
      );
      expect(
        historyTrimBudgetsForWindow(0, web: false),
        (maxLines: 1000, maxBytes: 262144),
      );
      expect(
        historyTrimBudgetsForWindow(-1, web: false),
        (maxLines: 1000, maxBytes: 262144),
      );
      expect(
        historyTrimBudgetsForWindow(null, web: true),
        (maxLines: 50000, maxBytes: 1048576),
      );
    });

    test('sub-first-page window floors maxLines at the platform budget', () {
      expect(
        historyTrimBudgetsForWindow(1024, web: false),
        (maxLines: 1000, maxBytes: 1024),
      );
      expect(
        historyTrimBudgetsForWindow(10, web: false),
        (maxLines: 1000, maxBytes: 10),
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

    test(
      'dense tail at raw_output_start == 0 records exact droppedBytes start across 64/128/256 KiB windows until all lines are retained',
      () {
        final session = _session();
        final tail = numberedLines(2500);
        final expectedDroppedAt64k = numberedLines(1500).length;
        final expectedDroppedAt128k = numberedLines(500).length;
        expect(tail.length, lessThan(kHistoryFirstWindowBytes));

        // First page (64 KiB, 1000-line budget) drops the oldest 1500 lines;
        // both pre-fit (_PendingHistory.effectiveStart) and post-fit
        // (store.appliedHistoryStart) report the exact cut offset.
        session.applyHistory(
          tail,
          throughOutputSeq: 7,
          rawOutputStart: 0,
          windowBytes: kHistoryFirstWindowBytes,
        );
        expect(session.historyStart, expectedDroppedAt64k);
        session.noteViewFit(80, 24);
        expect(session.historyStart, expectedDroppedAt64k);

        // Second page (128 KiB, 2000-line budget) drops only the oldest 500
        // lines, strictly reducing historyStart while keeping it > 0.
        session.store.dispatch(const Attach());
        session.historyWindowBytes = kHistoryFirstWindowBytes * 2;
        session.applyHistory(
          tail,
          throughOutputSeq: 7,
          rawOutputStart: 0,
          windowBytes: kHistoryFirstWindowBytes * 2,
        );
        expect(session.historyStart, expectedDroppedAt128k);
        expect(session.historyStart, lessThan(expectedDroppedAt64k));

        // Third page (256 KiB, 4000-line budget) retains all 2500 lines,
        // moving historyStart down to 0 so paging stops only once all lines
        // are actually in the terminal buffer.
        session.store.dispatch(const Attach());
        session.historyWindowBytes = kHistoryFirstWindowBytes * 4;
        session.applyHistory(
          tail,
          throughOutputSeq: 7,
          rawOutputStart: 0,
          windowBytes: kHistoryFirstWindowBytes * 4,
        );
        expect(session.historyStart, 0);
      },
    );

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

  group('trimHistoryTailWithOffset', () {
    test('returns droppedBytes == 0 when input fits within line and byte budgets', () {
      final raw = utf8.encode('line 0\nline 1\nline 2\n');
      final res = trimHistoryTailWithOffset(raw, maxLines: 10, maxBytes: 1024);
      expect(res.droppedBytes, 0);
      expect(res.bytes, same(raw));
    });

    test('returns exact cut index without SGR reset prefix when line-trimmed', () {
      final prefix = utf8.encode('line 0\nline 1\n');
      final suffix = utf8.encode('line 2\nline 3\n');
      final raw = <int>[...prefix, ...suffix];
      final res = trimHistoryTailWithOffset(raw, maxLines: 2, maxBytes: 1024);
      expect(res.droppedBytes, prefix.length);
      expect(res.bytes, <int>[0x1b, 0x5b, 0x30, 0x6d, ...suffix]);
    });

    test('returns exact cut index when byte-trimmed to next newline boundary', () {
      final line0 = utf8.encode('0123456789\n'); // 11 bytes
      final line1 = utf8.encode('abcdefghij\n'); // 11 bytes
      final line2 = utf8.encode('klmnopqrst\n'); // 11 bytes
      final raw = <int>[...line0, ...line1, ...line2];
      // maxBytes: 25 cuts inside line0 and advances to the start of line1.
      final res = trimHistoryTailWithOffset(raw, maxLines: 10, maxBytes: 25);
      expect(res.droppedBytes, line0.length);
      expect(res.bytes, <int>[0x1b, 0x5b, 0x30, 0x6d, ...line1, ...line2]);
    });

    test('returns droppedBytes == bytes.length when budgets are non-positive', () {
      final raw = utf8.encode('line 0\nline 1\n');
      final zeroLines = trimHistoryTailWithOffset(
        raw,
        maxLines: 0,
        maxBytes: 1024,
      );
      expect(zeroLines.droppedBytes, raw.length);
      expect(zeroLines.bytes, isEmpty);

      final zeroBytes = trimHistoryTailWithOffset(
        raw,
        maxLines: 10,
        maxBytes: 0,
      );
      expect(zeroBytes.droppedBytes, raw.length);
      expect(zeroBytes.bytes, isEmpty);
    });
  });
}
