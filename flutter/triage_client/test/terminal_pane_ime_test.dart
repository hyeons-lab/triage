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
    'line-buffered swipe keeps prior words in IME without sentinel resets until enter',
    variant: androidVariant,
    (WidgetTester tester) async {
      final (_, _, sent) = await pumpAndroidTerminalPane(tester);
      tester.testTextInput.log.clear();

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

      // Commit word 1 without wiping the platform buffer back to the sentinel.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  jello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      expect(sent, ['jello']);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.setEditingState',
        ),
        isEmpty,
      );

      // Swipe word 2 with word 1 still buffered in the InputConnection; only the
      // space prefix is emitted while word 2 composes, then "world" on commit.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  jello world',
          selection: TextSelection.collapsed(offset: 13),
          composing: TextRange(start: 8, end: 13),
        ),
      );
      expect(sent, ['jello', ' ']);

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  jello world',
          selection: TextSelection.collapsed(offset: 13),
        ),
      );
      expect(sent, ['jello', ' ', 'world']);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.setEditingState',
        ),
        isEmpty,
      );

      // Pressing Enter flushes cleanly and resets the platform buffer to sentinel.
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      expect(sent, ['jello', ' ', 'world', '\r']);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.setEditingState',
        ),
        isNotEmpty,
      );
    },
  );

  testWidgets(
    'post-commit autocorrect and inline newline commit boundaries emit minimal diffs',
    variant: androidVariant,
    (WidgetTester tester) async {
      final (_, _, sent) = await pumpAndroidTerminalPane(tester);

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  echo helo',
          selection: TextSelection.collapsed(offset: 11),
        ),
      );
      expect(sent, ['echo helo']);
      sent.clear();

      // Tapping an autocorrect chip replaces only the divergent suffix.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  echo hello',
          selection: TextSelection.collapsed(offset: 12),
        ),
      );
      expect(sent, ['\x7f', 'lo']);
      sent.clear();

      // Inline newline via text update submits and resets back to sentinel.
      tester.testTextInput.log.clear();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  echo hello\n',
          selection: TextSelection.collapsed(offset: 13),
        ),
      );
      expect(sent, ['\r']);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.setEditingState',
        ),
        isNotEmpty,
      );
    },
  );

  testWidgets(
    'backspace deletes across buffered words, into sentinel, and across composing prefix',
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

      // Commit two words into the line buffer, then backspace across the space.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  hello world',
          selection: TextSelection.collapsed(offset: 13),
        ),
      );
      expect(sent, ['hello world']);
      sent.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  hello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      expect(sent, List<String>.filled(6, '\x7f'));
      sent.clear();

      // Backspace back into the sentinel emits the remaining line deletions.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: ' ',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      expect(sent, List<String>.filled(6, '\x7f'));
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

  testWidgets(
    'accessory key flushes composing word and resets buffered line boundary',
    variant: androidVariant,
    (WidgetTester tester) async {
      final previousForceNative = TerminalPane.debugForceNativeTerminalView;
      TerminalPane.debugForceNativeTerminalView = true;
      addTearDown(() {
        TerminalPane.debugForceNativeTerminalView = previousForceNative;
      });
      final (_, _, sent) = await pumpAndroidTerminalPane(tester);

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  git st',
          selection: TextSelection.collapsed(offset: 8),
          composing: TextRange(start: 6, end: 8),
        ),
      );
      expect(sent, ['git ']);
      sent.clear();

      // Tapping tab accessory flushes active composing word and sends Tab.
      await tester.tap(find.text('tab'));
      await tester.pump();
      expect(sent, ['st', '\t']);

      // Subsequent typing starts fresh without emitting duplicate prefix bytes.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  atus',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      expect(sent, ['st', '\t', 'atus']);
    },
  );

  testWidgets(
    'focus loss flushes active composing word and resets line buffer',
    variant: androidVariant,
    (WidgetTester tester) async {
      final (_, _, sent) = await pumpAndroidTerminalPane(tester);

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  echo bye',
          selection: TextSelection.collapsed(offset: 10),
          composing: TextRange(start: 7, end: 10),
        ),
      );
      expect(sent, ['echo ']);
      sent.clear();

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(sent, ['bye']);
    },
  );
}
