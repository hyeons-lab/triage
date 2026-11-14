import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';
import 'package:triage_client/terminal/terminal_scroll_anchor.dart';
import 'package:triage_client/terminal/terminal_selection.dart';

TerminalCellLine _lineFromText(String text, {int width = 20}) {
  return TerminalCellLine.fromSpec(<String?>[
    for (final r in text.runes) String.fromCharCode(r),
  ], width: width);
}

void main() {
  const lineHeight = 10.0;

  TerminalCellBuffer bufferWithScrollback() {
    final buffer = TerminalCellBuffer(cols: 20, rows: 5);
    buffer.seedLinesForTest(
      cols: 20,
      rows: 5,
      scrollback: <TerminalCellLine>[
        for (var i = 0; i < 15; i++) _lineFromText('line $i'),
      ],
      viewport: <TerminalCellLine>[
        for (var i = 15; i < 20; i++) _lineFromText('line $i'),
      ],
    );
    return buffer;
  }

  void applyDaemonScrollbackClear(
    TerminalCellBuffer buffer, {
    int? cols,
    int? rows,
  }) {
    final targetCols = cols ?? buffer.viewWidth;
    final targetRows = rows ?? buffer.viewHeight;
    final viewportLines = <String>[
      for (var r = 0; r < targetRows; r++)
        buffer
                .lineAtVirtualRow(buffer.totalScrollbackRows + r)
                ?.toPlainText() ??
            '',
    ];
    buffer.applySyncFrame(
      TerminalSyncFrameData(
        frameSeq: buffer.lastFrameSeq + 1,
        rows: targetRows,
        cols: targetCols,
        totalScrollbackRows: 0,
        trimmedTopRows: 0,
        eraseScrollbackGen: buffer.eraseScrollbackGen + 1,
        cursorX: 0,
        cursorY: targetRows - 1,
        cursorStyle: 0,
        modeFlags:
            kModeCursorVisible |
            kModeAutoWrap |
            kModeSawEraseScrollback |
            kModeFullViewport,
        mouseMode: 0,
        mouseReportMode: 0,
        kittyKeyboardFlags: 0,
        title: null,
        viewportCompression: kCellCompressionNone,
        viewportPayload: encodeTcg1PlainTextRows(
          viewportLines,
          cols: targetCols,
        ),
        pushedScrollbackStartRow: 0,
        pushedScrollbackRowCount: 0,
        pushedScrollbackCompression: kCellCompressionNone,
        pushedScrollbackPayload: Uint8List(0),
      ),
    );
  }

  group('after a scrollback clear', () {
    test('scrollback rows are dropped from the buffer', () {
      final buffer = bufferWithScrollback();
      expect(buffer.totalScrollbackRows, 15);
      expect(buffer.totalLines, 20);
      expect(buffer.lineAtVirtualRow(0)?.toPlainText(), 'line 0');

      applyDaemonScrollbackClear(buffer);

      expect(buffer.totalScrollbackRows, 0);
      expect(buffer.totalLines, 5);
      expect(buffer.residentScrollbackPageCount, 0);
      expect(buffer.lineAtVirtualRow(0)?.toPlainText(), 'line 15');
    });

    test('surviving viewport lines sit at virtual rows 0..viewHeight-1', () {
      final buffer = bufferWithScrollback();
      applyDaemonScrollbackClear(buffer);

      for (var row = 0; row < buffer.totalLines; row++) {
        expect(buffer.lineAtVirtualRow(row)?.toPlainText(), 'line ${15 + row}');
      }
      expect(buffer.lineAtVirtualRow(buffer.totalLines), isNull);
    });

    test('the scroll anchor releases instead of pinning to the top', () {
      final buffer = bufferWithScrollback();
      final anchor = TerminalScrollAnchor();
      anchor.capture(
        buffer: buffer,
        pixels: 30,
        maxScrollExtent: 150,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);
      expect(
        anchor.desiredOffset(maxScrollExtent: 150, lineHeight: lineHeight),
        30,
      );

      applyDaemonScrollbackClear(buffer);

      expect(
        anchor.desiredOffset(maxScrollExtent: 150, lineHeight: lineHeight),
        isNull,
      );
      expect(anchor.hasAnchor, isFalse);
    });

    test('a selection over cleared rows is no longer live', () {
      final buffer = bufferWithScrollback();
      final before = TerminalSelectionRange(
        const CellOffset(0, 0),
        const CellOffset(6, 0),
        trimmedTopRows: buffer.trimmedTopRows,
        eraseScrollbackGen: buffer.eraseScrollbackGen,
      );
      expect(terminalSelectionIsLive(buffer, before), isTrue);

      applyDaemonScrollbackClear(buffer);

      expect(terminalSelectionIsLive(buffer, before), isFalse);
      expect(before.selectedColsOnRow(buffer, 0), isNull);
    });

    test('a selection created after clear over surviving rows stays live', () {
      final buffer = bufferWithScrollback();
      applyDaemonScrollbackClear(buffer);
      final selection = TerminalSelectionRange(
        const CellOffset(0, 1),
        const CellOffset(3, 1),
        trimmedTopRows: buffer.trimmedTopRows,
        eraseScrollbackGen: buffer.eraseScrollbackGen,
      );
      expect(terminalSelectionIsLive(buffer, selection), isTrue);
      expect(terminalSelectionText(buffer, selection), 'lin');
    });

    test('stale FetchTerminalRows pages from before clear are discarded', () {
      final buffer = bufferWithScrollback();
      final oldGen = buffer.eraseScrollbackGen;
      applyDaemonScrollbackClear(buffer);

      final accepted = buffer.applyFetchedRows(
        TerminalRowsPageData(
          sessionId: 's1',
          startRow: 0,
          rowCount: 2,
          totalScrollbackRows: 15,
          trimmedTopRows: 0,
          eraseScrollbackGen: oldGen,
          compression: kCellCompressionNone,
          payload: encodeTcg1PlainTextRows(const <String>[
            'stale 0',
            'stale 1',
          ], cols: 20),
        ),
      );

      expect(accepted, isFalse);
      expect(buffer.totalScrollbackRows, 0);
      expect(buffer.residentScrollbackPageCount, 0);
    });
  });

  group('after a scrollback clear and a width change', () {
    TerminalCellBuffer clearedThenResized(int newWidth) {
      final buffer = bufferWithScrollback();
      applyDaemonScrollbackClear(buffer);
      buffer.resize(newWidth, 5);
      return buffer;
    }

    for (final width in const [30, 12]) {
      test('every surviving row stays in order at width $width', () {
        final buffer = clearedThenResized(width);

        expect(buffer.totalScrollbackRows, 0);
        expect(buffer.totalLines, 5);
        for (var row = 0; row < buffer.totalLines; row++) {
          expect(
            buffer.lineAtVirtualRow(row)?.toPlainText(),
            'line ${15 + row}',
          );
        }
      });

      test('cleared lines are not resurrected at width $width', () {
        final buffer = bufferWithScrollback();
        final cleared = buffer.lineAtVirtualRow(0)!;
        applyDaemonScrollbackClear(buffer);
        buffer.resize(width, 5);

        for (var row = 0; row < buffer.totalLines; row++) {
          expect(identical(buffer.lineAtVirtualRow(row), cleared), isFalse);
        }
      });
    }

    test('a live selection survives the width change', () {
      final buffer = clearedThenResized(30);
      final selection = TerminalSelectionRange(
        const CellOffset(0, 1),
        const CellOffset(4, 1),
        trimmedTopRows: buffer.trimmedTopRows,
        eraseScrollbackGen: buffer.eraseScrollbackGen,
      );

      buffer.resize(24, 5);

      expect(terminalSelectionIsLive(buffer, selection), isTrue);
      expect(terminalSelectionText(buffer, selection), 'line');
    });

    test('a scroll anchor on a post-clear scrollback line still pins', () {
      final buffer = bufferWithScrollback();
      applyDaemonScrollbackClear(buffer);
      for (var i = 0; i < 6; i++) {
        buffer.appendOutputLineForTest(_lineFromText('fresh $i'));
      }
      final anchor = TerminalScrollAnchor();
      anchor.capture(
        buffer: buffer,
        pixels: 20,
        maxScrollExtent: 60,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);
      final anchoredText = buffer.lineAtVirtualRow(2)!.toPlainText();

      buffer.resize(30, 5);

      expect(buffer.lineAtVirtualRow(2)!.toPlainText(), anchoredText);
      expect(
        anchor.desiredOffset(maxScrollExtent: 60, lineHeight: lineHeight),
        20,
      );
    });
  });
}
