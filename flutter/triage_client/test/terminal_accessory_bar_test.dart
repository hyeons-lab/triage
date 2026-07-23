import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/widgets/terminal_accessory_bar.dart';

void main() {
  // Pumps the bar and returns the list of byte sequences it emits through
  // onSend, plus a counter of onToggleCtrl taps.
  Future<({List<String> sent, int Function() ctrlToggles})> pumpBar(
    WidgetTester tester, {
    bool ctrlArmed = false,
  }) async {
    final sent = <String>[];
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TerminalAccessoryBar(
              onSend: sent.add,
              onToggleCtrl: () => toggles++,
              ctrlArmed: ctrlArmed,
            ),
          ),
        ),
      ),
    );
    return (sent: sent, ctrlToggles: () => toggles);
  }

  Future<void> tapKey(WidgetTester tester, String label) async {
    final finder = find.text(label);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pump();
  }

  testWidgets('each key emits its byte sequence through onSend', (
    tester,
  ) async {
    final bar = await pumpBar(tester);

    await tapKey(tester, 'esc');
    await tapKey(tester, 'tab');
    await tapKey(tester, '⇧tab');
    await tapKey(tester, 'enter');
    await tapKey(tester, '▲');
    await tapKey(tester, '▼');
    await tapKey(tester, '◀');
    await tapKey(tester, '▶');
    await tapKey(tester, '^C');
    await tapKey(tester, '/');
    await tapKey(tester, '|');
    await tapKey(tester, '-');
    await tapKey(tester, '~');

    expect(bar.sent, [
      '\x1b',
      '\t',
      '\x1b[Z',
      '\r',
      '\x1b[A',
      '\x1b[B',
      '\x1b[D',
      '\x1b[C',
      '\x03',
      '/',
      '|',
      '-',
      '~',
    ]);
  });

  testWidgets('ctrl reports through onToggleCtrl, not onSend', (tester) async {
    final bar = await pumpBar(tester);
    await tapKey(tester, 'ctrl');
    expect(bar.ctrlToggles(), 1);
    expect(bar.sent, isEmpty);
  });

  testWidgets('ctrl still toggles (never sends) even while already armed', (
    tester,
  ) async {
    final bar = await pumpBar(tester, ctrlArmed: true);
    await tapKey(tester, 'ctrl');
    expect(bar.ctrlToggles(), 1);
    expect(bar.sent, isEmpty);
  });

  Color ctrlKeyColor(WidgetTester tester) {
    final container = tester.widget<Container>(
      find
          .ancestor(of: find.text('ctrl'), matching: find.byType(Container))
          .first,
    );
    return (container.decoration as BoxDecoration).color!;
  }

  testWidgets('the ctrl key is highlighted only while armed', (tester) async {
    await pumpBar(tester, ctrlArmed: false);
    expect(ctrlKeyColor(tester), const Color(0xff232c2f));

    await pumpBar(tester, ctrlArmed: true);
    expect(ctrlKeyColor(tester), const Color(0xff2b6a63));
  });
}
