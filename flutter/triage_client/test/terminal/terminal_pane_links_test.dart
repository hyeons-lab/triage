import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';
import 'package:triage_client/widgets/terminal_grid_render_box.dart';
import 'package:triage_client/widgets/terminal_pane.dart';

void _applyLines(
  TerminalCellBuffer buffer,
  List<String> lines, {
  int cols = 60,
  int mouseMode = 0,
  Set<int> wrappedRowIndices = const <int>{},
}) {
  buffer.applySyncFrame(
    TerminalSyncFrameData(
      frameSeq: 1,
      rows: lines.length,
      cols: cols,
      totalScrollbackRows: 0,
      trimmedTopRows: 0,
      eraseScrollbackGen: 0,
      cursorX: 0,
      cursorY: 0,
      cursorStyle: 2,
      modeFlags: kModeCursorVisible | kModeAutoWrap | kModeFullViewport,
      mouseMode: mouseMode,
      mouseReportMode: mouseMode > 0 ? 1006 : 0,
      kittyKeyboardFlags: 0,
      title: null,
      viewportCompression: kCellCompressionNone,
      viewportPayload: encodeTcg1PlainTextRows(
        lines,
        cols: cols,
        wrappedRowIndices: wrappedRowIndices,
      ),
      pushedScrollbackStartRow: 0,
      pushedScrollbackRowCount: 0,
      pushedScrollbackCompression: kCellCompressionNone,
      pushedScrollbackPayload: Uint8List(0),
    ),
  );
}

Offset _cellCenterGlobal(WidgetTester tester, int col, int row) {
  final gridState = tester.state<TerminalGridViewState>(
    find.byType(TerminalGridView),
  );
  final renderGrid = gridState.renderGrid!;
  return renderGrid.localToGlobal(
    Offset(
      (col + 0.5) * renderGrid.cellWidth,
      (row + 0.5) * renderGrid.lineHeight,
    ),
  );
}

MouseRegion _paneHoverMouseRegion(WidgetTester tester) {
  return tester.widget<MouseRegion>(
    find.descendant(
      of: find.byType(TerminalPane),
      matching: find.byWidgetPredicate(
        (w) => w is MouseRegion && w.onHover != null,
      ),
    ),
  );
}

