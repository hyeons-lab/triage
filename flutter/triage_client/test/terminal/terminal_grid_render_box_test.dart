import 'dart:typed_data';

import 'package:flutter/material.dart';
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
            viewportPayload: encodeTcg1PlainTextRows(
              const <String>['live bottom row'],
              cols: 80,
            ),
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

        final styledPayload = encodeTcg1StyledRows(
          const <StyledRow>[
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
          ],
          cols: 40,
        );
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
            cursorStyle: 1, // blinkingBlock when focused; hollow static when unfocused
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
  });
}
