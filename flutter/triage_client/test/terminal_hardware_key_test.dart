import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_mouse_encoder.dart';
import 'package:triage_client/widgets/terminal_grid_render_box.dart';
import 'package:triage_client/widgets/terminal_pane.dart';

TerminalCellLine _cellLine(String text, {int cols = 80}) {
  return TerminalCellLine.fromSpec(
    <String?>[for (final r in text.runes) String.fromCharCode(r)],
    width: cols,
  );
}

void _seedBufferLines(
  TerminalCellBuffer terminal,
  List<String> lines, {
  int? cols,
  int? rows,
}) {
  final targetCols = cols ?? terminal.viewWidth;
  final targetRows = rows ?? terminal.viewHeight;
  final cellLines = <TerminalCellLine>[
    for (final text in lines) _cellLine(text, cols: targetCols),
  ];
  final sbCount = cellLines.length > targetRows
      ? cellLines.length - targetRows
      : 0;
  terminal.seedLinesForTest(
    cols: targetCols,
    rows: targetRows,
    scrollback: sbCount > 0
        ? cellLines.sublist(0, sbCount)
        : const <TerminalCellLine>[],
    viewport: cellLines.sublist(sbCount),
  );
}

void main() {
  group('TerminalPane hardware Tab and Shift+Tab key handling', () {
    for (final platform in TargetPlatform.values) {
      testWidgets('receives Shift+Tab and Tab on $platform', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final terminal = TerminalCellBuffer();
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

          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pump();

          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();

          expect(inputs, ['\x1b[Z', '\t']);

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
        final terminal = TerminalCellBuffer();
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

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
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
        final terminal = TerminalCellBuffer();
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

        await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
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
        final terminal = TerminalCellBuffer();
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

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

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
        final terminal = TerminalCellBuffer(cols: 40, rows: 4);
        _seedBufferLines(
          terminal,
          <String>[for (var i = 0; i < 30; i++) 'line $i'],
          cols: 40,
          rows: 4,
        );
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
        final terminal = TerminalCellBuffer();
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
        final terminal = TerminalCellBuffer();
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
        final terminal = TerminalCellBuffer();
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

        showDialog<void>(
          context: savedContext,
          builder: (context) => const AlertDialog(
            title: Text('Modal Dialog'),
            content: Text('Dialog Content'),
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
  });

  group('TerminalPane Shift+Enter newline', () {
    Future<List<String>> pumpPane(
      WidgetTester tester, {
      VoidCallback? onInteraction,
    }) async {
      final terminal = TerminalCellBuffer();
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

    testWidgets('plain Enter is ignored on the outer fallback key handler', (
      tester,
    ) async {
      final inputs = await pumpPane(tester);

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
          final terminal = TerminalCellBuffer();
          terminal.setModesForTest(
            altScreen: true,
            mouseMode: kMouseModeNormal,
            mouseReportMode: kMouseReportSgr,
          );
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
          await tester.sendEventToBinding(
            trackpad.panZoomUpdate(center, pan: const Offset(0, 24)),
          );
          await tester.sendEventToBinding(trackpad.panZoomEnd());
          await tester.pump();

          expect(inputs, contains(startsWith('\x1b[<64;')));
          inputs.clear();

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
        final placeholderTerminal = TerminalCellBuffer();
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

        final loadedTerminal = TerminalCellBuffer();
        final loadedController = TerminalController();
        final loadedRows = <StyledRow>[
          for (var i = 0; i < 120; i++)
            StyledRow(
              spans: [
                StyledSpan(text: 'Line $i', style: const TerminalStyle()),
              ],
            ),
        ];
        TerminalPane.rebindSessionController(terminalId, loadedController);
        loadedController.clear();
        _seedBufferLines(
          loadedTerminal,
          <String>[for (var i = 0; i < 120; i++) 'Line $i'],
        );
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

        loadedController.refit();
        await tester.pump();
        scrollPosition.jumpTo(300.0);
        await tester.pump();
        for (var i = 0; i < 10; i++) {
          loadedTerminal.setViewportLineForTest(
            9,
            _cellLine('  * spinner $i', cols: loadedTerminal.viewWidth),
          );
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
        final terminal = TerminalCellBuffer();
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

        await tester.pumpWidget(buildHost(isExited: false, isObscured: true));
        await tester.pumpAndSettle();

        terminal.onOutput?.call('pwd\n');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(inputs, isEmpty);

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
          final terminal = TerminalCellBuffer(cols: 20, rows: 2);
          _seedBufferLines(
            terminal,
            const <String>['first line', 'second line'],
            cols: 20,
            rows: 2,
          );
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
          final terminal = TerminalCellBuffer(cols: 20, rows: 2);
          _seedBufferLines(
            terminal,
            const <String>['alpha', 'beta'],
            cols: 20,
            rows: 2,
          );
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

          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(copiedText, isNull);

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
          final terminal = TerminalCellBuffer(cols: 20, rows: 2);
          _seedBufferLines(
            terminal,
            const <String>['target 1', 'target 2'],
            cols: 20,
            rows: 2,
          );
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

          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();

          controller.notifyHistoryPageStarted();
          _seedBufferLines(
            terminal,
            const <String>['older 1', 'older 2', 'target 1', 'target 2'],
            cols: 20,
            rows: 2,
          );
          controller.notifyHistoryReplayed();
          await tester.pump();

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
          final terminal = TerminalCellBuffer(cols: 47, rows: 41);
          terminal.setModesForTest(
            altScreen: true,
            mouseMode: kMouseModeAnyEvent,
            mouseReportMode: kMouseReportSgr,
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
      'TerminalGridView stays pinned to bottom across loading, history sync, session swaps, and live output without phantom onNearTop paging',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        TerminalPane.debugForceNativeTerminalView = true;
        try {
          var nearTopCount = 0;
          final termA = TerminalCellBuffer();
          final ctrlA = TerminalController();
          final termB = TerminalCellBuffer();
          final ctrlB = TerminalController();

          Widget buildPane({
            required String id,
            required TerminalCellBuffer terminal,
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

          _seedBufferLines(
            termA,
            <String>[for (var i = 0; i < 120; i++) 'session A line $i'],
          );
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
            of: find.byType(TerminalGridView),
            matching: find.byType(Scrollable),
          );
          ScrollPosition pos() =>
              tester.state<ScrollableState>(scrollableFinder).position;

          expect(pos().maxScrollExtent, greaterThan(0));
          expect(pos().pixels, closeTo(pos().maxScrollExtent, 1.0));
          expect(nearTopCount, 0);

          final midA = pos().maxScrollExtent * 0.4;
          pos().jumpTo(midA);
          await tester.pump();
          expect(pos().pixels, closeTo(midA, 1.0));
          expect(nearTopCount, 0);

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

          _seedBufferLines(
            termB,
            <String>[for (var i = 0; i < 80; i++) 'session B line $i'],
          );
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

          for (var i = 80; i < 110; i++) {
            termB.appendOutputLineForTest(
              _cellLine('session B live $i', cols: termB.viewWidth),
            );
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));

          expect(pos().maxScrollExtent, greaterThan(extentBBeforeLive));
          expect(pos().pixels, closeTo(pos().maxScrollExtent, 1.0));
          expect(nearTopCount, 0);

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
            termA.appendOutputLineForTest(
              _cellLine(
                'session A live while scrolled up $i',
                cols: termA.viewWidth,
              ),
            );
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(pos().pixels, closeTo(midA, 1.0));
          expect(nearTopCount, 0);

          pos().jumpTo(0.0);
          await tester.pump();
          expect(nearTopCount, 1);

          ctrlA.notifyHistoryPageStarted();
          ctrlA.clear();
          _seedBufferLines(
            termA,
            <String>[for (var i = 0; i < 280; i++) 'session A paged line $i'],
          );
          ctrlA.notifyHistoryReplayed();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));

          final pagedPixels = pos().pixels;
          expect(pagedPixels, greaterThan(0.0));
          expect(pagedPixels, lessThan(pos().maxScrollExtent - 100.0));
          expect(nearTopCount, 1);

          for (var i = 0; i < 5; i++) {
            termA.appendOutputLineForTest(
              _cellLine(
                'session A live after page $i',
                cols: termA.viewWidth,
              ),
            );
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

    testWidgets(
      'mobile keyboard animation coalesces per-frame resize into a single settled resizeOut',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        TerminalPane.debugForceNativeTerminalView = true;
        TerminalPane.destroySession('mobile-kbd-resize');
        try {
          final term = TerminalCellBuffer();
          final ctrl = TerminalController();
          final resizeOuts = <(int, int)>[];
          ctrl.addResizeOutListener((cols, rows) {
            resizeOuts.add((cols, rows));
          });

          Widget buildWithHeight(double height) {
            return MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 400,
                  height: height,
                  child: TerminalPane(
                    terminalId: 'mobile-kbd-resize',
                    terminal: term,
                    controller: ctrl,
                    fallbackRows: const [],
                    onTerminalResizeBind: (_) {},
                    focusCursorRevision: 1,
                  ),
                ),
              ),
            );
          }

          await tester.pumpWidget(buildWithHeight(600));
          await tester.pump(const Duration(milliseconds: 150));
          final initialRows = term.viewHeight;
          resizeOuts.clear();

          for (var step = 1; step <= 10; step++) {
            final h = 600.0 - step * 30.0;
            tester.binding.handleMetricsChanged();
            await tester.pumpWidget(buildWithHeight(h));
            await tester.pump(const Duration(milliseconds: 16));
          }

          expect(term.viewHeight, initialRows);
          expect(resizeOuts, isEmpty);

          await tester.pump(const Duration(milliseconds: 100));
          expect(term.viewHeight, lessThan(initialRows));
          expect(resizeOuts.length, 1);
          expect(resizeOuts.single.$2, term.viewHeight);
        } finally {
          TerminalPane.debugForceNativeTerminalView = false;
          TerminalPane.destroySession('mobile-kbd-resize');
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'desktop primary click and wheel use 0-based viewport cell coordinates when mouse reporting is active',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        TerminalPane.debugForceNativeTerminalView = true;
        try {
          final term = TerminalCellBuffer();
          final ctrl = TerminalController();
          final sentInput = <String>[];
          ctrl.addInputListener(sentInput.add);

          _seedBufferLines(
            term,
            <String>[for (var i = 0; i < 60; i++) 'scrollback line $i'],
          );
          term.setModesForTest(
            mouseMode: kMouseModeButtonEvent,
            mouseReportMode: kMouseReportSgr,
          );

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 500,
                  child: TerminalPane(
                    terminalId: 'desktop-mouse-click-chip',
                    terminal: term,
                    controller: ctrl,
                    fallbackRows: const [],
                    onTerminalResizeBind: (_) {},
                    focusCursorRevision: 1,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          sentInput.clear();

          final paneRect = tester.getRect(find.byType(TerminalPane));
          final topTarget = paneRect.topLeft + const Offset(45, 45);
          await tester.tapAt(topTarget);
          await tester.pump(const Duration(milliseconds: 350));

          expect(sentInput.length, greaterThanOrEqualTo(2));
          final downReport = sentInput.first;
          final upReport = sentInput.last;
          expect(downReport, matches(RegExp(r'^\x1b\[<0;\d+;\d+M$')));
          expect(upReport, matches(RegExp(r'^\x1b\[<0;\d+;\d+m$')));
          final downRow = int.parse(
            RegExp(r'^\x1b\[<0;\d+;(\d+)M$').firstMatch(downReport)!.group(1)!,
          );
          expect(downRow, lessThan(10));
        } finally {
          TerminalPane.debugForceNativeTerminalView = false;
          TerminalPane.destroySession('desktop-mouse-click-chip');
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'mobile single-finger tap emits SGR mouse click at viewport cell while swipe scrolls without clicking',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        TerminalPane.debugForceNativeTerminalView = true;
        try {
          final term = TerminalCellBuffer();
          final ctrl = TerminalController();
          final sentInput = <String>[];
          ctrl.addInputListener(sentInput.add);

          term.setModesForTest(
            altScreen: true,
            mouseMode: kMouseModeButtonEvent,
            mouseReportMode: kMouseReportSgr,
          );

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 400,
                  height: 500,
                  child: TerminalPane(
                    terminalId: 'mobile-mouse-tap-chip',
                    terminal: term,
                    controller: ctrl,
                    fallbackRows: const [],
                    onTerminalResizeBind: (_) {},
                    focusCursorRevision: 1,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          sentInput.clear();

          final paneRect = tester.getRect(find.byType(TerminalPane));
          final chipTarget = Offset(paneRect.center.dx, paneRect.bottom - 70);
          await tester.tapAt(chipTarget);
          await tester.pump(const Duration(milliseconds: 350));

          expect(sentInput.length, 2);
          expect(sentInput[0], matches(RegExp(r'^\x1b\[<0;\d+;\d+M$')));
          expect(sentInput[1], matches(RegExp(r'^\x1b\[<0;\d+;\d+m$')));

          sentInput.clear();
          await tester.dragFrom(paneRect.center, const Offset(0, -90));
          await tester.pump(const Duration(milliseconds: 350));

          expect(sentInput, isNotEmpty);
          expect(
            sentInput.every(
              (s) => RegExp(r'^\x1b\[<6[45];\d+;\d+M$').hasMatch(s),
            ),
            isTrue,
          );
        } finally {
          TerminalPane.debugForceNativeTerminalView = false;
          TerminalPane.destroySession('mobile-mouse-tap-chip');
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'fit, refit, and history replay reconcile terminal size with RenderTerminalGrid when terminal was resized to a stale grid',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        TerminalPane.debugForceNativeTerminalView = true;
        try {
          final term = TerminalCellBuffer();
          final ctrl = TerminalController();
          final resizeOuts = <(int, int)>[];
          ctrl.addResizeOutListener(
            (cols, rows) => resizeOuts.add((cols, rows)),
          );

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 500,
                  child: TerminalPane(
                    terminalId: 'reconcile-stale-grid',
                    terminal: term,
                    controller: ctrl,
                    fallbackRows: const [],
                    onTerminalResizeBind: (_) {},
                    focusCursorRevision: 1,
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 150));

          final fittedCols = term.viewWidth;
          final fittedRows = term.viewHeight;
          expect(fittedCols, greaterThan(47));
          expect(fittedRows, greaterThan(19));

          term.resize(47, 19);
          expect(term.viewWidth, 47);
          expect(term.viewHeight, 19);

          ctrl.fit();
          await tester.pump();
          expect(term.viewWidth, fittedCols);
          expect(term.viewHeight, fittedRows);

          TerminalPane.invalidateCachedResizeOut('reconcile-stale-grid');
          term.resize(47, 19);
          resizeOuts.clear();
          ctrl.notifyHistoryReplayed();
          await tester.pump();
          expect(term.viewWidth, fittedCols);
          expect(term.viewHeight, fittedRows);
          await tester.pump(const Duration(milliseconds: 150));
          expect(resizeOuts, isEmpty);

          resizeOuts.clear();
          TerminalPane.invalidateCachedResizeOut('reconcile-stale-grid');
          ctrl.fit();
          await tester.pump();
          expect(resizeOuts, [(fittedCols, fittedRows)]);
        } finally {
          TerminalPane.debugForceNativeTerminalView = false;
          TerminalPane.destroySession('reconcile-stale-grid');
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'isLoading placeholder pane records workspace size without poisoning resizeOut cache for the loaded session',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        TerminalPane.debugForceNativeTerminalView = true;
        try {
          final placeholderTerm = TerminalCellBuffer();
          final placeholderCtrl = TerminalController();
          final loadedTerm = TerminalCellBuffer();
          final loadedCtrl = TerminalController();
          final loadedResizeOuts = <(int, int)>[];
          loadedCtrl.addResizeOutListener(
            (cols, rows) => loadedResizeOuts.add((cols, rows)),
          );

          Widget buildPane({
            required TerminalCellBuffer terminal,
            required TerminalController controller,
            required bool isLoading,
          }) {
            return MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 500,
                  child: TerminalPane(
                    terminalId: 'loading-swap-resize',
                    terminal: terminal,
                    controller: controller,
                    fallbackRows: const [],
                    onTerminalResizeBind: (cb) {
                      terminal.onResize = cb;
                    },
                    focusCursorRevision: 1,
                    isLoading: isLoading,
                  ),
                ),
              ),
            );
          }

          await tester.pumpWidget(
            buildPane(
              terminal: placeholderTerm,
              controller: placeholderCtrl,
              isLoading: true,
            ),
          );
          await tester.pump(const Duration(milliseconds: 150));

          final fittedCols = placeholderTerm.viewWidth;
          final fittedRows = placeholderTerm.viewHeight;
          expect(TerminalPane.getLastFittedWorkspaceSize(), (
            fittedRows,
            fittedCols,
          ));

          await tester.pumpWidget(
            buildPane(
              terminal: loadedTerm,
              controller: loadedCtrl,
              isLoading: false,
            ),
          );
          await tester.pump(const Duration(milliseconds: 150));

          expect(loadedTerm.viewWidth, fittedCols);
          expect(loadedTerm.viewHeight, fittedRows);
          expect(loadedResizeOuts, contains((fittedCols, fittedRows)));
        } finally {
          TerminalPane.debugForceNativeTerminalView = false;
          TerminalPane.destroySession('loading-swap-resize');
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
