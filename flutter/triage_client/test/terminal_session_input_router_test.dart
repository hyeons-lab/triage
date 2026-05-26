import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/widgets/terminal_pane.dart';

void main() {
  test(
    'late unbind from previous mount does not clear rebound session input',
    () {
      final router = TerminalSessionInputRouter();
      final session11 = TerminalController();
      final session7 = TerminalController();
      final inputs = <String>[];

      session11.addInputListener((data) => inputs.add('11:$data'));
      session7.addInputListener((data) => inputs.add('7:$data'));

      final firstSession11Mount = router.bind('session-11', session11);
      router.sendInput('session-11', 'first');

      final session7Mount = router.bind('session-7', session7);
      router.sendInput('session-7', 'second');

      router.bind('session-11', session11);
      router.unbind('session-11', firstSession11Mount);
      router.sendInput('session-11', 'third');

      router.unbind('session-7', session7Mount);
      router.sendInput('session-7', 'ignored');

      expect(inputs, ['11:first', '7:second', '11:third']);
    },
  );

  test('rebinding a session routes input to the replacement controller', () {
    final router = TerminalSessionInputRouter();
    final oldController = TerminalController();
    final newController = TerminalController();
    final inputs = <String>[];

    oldController.addInputListener((data) => inputs.add('old:$data'));
    newController.addInputListener((data) => inputs.add('new:$data'));

    final oldToken = router.bind('session-11', oldController);
    router.sendInput('session-11', 'before');

    final newToken = router.bind('session-11', newController);
    router.sendInput('session-11', 'after');

    router.unbind('session-11', oldToken);
    router.sendInput('session-11', 'still-new');

    router.unbind('session-11', newToken);
    router.sendInput('session-11', 'ignored');

    expect(inputs, ['old:before', 'new:after', 'new:still-new']);
  });
}
