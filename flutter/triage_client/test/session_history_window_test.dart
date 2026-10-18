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
}
