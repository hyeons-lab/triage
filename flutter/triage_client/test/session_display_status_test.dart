import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:triage_client/main.dart';

SessionVm _session({
  String status = 'attached',
  Color statusColor = const Color(0xff7fd1c7),
  bool isRemote = true,
  bool isExited = false,
}) {
  return SessionVm(
    title: 'triage / status-probe',
    status: status,
    statusColor: statusColor,
    icon: Icons.terminal,
    rows: const [],
    isRemote: isRemote,
    isExited: isExited,
  );
}

void main() {
  group('displayStatus', () {
    test('reports the sticky status on a live socket', () {
      final display = _session().displayStatus(connected: true);
      expect(display.text, 'attached');
      expect(display.color, const Color(0xff7fd1c7));
    });

    test('reads disconnected on a dead socket despite sticky attached', () {
      final display = _session().displayStatus(connected: false);
      expect(display.text, 'disconnected');
      expect(display.color, const Color(0xffff6b6b));
    });

    test('leaves local sessions alone on a dead socket', () {
      final display = _session(
        status: 'idle',
        statusColor: const Color(0xff7f8b8d),
        isRemote: false,
      ).displayStatus(connected: false);
      expect(display.text, 'idle');
      expect(display.color, const Color(0xff7f8b8d));
    });

    test('leaves exited sessions alone on a dead socket', () {
      final display = _session(
        status: 'exited',
        statusColor: const Color(0xff7f8b8d),
        isExited: true,
      ).displayStatus(connected: false);
      expect(display.text, 'exited');
      expect(display.color, const Color(0xff7f8b8d));
    });

    // The exited guard has two conjuncts (the isExited flag and the sticky
    // 'exited' status string); construction sites set both, so each needs
    // a leg of its own or deleting either conjunct stays green.
    test('the isExited flag alone leaves the session alone', () {
      final display = _session(
        status: 'attached',
        isExited: true,
      ).displayStatus(connected: false);
      expect(display.text, 'attached');
    });

    test("the 'exited' status alone leaves the session alone", () {
      final display = _session(
        status: 'exited',
        statusColor: const Color(0xff7f8b8d),
      ).displayStatus(connected: false);
      expect(display.text, 'exited');
    });
  });
}
