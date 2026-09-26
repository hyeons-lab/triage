import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/widgets/terminal_accessory_bar.dart';

void main() {
  // Pumps the bar and returns the list of byte sequences it emits through
  // onSend, plus counters of onToggleCtrl and onPaste taps.
  Future<
    ({List<String> sent, int Function() ctrlToggles, int Function() pastes})
  >
  pumpBar(WidgetTester tester, {bool ctrlArmed = false}) async {
    final sent = <String>[];
    var toggles = 0;
    var pastes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TerminalAccessoryBar(
              onSend: sent.add,
              onToggleCtrl: () => toggles++,
              onPaste: () => pastes++,
              ctrlArmed: ctrlArmed,
            ),
          ),
        ),
      ),
    );
    return (sent: sent, ctrlToggles: () => toggles, pastes: () => pastes);
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
    await tapKey(tester, '^K');
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
      '\x0b',
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

  testWidgets('paste reports through onPaste, not onSend', (tester) async {
    final bar = await pumpBar(tester);
    await tapKey(tester, 'paste');
    expect(bar.pastes(), 1);
    expect(bar.sent, isEmpty);
    expect(bar.ctrlToggles(), 0);
  });

  Future<int Function()> pumpKbdBar(
    WidgetTester tester, {
    bool keyboardEnabled = true,
    bool withHandler = true,
  }) async {
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TerminalAccessoryBar(
              onSend: (_) {},
              onToggleCtrl: () {},
              onPaste: () {},
              ctrlArmed: false,
              onToggleKeyboard: withHandler ? () => toggles++ : null,
              keyboardEnabled: keyboardEnabled,
            ),
          ),
        ),
      ),
    );
    return () => toggles;
  }

  Color kbdKeyColor(WidgetTester tester) {
    final container = tester.widget<Container>(
      find
          .ancestor(of: find.text('kbd'), matching: find.byType(Container))
          .first,
    );
    return (container.decoration as BoxDecoration).color!;
  }

  testWidgets('kbd reports through onToggleKeyboard, not onSend', (
    tester,
  ) async {
    final sent = <String>[];
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalAccessoryBar(
            onSend: sent.add,
            onToggleCtrl: () {},
            onPaste: () {},
            ctrlArmed: false,
            onToggleKeyboard: () => toggles++,
          ),
        ),
      ),
    );
    await tapKey(tester, 'kbd');
    expect(toggles, 1);
    expect(sent, isEmpty);
  });

  testWidgets('kbd hides without a handler', (tester) async {
    await pumpKbdBar(tester, withHandler: false);
    expect(find.text('kbd'), findsNothing);
    // The input keys are unaffected.
    expect(find.text('esc'), findsOneWidget);
  });

  testWidgets('the kbd key is highlighted only while suppressed', (
    tester,
  ) async {
    await pumpKbdBar(tester, keyboardEnabled: true);
    expect(kbdKeyColor(tester), const Color(0xff232c2f));

    await pumpKbdBar(tester, keyboardEnabled: false);
    expect(kbdKeyColor(tester), const Color(0xff2b6a63));
  });
}
