import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';

TerminalSyncFrameData _makeFrame({
  int frameSeq = 1,
  int rows = 4,
  int cols = 40,
  int totalScrollbackRows = 0,
  int trimmedTopRows = 0,
  int eraseScrollbackGen = 0,
  int cursorX = 0,
  int cursorY = 0,
  int cursorStyle = 2,
  int modeFlags = kModeCursorVisible | kModeAutoWrap | kModeFullViewport,
  int mouseMode = 0,
  int mouseReportMode = 0,
  int kittyKeyboardFlags = 0,
  String? title,
  Uint8List? viewportPayload,
  int pushedScrollbackStartRow = 0,
  int pushedScrollbackRowCount = 0,
  Uint8List? pushedScrollbackPayload,
}) {
  return TerminalSyncFrameData(
    frameSeq: frameSeq,
    rows: rows,
    cols: cols,
    totalScrollbackRows: totalScrollbackRows,
    trimmedTopRows: trimmedTopRows,
    eraseScrollbackGen: eraseScrollbackGen,
    cursorX: cursorX,
    cursorY: cursorY,
    cursorStyle: cursorStyle,
    modeFlags: modeFlags,
    mouseMode: mouseMode,
    mouseReportMode: mouseReportMode,
    kittyKeyboardFlags: kittyKeyboardFlags,
    title: title,
    viewportCompression: kCellCompressionNone,
    viewportPayload: viewportPayload ?? Uint8List(0),
    pushedScrollbackStartRow: pushedScrollbackStartRow,
    pushedScrollbackRowCount: pushedScrollbackRowCount,
    pushedScrollbackCompression: kCellCompressionNone,
    pushedScrollbackPayload: pushedScrollbackPayload ?? Uint8List(0),
  );
}

