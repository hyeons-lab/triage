import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/main.dart';

/// Covers the two decisions that decide whether this client competes for the
/// shared PTY's size: whether it currently counts as foreground, and whether
/// the host has drifted from the size it last fitted to.
void main() {
  SessionVm session() => SessionVm(
    title: 'shell',
    status: 'running',
    statusColor: Colors.green,
    icon: Icons.terminal,
    rows: const [],
    isRemote: true,
  );

  group('foregroundForLifecycle', () {
    test('only resumed asserts a size', () {
      expect(foregroundForLifecycle(AppLifecycleState.resumed), isTrue);
    });

    test('a blurred but visible client does not', () {
      // The one most easily got wrong. Flutter's web engine reports a window
      // blur as `inactive`, and a blurred window is precisely when the user is
      // looking at another device.
      expect(foregroundForLifecycle(AppLifecycleState.inactive), isFalse);
    });

    test('backgrounded and detached clients do not', () {
      expect(foregroundForLifecycle(AppLifecycleState.hidden), isFalse);
      expect(foregroundForLifecycle(AppLifecycleState.paused), isFalse);
      expect(foregroundForLifecycle(AppLifecycleState.detached), isFalse);
    });
  });

  group('hostSizeDriftedFromOwnFit', () {
    test('is false before this device has fitted', () {
      final vm = session()
        ..hostSizeCols = 95
        ..hostSizeRows = 34;

      // Nothing to reclaim to yet, so leave the PTY alone.
      expect(vm.hostSizeDriftedFromOwnFit, isFalse);
    });

    test('is false before the host has reported a size', () {
      final vm = session()
        ..ownFittedCols = 95
        ..ownFittedRows = 34;

      expect(vm.hostSizeDriftedFromOwnFit, isFalse);
    });

    test('is false when the PTY is already our size', () {
      final vm = session()
        ..ownFittedCols = 95
        ..ownFittedRows = 34
        ..hostSizeCols = 95
        ..hostSizeRows = 34
        ..lastFittedCols = 95
        ..lastFittedRows = 34;

      // Regaining focus has to be free in the single-device case: the refit
      // this gates jiggles the host to force a repaint.
      expect(vm.hostSizeDriftedFromOwnFit, isFalse);
    });

    test('is true when another device has taken the width', () {
      // A host broadcast writes `lastFitted*` alongside `hostSize*`, so this
      // is the shape the fields really take after another device resizes.
      final vm = session()
        ..ownFittedCols = 95
        ..ownFittedRows = 34
        ..hostSizeCols = 47
        ..hostSizeRows = 19
        ..lastFittedCols = 47
        ..lastFittedRows = 19;

      expect(vm.hostSizeDriftedFromOwnFit, isTrue);
    });

    test('is true when only the rows differ', () {
      final vm = session()
        ..ownFittedCols = 95
        ..ownFittedRows = 34
        ..hostSizeCols = 95
        ..hostSizeRows = 19
        ..lastFittedCols = 95
        ..lastFittedRows = 19;

      expect(vm.hostSizeDriftedFromOwnFit, isTrue);
    });

    test('survives a local fit arriving while backgrounded', () {
      final vm = session()
        ..ownFittedCols = 95
        ..ownFittedRows = 34
        ..hostSizeCols = 47
        ..hostSizeRows = 19;

      // A backgrounded client still fits: a window moves behind another, the
      // DPI changes, the tree rebuilds. That records `lastFitted*` without
      // forwarding anything to the host. Comparing against `lastFitted*` here
      // would now see our own size on both sides, report no drift, and leave
      // the client stuck at the other device's width on refocus.
      vm
        ..lastFittedCols = 95
        ..lastFittedRows = 34;

      expect(vm.hostSizeDriftedFromOwnFit, isTrue);
    });
  });
}
