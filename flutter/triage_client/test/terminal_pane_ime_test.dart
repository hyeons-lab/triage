import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/widgets/terminal_pane.dart';

void main() {
  const androidVariant = TargetPlatformVariant({TargetPlatform.android});

  Future<(TerminalController, TerminalCellBuffer, List<String>)>
  pumpAndroidTerminalPane(WidgetTester tester) async {
    final controller = TerminalController();
    final terminal = TerminalCellBuffer(cols: 80, rows: 24);
    final sent = <String>[];
    void captureInput(String data) => sent.add(data);
    controller.addInputListener(captureInput);

    addTearDown(() {
      controller.removeInputListener(captureInput);
      controller.dispose();
      terminal.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalPane(
            terminalId: 'ime-test-session',
            controller: controller,
            terminal: terminal,
            fallbackRows: const [],
            onTerminalResizeBind: (_) {},
            focusCursorRevision: 0,
          ),
        ),
      ),
    );
    await tester.pump();
    return (controller, terminal, sent);
  }

  testWidgets(
    'Android IME configuration enables suggestions for swipe typing',
    variant: androidVariant,
    (WidgetTester tester) async {
      await pumpAndroidTerminalPane(tester);

      expect(tester.testTextInput.hasAnyClients, isTrue);
      final setClientArgs = tester.testTextInput.setClientArgs;
      expect(setClientArgs, isNotNull);
      expect(setClientArgs!['enableSuggestions'], isTrue);
      expect(setClientArgs['autocorrect'], isFalse);
      expect(setClientArgs['smartDashesType'], '0');
      expect(setClientArgs['smartQuotesType'], '0');
      final inputType = setClientArgs['inputType'] as Map<Object?, Object?>?;
      expect(inputType?['name'], 'TextInputType.text');
    },
  );

  testWidgets(
    'consecutive swiped words auto-space and commit cleanly',
    variant: androidVariant,
    (WidgetTester tester) async {
      final (_, _, sent) = await pumpAndroidTerminalPane(tester);

      // Swipe word 1 ("hello"), then refine suggestion to ("jello") before commit.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  hello',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 2, end: 7),
        ),
      );
      expect(sent, isEmpty);

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  jello',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 2, end: 7),
        ),
      );
      expect(sent, isEmpty);

      // Finish composing word 1 without trailing space, then swipe word 2.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  jello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      expect(sent, ['jello']);

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  world',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 2, end: 7),
        ),
      );
      expect(sent, ['jello']);

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  world',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      expect(sent, ['jello', ' world']);
    },
  );

  testWidgets(
    'batched swipe flushes committed prefix before active composing and completes on newline',
    variant: androidVariant,
    (WidgetTester tester) async {
      final (_, _, sent) = await pumpAndroidTerminalPane(tester);

      // Swipe word 1 ("hello").
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  hello',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 2, end: 7),
        ),
      );
      expect(sent, isEmpty);

      // Immediately swipe word 2 ("world") in a single batch where "hello "
      // is committed ahead of the new composing span.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  hello world',
          selection: TextSelection.collapsed(offset: 13),
          composing: TextRange(start: 8, end: 13),
        ),
      );
      expect(sent, ['hello ']);

      // Tapping Enter flushes only the remaining composing word plus '\r'.
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      expect(sent, ['hello ', 'world', '\r']);
    },
  );

  testWidgets(
    'backspace deletes from sentinel and across committed prefix',
    variant: androidVariant,
    (WidgetTester tester) async {
      final (_, _, sent) = await pumpAndroidTerminalPane(tester);

      // Soft backspace from the idle '  ' sentinel.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: ' ',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      expect(sent, ['\x7f']);
      sent.clear();

      // Backspacing out of a composing word after a flushed prefix deletes only
      // the previously emitted prefix characters without duplicating them.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  hello world',
          selection: TextSelection.collapsed(offset: 13),
          composing: TextRange(start: 8, end: 13),
        ),
      );
      expect(sent, ['hello ']);
      sent.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  hello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      expect(sent, ['\x7f']);
    },
  );
}
