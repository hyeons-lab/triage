import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/widgets/terminal_pane.dart';
import 'package:xterm/xterm.dart' hide TerminalController;

void main() {
  group('TerminalPane hardware Tab and Shift+Tab key handling', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      testWidgets('receives Shift+Tab and Tab on $platform', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final terminal = Terminal();
          final controller = TerminalController();
          final inputs = <String>[];
          controller.addInputListener((data) {
            inputs.add(data);
          });

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Column(
                  children: [
                    ElevatedButton(
                      onPressed: () {},
                      child: const Text('Top Button'),
                    ),
                    Expanded(
                      child: TerminalPane(
                        terminalId: 'test-session',
                        terminal: terminal,
                        controller: controller,
                        fallbackRows: const [],
                        onTerminalResizeBind: (_) {},
                        focusCursorRevision: 0,
                        bracketedPasteEnabled: false,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () {},
                      child: const Text('Bottom Button'),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Shift+Tab sends back-tab escape sequence (\x1b[Z)
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pump();

          // Plain Tab sends literal tab character (\t)
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();

          expect(inputs, ['\x1b[Z', '\t']);

          // Focus remains on the terminal and is not stolen by focus traversal
          final terminalFocus = Focus.of(
            tester.element(find.byType(SingleChildScrollView)),
          );
          expect(terminalFocus.hasFocus, isTrue);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('handles Shift+Tab key repeat without losing focus', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final terminal = Terminal();
        final controller = TerminalController();
        final inputs = <String>[];
        controller.addInputListener((data) {
          inputs.add(data);
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  ElevatedButton(
                    onPressed: () {},
                    child: const Text('Top Button'),
                  ),
                  Expanded(
                    child: TerminalPane(
                      terminalId: 'test-session',
                      terminal: terminal,
                      controller: controller,
                      fallbackRows: const [],
                      onTerminalResizeBind: (_) {},
                      focusCursorRevision: 0,
                      bracketedPasteEnabled: false,
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {},
                    child: const Text('Bottom Button'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Hold shift down
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        // Initial tab down
        await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
        // Repeated tab event
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
        // Tab up
        await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
        // Shift up
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();

        expect(inputs, ['\x1b[Z', '\x1b[Z']);

        final terminalFocus = Focus.of(
          tester.element(find.byType(SingleChildScrollView)),
        );
        expect(terminalFocus.hasFocus, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('handles plain Tab key repeat without losing focus', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final terminal = Terminal();
        final controller = TerminalController();
        final inputs = <String>[];
        controller.addInputListener((data) {
          inputs.add(data);
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  ElevatedButton(
                    onPressed: () {},
                    child: const Text('Top Button'),
                  ),
                  Expanded(
                    child: TerminalPane(
                      terminalId: 'test-session',
                      terminal: terminal,
                      controller: controller,
                      fallbackRows: const [],
                      onTerminalResizeBind: (_) {},
                      focusCursorRevision: 0,
                      bracketedPasteEnabled: false,
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {},
                    child: const Text('Bottom Button'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initial tab down
        await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
        // Repeated tab event
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
        // Tab up
        await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
        await tester.pump();

        expect(inputs, ['\t', '\t']);

        final terminalFocus = Focus.of(
          tester.element(find.byType(SingleChildScrollView)),
        );
        expect(terminalFocus.hasFocus, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

