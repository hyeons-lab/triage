import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:triage_client/main.dart';
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
}