Future<void> _pumpTestPane(
  WidgetTester tester, {
  required String id,
  required TerminalCellBuffer terminal,
  required TerminalController controller,
  required List<Uri> openedUrls,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 500,
          child: TerminalPane(
            terminalId: id,
            terminal: terminal,
            controller: controller,
            fallbackRows: const [],
            onOpenUrl: openedUrls.add,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('TerminalPane clickable URLs', () {
    testWidgets('hover shows click cursor and click opens URL on desktop', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      TerminalPane.debugForceNativeTerminalView = true;
      final controller = TerminalController();
      final terminal = TerminalCellBuffer(cols: 60, rows: 10);
      final openedUrls = <Uri>[];
      try {
        _applyLines(terminal, <String>[
          'see https://example.com/docs?q=1 please',
          'plain text row',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
        ]);

        await _pumpTestPane(
          tester,
          id: 'url-click-desktop',
          terminal: terminal,
          controller: controller,
          openedUrls: openedUrls,
        );

        final urlPos = _cellCenterGlobal(tester, 10, 0);
        final plainPos = _cellCenterGlobal(tester, 2, 1);
        final gridState = tester.state<TerminalGridViewState>(
          find.byType(TerminalGridView),
        );

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        await mouse.moveTo(urlPos);
        await tester.pump();
        expect(_paneHoverMouseRegion(tester).cursor, SystemMouseCursors.click);
        expect(
          gridState.renderGrid!.hoveredLink?.url,
          'https://example.com/docs?q=1',
        );

        await mouse.moveTo(plainPos);
        await tester.pump();
        expect(_paneHoverMouseRegion(tester).cursor, SystemMouseCursors.text);
        expect(gridState.renderGrid!.hoveredLink, isNull);

        await tester.tapAt(urlPos);
        await tester.pump();
        expect(openedUrls, <Uri>[Uri.parse('https://example.com/docs?q=1')]);
      } finally {
        TerminalPane.debugForceNativeTerminalView = false;
        TerminalPane.destroySession('url-click-desktop');
        debugDefaultTargetPlatformOverride = null;
        terminal.dispose();
      }
    });

    testWidgets(
      'drag over URL selects instead of opening, and clicking to clear selection does not open',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        TerminalPane.debugForceNativeTerminalView = true;
        final controller = TerminalController();
        final terminal = TerminalCellBuffer(cols: 60, rows: 10);
        final openedUrls = <Uri>[];
        try {
          _applyLines(terminal, <String>[
            'go https://example.com/drag-target now',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ]);

          await _pumpTestPane(
            tester,
            id: 'url-drag-clear',
            terminal: terminal,
            controller: controller,
            openedUrls: openedUrls,
          );

          final start = _cellCenterGlobal(tester, 5, 0);
          final end = _cellCenterGlobal(tester, 25, 0);
          final gridState = tester.state<TerminalGridViewState>(
            find.byType(TerminalGridView),
          );

          await tester.dragFrom(start, end - start);
          await tester.pump();
          expect(openedUrls, isEmpty);
          expect(gridState.renderGrid!.selection, isNotNull);
          expect(gridState.renderGrid!.selection!.isCollapsed, isFalse);

          // Clicking the URL while an active selection exists clears the
          // selection instead of launching the browser.
          await tester.tapAt(start);
          await tester.pump();
          expect(gridState.renderGrid!.selection, isNull);
          expect(openedUrls, isEmpty);

          // A subsequent click with no active selection opens the URL.
          await tester.tapAt(start);
          await tester.pump();
          expect(openedUrls, <Uri>[
            Uri.parse('https://example.com/drag-target'),
          ]);
        } finally {
          TerminalPane.debugForceNativeTerminalView = false;
          TerminalPane.destroySession('url-drag-clear');
          debugDefaultTargetPlatformOverride = null;
          terminal.dispose();
        }
      },
    );

    testWidgets(
      'mouseMode > 0 forwards plain clicks and requires Ctrl+click to open URL',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        TerminalPane.debugForceNativeTerminalView = true;
        final controller = TerminalController();
        final sentInputs = <String>[];
        controller.addInputListener(sentInputs.add);
        final terminal = TerminalCellBuffer(cols: 60, rows: 10);
        final openedUrls = <Uri>[];
        try {
          _applyLines(terminal, <String>[
            'see https://example.com/tui-link here',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ], mouseMode: 1000);

          await _pumpTestPane(
            tester,
            id: 'url-mouse-mode',
            terminal: terminal,
            controller: controller,
            openedUrls: openedUrls,
          );

          final urlPos = _cellCenterGlobal(tester, 10, 0);

          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          addTearDown(mouse.removePointer);
          await mouse.moveTo(urlPos);
          await tester.pump();
          expect(
            _paneHoverMouseRegion(tester).cursor,
            SystemMouseCursors.basic,
          );

          await tester.tapAt(urlPos);
          await tester.pump();
          expect(openedUrls, isEmpty);
          expect(sentInputs, isNotEmpty);

          sentInputs.clear();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(
            _paneHoverMouseRegion(tester).cursor,
            SystemMouseCursors.click,
          );

          await tester.tapAt(urlPos);
          await tester.pump();
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();

          expect(openedUrls, <Uri>[Uri.parse('https://example.com/tui-link')]);
          expect(sentInputs, isEmpty);
        } finally {
          TerminalPane.debugForceNativeTerminalView = false;
          TerminalPane.destroySession('url-mouse-mode');
          debugDefaultTargetPlatformOverride = null;
          terminal.dispose();
        }
      },
    );

    testWidgets(
      'mobile short tap opens URL while long press selects without opening',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        TerminalPane.debugForceNativeTerminalView = true;
        final controller = TerminalController();
        final terminal = TerminalCellBuffer(cols: 60, rows: 10);
        final openedUrls = <Uri>[];
        try {
          _applyLines(terminal, <String>[
            'tap https://example.com/mobile-url ok',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ]);

          await _pumpTestPane(
            tester,
            id: 'url-mobile',
            terminal: terminal,
            controller: controller,
            openedUrls: openedUrls,
          );

          final urlPos = _cellCenterGlobal(tester, 10, 0);
          final gridState = tester.state<TerminalGridViewState>(
            find.byType(TerminalGridView),
          );

          await tester.longPressAt(urlPos);
          await tester.pumpAndSettle();
          expect(openedUrls, isEmpty);
          expect(gridState.renderGrid!.selection, isNotNull);
        } finally {
          TerminalPane.debugForceNativeTerminalView = false;
          TerminalPane.destroySession('url-mobile');
          debugDefaultTargetPlatformOverride = null;
          terminal.dispose();
        }
      },
    );

    testWidgets('mobile tap without long press opens URL', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TerminalPane.debugForceNativeTerminalView = true;
      final controller = TerminalController();
      final terminal = TerminalCellBuffer(cols: 60, rows: 10);
      final openedUrls = <Uri>[];
      try {
        _applyLines(terminal, <String>[
          'tap https://example.com/mobile-tap ok',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
        ]);

        await _pumpTestPane(
          tester,
          id: 'url-mobile-tap',
          terminal: terminal,
          controller: controller,
          openedUrls: openedUrls,
        );

        await tester.tapAt(_cellCenterGlobal(tester, 10, 0));
        await tester.pumpAndSettle();
        expect(openedUrls, <Uri>[Uri.parse('https://example.com/mobile-tap')]);
      } finally {
        TerminalPane.debugForceNativeTerminalView = false;
        TerminalPane.destroySession('url-mobile-tap');
        debugDefaultTargetPlatformOverride = null;
        terminal.dispose();
      }
    });
  });
}
