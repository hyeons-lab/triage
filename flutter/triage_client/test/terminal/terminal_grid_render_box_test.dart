import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';
import 'package:triage_client/terminal/terminal_selection.dart';
import 'package:triage_client/widgets/terminal_grid_render_box.dart';

void main() {
  group('TerminalGridView & RenderTerminalGrid', () {
    testWidgets(
      'measures positive cell metrics, fits cols/rows to viewport, and maps cell offsets',
      (WidgetTester tester) async {
        final buffer = TerminalCellBuffer(cols: 80, rows: 24);
        final scrollController = ScrollController();
        addTearDown(() {
          scrollController.dispose();
          buffer.dispose();
        });

        int? reportedCols;
        int? reportedRows;
        final gridKey = GlobalKey<TerminalGridViewState>();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 480,
                child: TerminalGridView(
                  key: gridKey,
                  buffer: buffer,
                  scrollController: scrollController,
                  onGridMetricsChanged: (cols, rows, cw, ch) {
                    reportedCols = cols;
                    reportedRows = rows;
                    buffer.resize(cols, rows);
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final renderGrid = gridKey.currentState!.renderGrid!;
        expect(renderGrid.cellWidth, greaterThan(1.0));
        expect(renderGrid.lineHeight, greaterThan(2.0));
        expect(reportedCols, equals(renderGrid.fittedCols));
        expect(reportedRows, equals(renderGrid.fittedRows));
        expect(buffer.viewWidth, equals(renderGrid.fittedCols));
        expect(buffer.viewHeight, equals(renderGrid.fittedRows));

        final target = const CellOffset(5, 3);
        final pixelPos = renderGrid.getOffset(target);
        final mapped = renderGrid.getCellOffset(
          pixelPos + const Offset(1.0, 1.0),
        );
        expect(mapped, equals(target));
      },
    );

    testWidgets(
      'sizes virtual scrollback extent across thousands of rows and demand-pages missing top rows',
      (WidgetTester tester) async {
        final buffer = TerminalCellBuffer(cols: 80, rows: 20);
        final scrollController = ScrollController();
        addTearDown(() {
          scrollController.dispose();
          buffer.dispose();
        });

        buffer.applySyncFrame(
          TerminalSyncFrameData(
            frameSeq: 1,
            rows: 20,
            cols: 80,
            totalScrollbackRows: 2000,
            trimmedTopRows: 0,
            eraseScrollbackGen: 0,
            cursorX: 0,
            cursorY: 0,
            cursorStyle: 2,
            modeFlags: kModeCursorVisible | kModeFullViewport,
            mouseMode: 0,
            mouseReportMode: 0,
            kittyKeyboardFlags: 0,
            title: null,
            viewportCompression: kCellCompressionNone,
            viewportPayload: encodeTcg1PlainTextRows(const <String>[
              'live bottom row',
            ], cols: 80),
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 0,
            pushedScrollbackCompression: kCellCompressionNone,
            pushedScrollbackPayload: Uint8List(0),
          ),
        );

        final missingVisibleCalls = <(int, int)>[];
        final gridKey = GlobalKey<TerminalGridViewState>();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 360,
                child: TerminalGridView(
                  key: gridKey,
                  buffer: buffer,
                  scrollController: scrollController,
                  autoResize: false,
                  stickToBottom: true,
                  onMissingRowsVisible: (firstRow, lastRow) {
                    missingVisibleCalls.add((firstRow, lastRow));
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final renderGrid = gridKey.currentState!.renderGrid!;
        final expectedExtent =
            buffer.totalLines * renderGrid.lineHeight - 360.0;
        expect(
          scrollController.position.maxScrollExtent,
          closeTo(expectedExtent, 0.5),
        );
        // Initially pinned to bottom, where only live viewport rows are visible.
        expect(
          scrollController.position.pixels,
          closeTo(scrollController.position.maxScrollExtent, 0.5),
        );

        // Jump to virtual row 0 (unloaded scrollback) -> triggers post-frame
        // onMissingRowsVisible callback covering row 0.
        scrollController.jumpTo(0.0);
        await tester.pump();
        await tester.pump();

        expect(missingVisibleCalls, isNotEmpty);
        expect(missingVisibleCalls.last.$1, equals(0));
      },
    );

    testWidgets(
      'paints styled cells, wide glyphs, selection highlight, and static unfocused cursor cleanly',
      (WidgetTester tester) async {
        final buffer = TerminalCellBuffer(cols: 40, rows: 6);
        final scrollController = ScrollController();
        final focusNode = FocusNode();
        addTearDown(() {
          focusNode.dispose();
          scrollController.dispose();
          buffer.dispose();
        });

        final styledPayload = encodeTcg1StyledRows(const <StyledRow>[
          StyledRow(
            spans: <StyledSpan>[
              StyledSpan(
                text: '中文 bold ',
                style: TerminalStyle(
                  foreground: TerminalColor(red: 127, green: 209, blue: 199),
                  background: TerminalColor(red: 25, green: 35, blue: 40),
                  bold: true,
                  underline: true,
                ),
              ),
              StyledSpan(
                text: 'inverse',
                style: TerminalStyle(reverse: true, italic: true),
              ),
            ],
          ),
        ], cols: 40);
        buffer.applySyncFrame(
          TerminalSyncFrameData(
            frameSeq: 1,
            rows: 6,
            cols: 40,
            totalScrollbackRows: 0,
            trimmedTopRows: 0,
            eraseScrollbackGen: 0,
            cursorX: 2,
            cursorY: 0,
            cursorStyle:
                1, // blinkingBlock when focused; hollow static when unfocused
            modeFlags: kModeCursorVisible | kModeFullViewport,
            mouseMode: 0,
            mouseReportMode: 0,
            kittyKeyboardFlags: 0,
            title: null,
            viewportCompression: kCellCompressionNone,
            viewportPayload: styledPayload,
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 0,
            pushedScrollbackCompression: kCellCompressionNone,
            pushedScrollbackPayload: Uint8List(0),
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 200,
                child: TerminalGridView(
                  buffer: buffer,
                  scrollController: scrollController,
                  focusNode: focusNode,
                  autoResize: false,
                  selection: const TerminalSelectionRange(
                    CellOffset(0, 0),
                    CellOffset(10, 0),
                  ),
                ),
              ),
            ),
          ),
        );

        // When unfocused, no continuous cursor-blink ticker is active, so
        // pumpAndSettle completes cleanly without timing out.
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'standalone autofocus/onKeyEvent works without external focusNode, ignores remote buffer width drift and 0x0 collapse, and pins swapped ScrollController to bottom',
      (WidgetTester tester) async {
        final buffer = TerminalCellBuffer(cols: 80, rows: 24);
        final controllerA = ScrollController();
        final controllerB = ScrollController();
        addTearDown(() {
          controllerA.dispose();
          controllerB.dispose();
          buffer.dispose();
        });

        buffer.applySyncFrame(
          TerminalSyncFrameData(
            frameSeq: 1,
            rows: 24,
            cols: 80,
            totalScrollbackRows: 100,
            trimmedTopRows: 0,
            eraseScrollbackGen: 0,
            cursorX: 0,
            cursorY: 0,
            cursorStyle: 2,
            modeFlags: kModeCursorVisible | kModeFullViewport,
            mouseMode: 0,
            mouseReportMode: 0,
            kittyKeyboardFlags: 0,
            title: null,
            viewportCompression: kCellCompressionNone,
            viewportPayload: encodeTcg1PlainTextRows(const <String>[
              'prompt',
            ], cols: 80),
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 0,
            pushedScrollbackCompression: kCellCompressionNone,
            pushedScrollbackPayload: Uint8List(0),
          ),
        );

        var metricsNotifications = 0;
        var keyEvents = 0;
        final gridKey = GlobalKey<TerminalGridViewState>();

        Widget buildHarness({
          required double width,
          required double height,
          required ScrollController controller,
        }) {
          return MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: width,
                height: height,
                child: TerminalGridView(
                  key: gridKey,
                  buffer: buffer,
                  scrollController: controller,
                  autofocus: true,
                  stickToBottom: true,
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent) keyEvents++;
                    return KeyEventResult.handled;
                  },
                  onGridMetricsChanged: (c, r, cw, ch) {
                    metricsNotifications++;
                  },
                ),
              ),
            ),
          );
        }

        await tester.pumpWidget(
          buildHarness(width: 640, height: 360, controller: controllerA),
        );
        await tester.pumpAndSettle();
        expect(metricsNotifications, 1);

        // Key events reach standalone TerminalGridView without external FocusNode.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyX);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyX);
        expect(keyEvents, 1);

        // Remote TerminalSync updating buffer.viewWidth at unchanged layout
        // constraints must not re-fire onGridMetricsChanged.
        buffer.applySyncFrame(
          TerminalSyncFrameData(
            frameSeq: 2,
            rows: 24,
            cols: 120,
            totalScrollbackRows: 100,
            trimmedTopRows: 0,
            eraseScrollbackGen: 0,
            cursorX: 0,
            cursorY: 0,
            cursorStyle: 2,
            modeFlags: kModeCursorVisible | kModeFullViewport,
            mouseMode: 0,
            mouseReportMode: 0,
            kittyKeyboardFlags: 0,
            title: null,
            viewportCompression: kCellCompressionNone,
            viewportPayload: Uint8List(0),
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 0,
            pushedScrollbackCompression: kCellCompressionNone,
            pushedScrollbackPayload: Uint8List(0),
          ),
        );
        await tester.pumpAndSettle();
        expect(metricsNotifications, 1);

        // Collapsing viewport to 0x0 must not emit transient 1x1 metrics.
        await tester.pumpWidget(
          buildHarness(width: 0, height: 0, controller: controllerA),
        );
        await tester.pumpAndSettle();
        expect(metricsNotifications, 1);

        // Restoring viewport and swapping to fresh controllerB pins controllerB to bottom.
        await tester.pumpWidget(
          buildHarness(width: 640, height: 360, controller: controllerB),
        );
        await tester.pumpAndSettle();
        expect(controllerB.hasClients, isTrue);
        expect(
          controllerB.position.pixels,
          closeTo(controllerB.position.maxScrollExtent, 1.0),
        );
      },
    );

    testWidgets(
      'handles late onGridMetricsChanged attachment, synchronous resize in callback, focusNode removal, and unbounded axes',
      (WidgetTester tester) async {
        final buffer = TerminalCellBuffer(cols: 93, rows: 27);
        final scrollController = ScrollController();
        final externalFocus = FocusNode();
        addTearDown(scrollController.dispose);
        addTearDown(externalFocus.dispose);

        (int, int)? reported;
        // Phase 1: mount with externalFocus focused and onGridMetricsChanged == null.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: TerminalGridView(
                    buffer: buffer,
                    scrollController: scrollController,
                    focusNode: externalFocus,
                    autofocus: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(externalFocus.hasFocus, isTrue);

        // Phase 2: remove externalFocus (focusNode -> null) and attach onGridMetricsChanged
        // that synchronously calls buffer.resize(...) during post-frame callback.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: TerminalGridView(
                    buffer: buffer,
                    scrollController: scrollController,
                    focusNode: null,
                    autofocus: false,
                    onGridMetricsChanged: (cols, rows, cw, ch) {
                      reported = (cols, rows);
                      buffer.resize(
                        cols,
                        rows,
                        (cols * cw).round(),
                        (rows * ch).round(),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Exact integer fallbackCols/fallbackRows preserved on unbounded axes (no IEEE-754 floor loss to 92/26).
        expect(reported, (93, 27));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