void main() {
  group('TerminalCellBuffer sync & virtual scrollback cache', () {
    test('applies full viewport and dirty-row delta updates', () {
      final titles = <String>[];
      var bells = 0;
      final buf = TerminalCellBuffer(
        cols: 40,
        rows: 4,
        onTitleChanged: titles.add,
        onBell: () => bells++,
      );

      buf.applySyncFrame(
        _makeFrame(
          frameSeq: 1,
          rows: 4,
          cols: 40,
          cursorX: 5,
          cursorY: 2,
          modeFlags:
              kModeCursorVisible |
              kModeAutoWrap |
              kModeFullViewport |
              kModeTitleChanged,
          title: 'build-job',
          viewportPayload: encodeTcg1PlainTextRows(
            const <String>['row 0', 'row 1', 'row 2', 'row 3'],
            cols: 40,
          ),
        ),
      );

      expect(buf.lastFrameSeq, 1);
      expect(buf.cursorX, 5);
      expect(buf.cursorY, 2);
      expect(buf.title, 'build-job');
      expect(titles, <String>['build-job']);
      expect(buf.lineAtVirtualRow(0)?.toPlainText(), 'row 0');
      expect(buf.lineAtVirtualRow(1)?.toPlainText(), 'row 1');
      expect(buf.lineAtVirtualRow(2)?.toPlainText(), 'row 2');
      expect(buf.lineAtVirtualRow(3)?.toPlainText(), 'row 3');

      // Apply dirty-row delta touching only row 2 plus a bell signal.
      buf.applySyncFrame(
        _makeFrame(
          frameSeq: 2,
          rows: 4,
          cols: 40,
          cursorX: 9,
          cursorY: 2,
          modeFlags: kModeCursorVisible | kModeAutoWrap | kModeBellRang,
          viewportPayload: encodeTcg1PlainTextRows(
            const <String>['row 2 updated'],
            cols: 40,
            startRowIndex: 2,
          ),
        ),
      );

      expect(buf.lastFrameSeq, 2);
      expect(bells, 1);
      expect(buf.lineAtVirtualRow(0)?.toPlainText(), 'row 0');
      expect(buf.lineAtVirtualRow(1)?.toPlainText(), 'row 1');
      expect(buf.lineAtVirtualRow(2)?.toPlainText(), 'row 2 updated');
      expect(buf.lineAtVirtualRow(3)?.toPlainText(), 'row 3');
    });

    test('records pushed scrollback rows and computes missing page ranges', () {
      final buf = TerminalCellBuffer(cols: 40, rows: 4);
      buf.applySyncFrame(
        _makeFrame(
          frameSeq: 1,
          totalScrollbackRows: 300,
          pushedScrollbackStartRow: 298,
          pushedScrollbackRowCount: 2,
          pushedScrollbackPayload: encodeTcg1PlainTextRows(
            const <String>['sb-298', 'sb-299'],
            cols: 40,
          ),
          viewportPayload: encodeTcg1PlainTextRows(
            const <String>['vp-0'],
            cols: 40,
          ),
        ),
      );

      expect(buf.totalScrollbackRows, 300);
      expect(buf.totalLines, 304);
      expect(buf.lineAtVirtualRow(298)?.toPlainText(), 'sb-298');
      expect(buf.lineAtVirtualRow(299)?.toPlainText(), 'sb-299');
      expect(buf.lineAtVirtualRow(300)?.toPlainText(), 'vp-0');
      expect(buf.lineAtVirtualRow(0), isNull);

      // Missing ranges in [0..299]: pages 0..127 and 128..255 coalesce to
      // (0, 256), and bucket 256..299 still has unloaded rows 256..297 -> (256, 44).
      final missing = buf.missingScrollbackRanges(0, 299);
      expect(missing, const <(int, int)>[(0, 256), (256, 44)]);
    });

    test(
      'keeps cached scrollback pages alignment-invariant across trimmedTopRows retention',
      () {
        final buf = TerminalCellBuffer(cols: 40, rows: 4);
        buf.applySyncFrame(
          _makeFrame(frameSeq: 1, totalScrollbackRows: 400, trimmedTopRows: 0),
        );

        // Populate absolute page 1 (rows 128..255 at trimmedTopRows = 0).
        final lines128To255 = List<String>.generate(
          kScrollbackPageSize,
          (i) => 'abs-${128 + i}',
        );
        expect(
          buf.applyFetchedRows(
            TerminalRowsPageData(
              sessionId: 's1',
              startRow: 128,
              rowCount: kScrollbackPageSize,
              totalScrollbackRows: 400,
              trimmedTopRows: 0,
              eraseScrollbackGen: 0,
              compression: kCellCompressionNone,
              payload: encodeTcg1PlainTextRows(lines128To255, cols: 40),
            ),
          ),
          isTrue,
        );
        expect(buf.lineAtVirtualRow(150)?.toPlainText(), 'abs-150');

        // Daemon trims 50 oldest rows from the top (trimmedTopRows: 50,
        // totalScrollbackRows: 350). Absolute row 150 is now virtual row 100,
        // and must remain resident without re-fetching!
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 2,
            totalScrollbackRows: 350,
            trimmedTopRows: 50,
            modeFlags: kModeCursorVisible | kModeAutoWrap,
          ),
        );
        expect(buf.lineAtVirtualRow(100)?.toPlainText(), 'abs-150');
      },
    );

    test(
      'evicts oldest LRU pages beyond kMaxResidentScrollbackPages while protecting visible range',
      () {
        const totalPages = kMaxResidentScrollbackPages + 6;
        const totalSb = totalPages * kScrollbackPageSize;
        final buf = TerminalCellBuffer(cols: 20, rows: 4);
        buf.applySyncFrame(
          _makeFrame(frameSeq: 1, cols: 20, totalScrollbackRows: totalSb),
        );

        for (var p = 0; p < totalPages; p++) {
          final start = p * kScrollbackPageSize;
          buf.applyFetchedRows(
            TerminalRowsPageData(
              sessionId: 's1',
              startRow: start,
              rowCount: 1,
              totalScrollbackRows: totalSb,
              trimmedTopRows: 0,
              eraseScrollbackGen: 0,
              compression: kCellCompressionNone,
              payload: encodeTcg1PlainTextRows(
                <String>['page-$p'],
                cols: 20,
              ),
            ),
            // Protect page 0 as the visible viewport while paging later blocks.
            protectFirstVirtualRow: 0,
            protectLastVirtualRow: 10,
          );
        }

        expect(buf.residentScrollbackPageCount, kMaxResidentScrollbackPages);
        // Page 0 was protected and must still be resident.
        expect(buf.lineAtVirtualRow(0)?.toPlainText(), 'page-0');
        // Unprotected oldest pages (1..6) were evicted; newest page is resident.
        expect(buf.lineAtVirtualRow(kScrollbackPageSize), isNull);
        expect(
          buf.lineAtVirtualRow((totalPages - 1) * kScrollbackPageSize)?.toPlainText(),
          'page-${totalPages - 1}',
        );
      },
    );

    test(
      'column resize invalidates reflow window pages while preserving archived journal pages',
      () {
        const totalSb = 5000;
        final buf = TerminalCellBuffer(cols: 80, rows: 24);
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 1,
            cols: 80,
            rows: 24,
            totalScrollbackRows: totalSb,
          ),
        );

        // Cache an old archived page at row 0 (< 5000 - 3600 = 1400) and a
        // tail page inside the reflow window at row 4864.
        for (final start in const <int>[0, 4864]) {
          buf.applyFetchedRows(
            TerminalRowsPageData(
              sessionId: 's1',
              startRow: start,
              rowCount: 1,
              totalScrollbackRows: totalSb,
              trimmedTopRows: 0,
              eraseScrollbackGen: 0,
              compression: kCellCompressionNone,
              payload: encodeTcg1PlainTextRows(
                <String>['row-$start'],
                cols: 80,
              ),
            ),
          );
        }
        expect(buf.lineAtVirtualRow(0)?.toPlainText(), 'row-0');
        expect(buf.lineAtVirtualRow(4864)?.toPlainText(), 'row-4864');

        // Resize to 120 cols: row 0 stays cached, row 4864 is invalidated.
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 2,
            cols: 120,
            rows: 24,
            totalScrollbackRows: totalSb,
          ),
        );
        expect(buf.lineAtVirtualRow(0)?.toPlainText(), 'row-0');
        expect(buf.lineAtVirtualRow(4864), isNull);
      },
    );

    test(
      'eraseScrollbackGen bump clears scrollback cache and discards stale in-flight pages',
      () {
        final buf = TerminalCellBuffer(cols: 40, rows: 4);
        buf.applySyncFrame(
          _makeFrame(frameSeq: 1, totalScrollbackRows: 200, eraseScrollbackGen: 1),
        );
        expect(
          buf.applyFetchedRows(
            TerminalRowsPageData(
              sessionId: 's1',
              startRow: 0,
              rowCount: 1,
              totalScrollbackRows: 200,
              trimmedTopRows: 0,
              eraseScrollbackGen: 1,
              compression: kCellCompressionNone,
              payload: encodeTcg1PlainTextRows(const <String>['pre-clear'], cols: 40),
            ),
          ),
          isTrue,
        );
        expect(buf.lineAtVirtualRow(0)?.toPlainText(), 'pre-clear');

        // CSI 3J increments eraseScrollbackGen to 2.
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 2,
            totalScrollbackRows: 0,
            eraseScrollbackGen: 2,
            modeFlags:
                kModeCursorVisible |
                kModeFullViewport |
                kModeSawEraseScrollback,
          ),
        );
        expect(buf.totalScrollbackRows, 0);
        expect(buf.residentScrollbackPageCount, 0);

        // Stale response with eraseScrollbackGen == 1 is rejected.
        expect(
          buf.applyFetchedRows(
            TerminalRowsPageData(
              sessionId: 's1',
              startRow: 0,
              rowCount: 1,
              totalScrollbackRows: 200,
              trimmedTopRows: 0,
              eraseScrollbackGen: 1,
              compression: kCellCompressionNone,
              payload: encodeTcg1PlainTextRows(const <String>['stale'], cols: 40),
            ),
          ),
          isFalse,
        );
        expect(buf.totalScrollbackRows, 0);
      },
    );

    test('alt-screen hides primary scrollback while active and restores it on exit', () {
      final buf = TerminalCellBuffer(cols: 40, rows: 4);
      buf.applySyncFrame(
        _makeFrame(frameSeq: 1, totalScrollbackRows: 120),
      );
      expect(buf.totalScrollbackRows, 120);

      buf.applySyncFrame(
        _makeFrame(
          frameSeq: 2,
          totalScrollbackRows: 0,
          modeFlags: kModeAltScreen | kModeCursorVisible | kModeFullViewport,
        ),
      );
      expect(buf.isUsingAltBuffer, isTrue);
      expect(buf.totalScrollbackRows, 0);
      expect(buf.missingScrollbackRanges(0, 50), isEmpty);

      buf.applySyncFrame(
        _makeFrame(
          frameSeq: 3,
          totalScrollbackRows: 120,
          modeFlags: kModeCursorVisible | kModeFullViewport,
        ),
      );
      expect(buf.isUsingAltBuffer, isFalse);
      expect(buf.totalScrollbackRows, 120);
    });
  });
}
