import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/widgets/terminal_pane.dart';
import 'package:xterm/xterm.dart' hide TerminalController;

void main() {
  group('TerminalPane hardware Tab and Shift+Tab key handling', () {
    for (final platform in TargetPlatform.values) {
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

    testWidgets('ignores Ctrl+Tab, Alt+Tab, and Cmd/Meta+Tab chords', (
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
              body: TerminalPane(
                terminalId: 'test-session',
                terminal: terminal,
                controller: controller,
                fallbackRows: const [],
                onTerminalResizeBind: (_) {},
                focusCursorRevision: 0,
                bracketedPasteEnabled: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Ctrl+Tab
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        // Alt+Tab
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();

        // Meta+Tab
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();

        // Ctrl+Shift+Tab
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(inputs, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('notifies interaction when Tab and Shift+Tab are pressed', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final terminal = Terminal();
        final controller = TerminalController();
        var interactions = 0;
        controller.addInteractionListener(() {
          interactions++;
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalPane(
                terminalId: 'test-session',
                terminal: terminal,
                controller: controller,
                fallbackRows: const [],
                onTerminalResizeBind: (_) {},
                focusCursorRevision: 0,
                bracketedPasteEnabled: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(interactions, 1);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(interactions, 2);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('ignores Tab when session is exited', (tester) async {
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
                      isExited: true,
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

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();

        expect(inputs, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('ignores Tab when a modal route is active', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final terminal = Terminal();
        final controller = TerminalController();
        final inputs = <String>[];
        controller.addInputListener((data) {
          inputs.add(data);
        });
        late BuildContext savedContext;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  savedContext = context;
                  return TerminalPane(
                    terminalId: 'test-session',
                    terminal: terminal,
                    controller: controller,
                    fallbackRows: const [],
                    onTerminalResizeBind: (_) {},
                    focusCursorRevision: 0,
                    bracketedPasteEnabled: false,
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Push a modal dialog over the terminal
        showDialog<void>(
          context: savedContext,
          builder: (context) => const AlertDialog(
            title: Text('Modal Dialog'),
            content: Text('Dialog Content'),
          ),
        );
        await tester.pumpAndSettle();

        // Press Tab while dialog is active
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();

        // ModalRoute is not current for the terminal, so Tab is ignored
        expect(inputs, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('TerminalPane Shift+Enter newline', () {
    Future<List<String>> pumpPane(
      WidgetTester tester, {
      VoidCallback? onInteraction,
    }) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final inputs = <String>[];
      controller.addInputListener((data) {
        inputs.add(data);
      });
      if (onInteraction != null) {
        controller.addInteractionListener(onInteraction);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalPane(
              terminalId: 'test-session',
              terminal: terminal,
              controller: controller,
              fallbackRows: const [],
              onTerminalResizeBind: (_) {},
              focusCursorRevision: 0,
              bracketedPasteEnabled: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return inputs;
    }

    testWidgets('Shift+Enter sends LF instead of submitting', (tester) async {
      var interactions = 0;
      final inputs = await pumpPane(
        tester,
        onInteraction: () => interactions++,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(inputs, ['\n', '\n']);
      expect(interactions, 2);
    });

    testWidgets('Shift+numpadEnter sends LF', (tester) async {
      final inputs = await pumpPane(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(inputs, ['\n']);
    });

    testWidgets('plain Enter is left to the emulator default', (tester) async {
      final inputs = await pumpPane(tester);

      // Our layer sends nothing: xterm's own handler owns plain Enter (CR)
      // in production. (The fallback view mounts no TerminalView, so there
      // is no emulator echo to observe here.)
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(inputs, isEmpty);
    });

    for (final (label, modifier) in [
      ('Ctrl', LogicalKeyboardKey.controlLeft),
      ('Alt', LogicalKeyboardKey.altLeft),
      ('Meta', LogicalKeyboardKey.metaLeft),
    ]) {
      testWidgets('$label+Shift+Enter is left to the default path', (
        tester,
      ) async {
        final inputs = await pumpPane(tester);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(modifier);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();

        expect(inputs, isEmpty);
      });
    }
  });

  group('TerminalPane exited, obscured, and modal-route input guards', () {
    testWidgets(
      'ignores user terminal output and key events when isExited or isObscured while passing emulator query responses',
      (tester) async {
        final terminal = Terminal();
        final controller = TerminalController();
        final inputs = <String>[];
        controller.addInputListener(inputs.add);

        Widget buildHost({required bool isExited, required bool isObscured}) {
          return MaterialApp(
            home: Scaffold(
              body: TerminalPane(
                terminalId: 'guard-session',
                terminal: terminal,
                controller: controller,
                fallbackRows: const [],
                onTerminalResizeBind: (_) {},
                focusCursorRevision: 0,
                bracketedPasteEnabled: false,
                isExited: isExited,
                isObscured: isObscured,
              ),
            ),
          );
        }

        // 1. Exited session drops user typing and Shift+Enter/Tab, but allows emulator query responses.
        await tester.pumpWidget(buildHost(isExited: true, isObscured: false));
        await tester.pumpAndSettle();

        terminal.onOutput?.call('ls\n');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(inputs, isEmpty);

        terminal.onOutput?.call('\x1b[1;1R');
        expect(inputs, ['\x1b[1;1R']);
        inputs.clear();

        // 2. Obscured session drops user typing and hardware keys.
        await tester.pumpWidget(buildHost(isExited: false, isObscured: true));
        await tester.pumpAndSettle();

        terminal.onOutput?.call('pwd\n');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(inputs, isEmpty);

        // 3. Unobscured live session accepts input again.
        await tester.pumpWidget(buildHost(isExited: false, isObscured: false));
        await tester.pumpAndSettle();

        terminal.onOutput?.call('ok');
        expect(inputs, ['ok']);
      },
    );
  });

  group('TerminalPane select-all and history-page selection preservation', () {
    String? copiedText;

    setUp(() {
      copiedText = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<dynamic, dynamic>;
              copiedText = args['text'] as String?;
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets(
      'Cmd+A selects all buffer lines on macOS and Cmd+C copies them',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          final terminal = Terminal(maxLines: 100);
          terminal.resize(20, 2);
          terminal.write('first line\r\nsecond line');
          final controller = TerminalController();
          final inputs = <String>[];
          controller.addInputListener(inputs.add);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TerminalPane(
                  terminalId: 'test-select-all-macos',
                  terminal: terminal,
                  controller: controller,
                  fallbackRows: const [],
                  onTerminalResizeBind: (_) {},
                  focusCursorRevision: 0,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();

          expect(inputs, isEmpty);
          expect(copiedText, 'first line\nsecond line');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'Ctrl+Shift+A selects all buffer lines on Linux while plain Ctrl+A does not select',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          final terminal = Terminal(maxLines: 100);
          terminal.resize(20, 2);
          terminal.write('alpha\r\nbeta');
          final controller = TerminalController();

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TerminalPane(
                  terminalId: 'test-select-all-linux',
                  terminal: terminal,
                  controller: controller,
                  fallbackRows: const [],
                  onTerminalResizeBind: (_) {},
                  focusCursorRevision: 0,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Plain Ctrl+A must not trigger select-all, so a subsequent
          // Ctrl+Shift+C has nothing to copy.
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(copiedText, isNull);

          // Ctrl+Shift+A selects all and Ctrl+Shift+C copies it.
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(copiedText, 'alpha\nbeta');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'prepending a scrollback history page shifts the active selection down by addedLines',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          final terminal = Terminal(maxLines: 100);
          terminal.resize(20, 2);
          terminal.write('target 1\r\ntarget 2');
          final controller = TerminalController();

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TerminalPane(
                  terminalId: 'test-history-page-selection',
                  terminal: terminal,
                  controller: controller,
                  fallbackRows: const [],
                  onTerminalResizeBind: (_) {},
                  focusCursorRevision: 0,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Select the current 2-line buffer ('target 1\ntarget 2').
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();

          // Simulate a scrollback page prepending 2 older lines ahead of the
          // originally selected lines.
          controller.notifyHistoryPageStarted();
          terminal.buffer.clear();
          terminal.buffer.setCursor(0, 0);
          terminal.write('older 1\r\nolder 2\r\ntarget 1\r\ntarget 2');
          controller.notifyHistoryReplayed();
          await tester.pump();

          // Copying the selection after replay must copy the shifted original
          // lines ('target 1\ntarget 2'), not the newly prepended top lines.
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();

          expect(copiedText, 'target 1\ntarget 2');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
