import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/widgets/terminal_pane.dart';

void main() {
  test(
    'refit notifies only refit listeners, fit notifies only fit listeners',
    () {
      final controller = TerminalController();
      var fitCount = 0;
      var refitCount = 0;
      controller.addFitListener(() => fitCount++);
      controller.addRefitListener(() => refitCount++);

      // The two are distinct channels: the resize observer's `fit` must not fire
      // the explicit-refit path (which force-sends to the host), and vice versa.
      controller.fit();
      expect(fitCount, 1);
      expect(refitCount, 0);

      controller.refit();
      expect(fitCount, 1);
      expect(refitCount, 1);
    },
  );

  test('removeRefitListener stops delivery', () {
    final controller = TerminalController();
    var count = 0;
    void listener() => count++;
    controller.addRefitListener(listener);
    controller.refit();
    controller.removeRefitListener(listener);
    controller.refit();
    expect(count, 1);
  });

  test('dispose clears refit listeners', () {
    final controller = TerminalController();
    var count = 0;
    controller.addRefitListener(() => count++);
    controller.dispose();
    controller.refit();
    expect(count, 0);
  });

  test('history page started and cancelled listeners lifecycle', () {
    final controller = TerminalController();
    var startedCount = 0;
    var cancelledCount = 0;
    void onStarted() => startedCount++;
    void onCancelled() => cancelledCount++;

    controller.addHistoryPageStartedListener(onStarted);
    controller.addHistoryPageCancelledListener(onCancelled);

    controller.notifyHistoryPageStarted();
    expect(startedCount, 1);
    expect(cancelledCount, 0);

    controller.notifyHistoryPageCancelled();
    expect(startedCount, 1);
    expect(cancelledCount, 1);

    controller.removeHistoryPageCancelledListener(onCancelled);
    controller.notifyHistoryPageCancelled();
    expect(cancelledCount, 1);

    controller.dispose();
    controller.notifyHistoryPageStarted();
    expect(startedCount, 1);
  });
}
