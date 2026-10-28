import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/widgets/terminal_pane.dart';
import 'package:xterm/xterm.dart' hide TerminalController, TerminalStyle;

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

        // Right-hand Ctrl+Tab, Alt+Tab, and Meta+Tab
        for (final modifier in [
          LogicalKeyboardKey.controlRight,
          LogicalKeyboardKey.altRight,
          LogicalKeyboardKey.metaRight,
        ]) {
          await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyUpEvent(modifier);
          await tester.pump();
        }

        expect(inputs, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Tab resets scrolled-up viewport back to bottom', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final terminal = Terminal(maxLines: 100);
        terminal.resize(40, 4);
        for (var i = 0; i < 30; i++) {
          terminal.write('line $i\r\n');
        }
        final controller = TerminalController();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 120,
                child: TerminalPane(
                  terminalId: 'test-tab-scroll-reset',
                  terminal: terminal,
                  controller: controller,
                  fallbackRows: const [],
                  onTerminalResizeBind: (_) {},
                  focusCursorRevision: 0,
                  bracketedPasteEnabled: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(Scrollable),
          ),
        );
        scrollable.position.jumpTo(120);
        await tester.pump();
        expect(scrollable.position.pixels, 120);

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(scrollable.position.pixels, 0);
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

  group('TerminalPane alt-screen trackpad and mouse wheel scrolling', () {
    testWidgets(
      'trackpad pan/zoom and mouse wheel emit SGR wheel reports in alt-screen',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          final terminal = Terminal();
          terminal.write('\x1b[?1049h\x1b[?1000h\x1b[?1006h');
          final controller = TerminalController();
          final inputs = <String>[];
          controller.addInputListener(inputs.add);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TerminalPane(
                  terminalId: 'test-alt-scroll',
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

          final center = tester.getCenter(find.byType(TerminalPane));
          final trackpad = TestPointer(1, PointerDeviceKind.trackpad);
          await tester.sendEventToBinding(trackpad.panZoomStart(center));
          // Positive panDelta.dy (two-finger swipe down with natural scrolling)
          // scrolls UP toward older content (wheelUp = button 64).
          await tester.sendEventToBinding(
            trackpad.panZoomUpdate(center, pan: const Offset(0, 24)),
          );
          await tester.sendEventToBinding(trackpad.panZoomEnd());
          await tester.pump();

          expect(inputs, contains(startsWith('\x1b[<64;')));
          inputs.clear();

          // Mouse wheel scroll down (positive scrollDelta.dy) emits wheelDown (65).
          final mouse = TestPointer(2, PointerDeviceKind.mouse);
          await tester.sendEventToBinding(mouse.hover(center));
          await tester.sendEventToBinding(mouse.scroll(const Offset(0, 24)));
          await tester.pump();

          expect(inputs, contains(startsWith('\x1b[<65;')));
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'placeholder-to-loaded session swap with rebindSessionController stays pinned to bottom',
      (tester) async {
        final placeholderTerminal = Terminal();
        final placeholderController = TerminalController();
        const terminalId = 'triage / session-swap-scroll';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 400,
                child: TerminalPane(
                  terminalId: terminalId,
                  terminal: placeholderTerminal,
                  controller: placeholderController,
                  fallbackRows: const [],
                  onTerminalResizeBind: (_) {},
                  focusCursorRevision: 1,
                  bracketedPasteEnabled: false,
                  isLoading: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final loadedTerminal = Terminal();
        final loadedController = TerminalController();
        final loadedRows = <StyledRow>[
          for (var i = 0; i < 120; i++)
            StyledRow(
              spans: [
                StyledSpan(text: 'Line $i', style: const TerminalStyle()),
              ],
            ),
        ];
        // Simulate _loadDaemonSessionInto: rebind controller and replay history
        // before the widget rebuilds with the loaded terminal.
        TerminalPane.rebindSessionController(terminalId, loadedController);
        loadedController.clear();
        for (var i = 0; i < 120; i++) {
          loadedTerminal.write('Line $i\r\n');
        }
        loadedController.notifyHistoryReplayed();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 400,
                child: TerminalPane(
                  terminalId: terminalId,
                  terminal: loadedTerminal,
                  controller: loadedController,
                  fallbackRows: loadedRows,
                  onTerminalResizeBind: (_) {},
                  focusCursorRevision: 1,
                  bracketedPasteEnabled: false,
                  isLoading: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final scrollPosition = tester
            .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
            .controller!
            .position;
        expect(scrollPosition.maxScrollExtent, greaterThan(0));
        expect(
          scrollPosition.pixels,
          closeTo(scrollPosition.maxScrollExtent, 1.0),
        );

        // Trigger refit(), then immediately scroll up and emit in-place
        // spinner output; the viewport must stay at the user's scrolled
        // offset instead of snapping back.
        loadedController.refit();
        await tester.pump();
        scrollPosition.jumpTo(300.0);
        await tester.pump();
        for (var i = 0; i < 10; i++) {
          loadedTerminal.write('\x1b[10;3H* spinner $i');
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(scrollPosition.pixels, closeTo(300.0, 1.0));
      },
    );
  });

  group('TerminalPane exited, obscured, and modal-route input guards', () {
    testWidgets(
      'ignores user terminal output, key events, and emulator query responses when isExited or isObscured',
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

        // 1. Exited session drops user typing, Shift+Enter/Tab, and emulator query responses.
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
        expect(inputs, isEmpty);

        // 2. Obscured session drops user typing and hardware keys.
        await tester.pumpWidget(buildHost(isExited: false, isObscured: true));
        await tester.pumpAndSettle();

        terminal.onOutput?.call('pwd\n');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(inputs, isEmpty);

        // 3. Unobscured live session accepts user input while still dropping emulator query responses.
        await tester.pumpWidget(buildHost(isExited: false, isObscured: false));
        await tester.pumpAndSettle();

        terminal.onOutput?.call('\x1b[1;1R');
        expect(inputs, isEmpty);
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

    testWidgets(
      'mobile touch drag on alternate-screen mouse-tracking terminal emits unshifted SGR wheel 64/65',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final terminal = Terminal(maxLines: 100);
          terminal.resize(47, 41);
          terminal.write(
            '\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h',
          );
          final sentInputs = <String>[];
          final controller = TerminalController();
          controller.addInputListener(sentInputs.add);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 470,
                  height: 820,
                  child: TerminalPane(
                    terminalId: 'test-android-alt-scroll',
                    terminal: terminal,
                    controller: controller,
                    fallbackRows: const [],
                    onTerminalResizeBind: (_) {},
                    focusCursorRevision: 0,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Drag finger downward (scrolling up into older history) -> wheelUp (64).
          final gesture = await tester.startGesture(const Offset(200, 300));
          await gesture.moveBy(const Offset(0, 60));
          await gesture.up();
          await tester.pump();

          expect(
            sentInputs.any((s) => s.startsWith('\x1b[<64;')),
            isTrue,
            reason: 'Expected SGR wheelUp (64), got: $sentInputs',
          );

          sentInputs.clear();
          // Drag finger upward (scrolling down toward newer output) -> wheelDown (65).
          final gestureDown = await tester.startGesture(const Offset(200, 300));
          await gestureDown.moveBy(const Offset(0, -60));
          await gestureDown.up();
          await tester.pump();

          expect(
            sentInputs.any((s) => s.startsWith('\x1b[<65;')),
            isTrue,
            reason: 'Expected SGR wheelDown (65), got: $sentInputs',
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'native TerminalView stays pinned to bottom across loading, history replay, session swaps, and live output without phantom onNearTop paging',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        TerminalPane.debugForceNativeTerminalView = true;
        try {
          var nearTopCount = 0;
          final termA = Terminal(maxLines: 500);
          final ctrlA = TerminalController();
          final termB = Terminal(maxLines: 500);
          final ctrlB = TerminalController();

          Widget buildPane({
            required String id,
            required Terminal terminal,
            required TerminalController controller,
            required bool isLoading,
            required int focusRev,
          }) {
            return MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 400,
                  height: 300,
                  child: TerminalPane(
                    terminalId: id,
                    terminal: terminal,
                    controller: controller,
                    fallbackRows: const [],
                    onTerminalResizeBind: (_) {},
                    focusCursorRevision: focusRev,
                    isLoading: isLoading,
                    onNearTop: () {
                      nearTopCount++;
                      return false;
                    },
                  ),
                ),
              ),
            );
          }

          // 1. Mount session A while loading with an empty buffer (maxScrollExtent == 0).
          await tester.pumpWidget(
            buildPane(
              id: 'native-scroll-a',
              terminal: termA,
              controller: ctrlA,
              isLoading: true,
              focusRev: 1,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));

          // Replay 120 lines of history into session A and finish loading.
          for (var i = 0; i < 120; i++) {
            termA.write('session A line $i\r\n');
          }
          ctrlA.notifyHistoryReplayed();
          await tester.pumpWidget(
            buildPane(
              id: 'native-scroll-a',
              terminal: termA,
              controller: ctrlA,
              isLoading: false,
              focusRev: 1,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          final scrollableFinder = find.descendant(
            of: find.byType(TerminalView),
            matching: find.byType(Scrollable),
          );
          ScrollPosition pos() =>
              tester.state<ScrollableState>(scrollableFinder).position;

          expect(pos().maxScrollExtent, greaterThan(0));
          expect(pos().pixels, closeTo(pos().maxScrollExtent, 1.0));
          expect(nearTopCount, 0);

          // 2. Scroll session A up to the middle so RenderTerminal._stickToBottom
          // becomes false and session A records a saved scroll offset.
          final midA = pos().maxScrollExtent * 0.4;
          pos().jumpTo(midA);
          await tester.pump();
          expect(pos().pixels, closeTo(midA, 1.0));
          expect(nearTopCount, 0);

          // 3. Switch to session B while it is loading and still has an empty
          // buffer (maxScrollExtent shrinks from session A's extent to 0),
          // then replay 80 lines of history and stream live output.
          await tester.pumpWidget(
            buildPane(
              id: 'native-scroll-b',
              terminal: termB,
              controller: ctrlB,
              isLoading: true,
              focusRev: 2,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 30));
          expect(nearTopCount, 0);

          for (var i = 0; i < 80; i++) {
            termB.write('session B line $i\r\n');
          }
          ctrlB.notifyHistoryReplayed();
          await tester.pumpWidget(
            buildPane(
              id: 'native-scroll-b',
              terminal: termB,
              controller: ctrlB,
              isLoading: false,
              focusRev: 2,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          final extentBBeforeLive = pos().maxScrollExtent;
          expect(extentBBeforeLive, greaterThan(0));
          expect(pos().pixels, closeTo(extentBBeforeLive, 1.0));
          expect(nearTopCount, 0);

          // 4. Write additional live output to session B and verify that
          // RenderTerminal._stickToBottom is true and advances pixels to the
          // new bottom extent.
          for (var i = 80; i < 110; i++) {
            termB.write('session B live $i\r\n');
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));

          expect(pos().maxScrollExtent, greaterThan(extentBBeforeLive));
          expect(pos().pixels, closeTo(pos().maxScrollExtent, 1.0));
          expect(nearTopCount, 0);

          // 5. Switch back to session A and verify its scrolled-up offset is
          // restored on the very first frame (no 1-frame snap to bottom) and
          // stays pinned across live output without triggering onNearTop.
          await tester.pumpWidget(
            buildPane(
              id: 'native-scroll-a',
              terminal: termA,
              controller: ctrlA,
              isLoading: false,
              focusRev: 3,
            ),
          );
          await tester.pump();
          expect(pos().pixels, closeTo(midA, 1.0));
          await tester.pump(const Duration(milliseconds: 60));
          expect(pos().pixels, closeTo(midA, 1.0));
          for (var i = 0; i < 5; i++) {
            termA.write('session A live while scrolled up $i\r\n');
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(pos().pixels, closeTo(midA, 1.0));
          expect(nearTopCount, 0);

          // 6. Explicitly scroll session A to top (0.0); onNearTop fires once,
          // and a large backward history page (where addedLines * lh exceeds
          // the previous maxScrollExtent) re-seats the viewport on the same
          // content without flipping RenderTerminal._stickToBottom to true or
          // re-triggering onNearTop.
          pos().jumpTo(0.0);
          await tester.pump();
          expect(nearTopCount, 1);

          ctrlA.notifyHistoryPageStarted();
          ctrlA.clear();
          termA.useMainBuffer();
          termA.mainBuffer.clear();
          termA.altBuffer.clear();
          termA.write('\x1b[H\x1b[2J\x1b[3J');
          for (var i = 0; i < 280; i++) {
            termA.write('session A paged line $i\r\n');
          }
          ctrlA.notifyHistoryReplayed();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));

          final pagedPixels = pos().pixels;
          expect(pagedPixels, greaterThan(0.0));
          expect(pagedPixels, lessThan(pos().maxScrollExtent - 100.0));
          expect(nearTopCount, 1);

          // Live output after paging must keep the viewport pinned at
          // pagedPixels rather than snapping to bottom.
          for (var i = 0; i < 5; i++) {
            termA.write('session A live after page $i\r\n');
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(pos().pixels, closeTo(pagedPixels, 1.0));
          expect(nearTopCount, 1);
        } finally {
          TerminalPane.debugForceNativeTerminalView = false;
          TerminalPane.destroySession('native-scroll-a');
          TerminalPane.destroySession('native-scroll-b');
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
