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
          viewportPayload: encodeTcg1PlainTextRows(const <String>[
            'row 0',
            'row 1',
            'row 2',
            'row 3',
          ], cols: 40),
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
          pushedScrollbackPayload: encodeTcg1PlainTextRows(const <String>[
            'sb-298',
            'sb-299',
          ], cols: 40),
          viewportPayload: encodeTcg1PlainTextRows(const <String>[
            'vp-0',
          ], cols: 40),
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
              payload: encodeTcg1PlainTextRows(<String>['page-$p'], cols: 20),
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
          buf
              .lineAtVirtualRow((totalPages - 1) * kScrollbackPageSize)
              ?.toPlainText(),
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
              payload: encodeTcg1PlainTextRows(<String>[
                'row-$start',
              ], cols: 80),
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
          _makeFrame(
            frameSeq: 1,
            totalScrollbackRows: 200,
            eraseScrollbackGen: 1,
          ),
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
              payload: encodeTcg1PlainTextRows(const <String>[
                'pre-clear',
              ], cols: 40),
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
              payload: encodeTcg1PlainTextRows(const <String>[
                'stale',
              ], cols: 40),
            ),
          ),
          isFalse,
        );
        expect(buf.totalScrollbackRows, 0);
      },
    );

    test(
      'alt-screen hides primary scrollback while active and restores it on exit',
      () {
        final buf = TerminalCellBuffer(cols: 40, rows: 4);
        buf.applySyncFrame(_makeFrame(frameSeq: 1, totalScrollbackRows: 120));
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
      },
    );

    test(
      'applySyncFrame rejects corrupted totalScrollbackRows < pushedEnd',
      () {
        final buf = TerminalCellBuffer(cols: 40, rows: 4);
        final pushedPayload = encodeTcg1PlainTextRows(const <String>[
          'sb0',
          'sb1',
          'sb2',
        ], cols: 40);
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 1,
            totalScrollbackRows: 2, // less than 0 + 3
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 3,
            pushedScrollbackPayload: pushedPayload,
          ),
        );
        expect(buf.lastFrameSeq, 0);
        expect(buf.totalScrollbackRows, 0);
      },
    );

    test(
      'expectedReflowGen rejects stale fetched pages across resize reflows',
      () {
        final buf = TerminalCellBuffer(cols: 80, rows: 4);
        buf.applySyncFrame(
          _makeFrame(frameSeq: 1, cols: 80, rows: 4, totalScrollbackRows: 200),
        );
        final genBeforeReflow = buf.reflowGen;

        // Local resize clamps cursor without bumping reflowGen.
        buf.resize(60, 4, 600, 80);
        expect(buf.reflowGen, genBeforeReflow);

        // Server-confirmed width changes 80 -> 120 -> 80 bump reflowGen twice.
        buf.applySyncFrame(
          _makeFrame(frameSeq: 2, cols: 120, rows: 4, totalScrollbackRows: 150),
        );
        buf.applySyncFrame(
          _makeFrame(frameSeq: 3, cols: 80, rows: 4, totalScrollbackRows: 200),
        );
        expect(buf.reflowGen, greaterThan(genBeforeReflow));

        final stalePage = TerminalRowsPageData(
          sessionId: 's1',
          startRow: 0,
          rowCount: 1,
          totalScrollbackRows: 200,
          trimmedTopRows: 0,
          eraseScrollbackGen: 0,
          compression: kCellCompressionNone,
          payload: encodeTcg1PlainTextRows(const <String>[
            'stale-80',
          ], cols: 80),
        );
        expect(
          buf.applyFetchedRows(stalePage, expectedReflowGen: genBeforeReflow),
          isFalse,
        );
        expect(buf.lineAtVirtualRow(0), isNull);

        expect(
          buf.applyFetchedRows(stalePage, expectedReflowGen: buf.reflowGen),
          isTrue,
        );
        expect(buf.lineAtVirtualRow(0)?.toPlainText(), 'stale-80');
      },
    );

    test(
      'missingScrollbackRanges scans past row 0 in partially populated page',
      () {
        final buf = TerminalCellBuffer(cols: 40, rows: 4);
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 1,
            cols: 40,
            rows: 4,
            totalScrollbackRows: 100,
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 1,
            pushedScrollbackPayload: encodeTcg1PlainTextRows(const <String>[
              'only-row-zero',
            ], cols: 40),
          ),
        );
        expect(buf.lineAtVirtualRow(0)?.toPlainText(), 'only-row-zero');
        expect(buf.lineAtVirtualRow(1), isNull);
        final missing = buf.missingScrollbackRanges(0, 99);
        expect(missing, isNotEmpty);
        expect(missing.first, (0, 100));
      },
    );

    test(
      'preserves combining space, invalidates pages across height grow and alt resize, and accepts wide journal rows',
      () {
        // Space with combining acute accent must not be trimmed as trailing blank.
        final spaceComb = encodeTcg1PlainTextRows(const <String>[
          'a \u0301',
        ], cols: 4);
        final spaceLine = TerminalCellLine.fromDecoded(
          decodeTcg1Batch(kCellCompressionNone, spaceComb).single,
        );
        expect(spaceLine.toPlainText(), 'a \u0301');

        final buf = TerminalCellBuffer(cols: 80, rows: 10);
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 1,
            cols: 80,
            rows: 10,
            totalScrollbackRows: 20,
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 20,
            pushedScrollbackPayload: encodeTcg1PlainTextRows(
              List<String>.generate(20, (i) => 'sb-$i'),
              cols: 80,
            ),
          ),
        );
        final gen0 = buf.reflowGen;

        // Height growth pulls 10 scrollback rows back into viewport: bumps reflowGen.
        buf.applySyncFrame(
          _makeFrame(frameSeq: 2, cols: 80, rows: 20, totalScrollbackRows: 10),
        );
        expect(buf.reflowGen, greaterThan(gen0));
        final genAfterHeightGrow = buf.reflowGen;

        // Alt-screen column resize (80 -> 40 -> 80 while in alt) bumps reflowGen on return.
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 3,
            cols: 40,
            rows: 20,
            totalScrollbackRows: 0,
            modeFlags: kModeAltScreen | kModeCursorVisible | kModeFullViewport,
          ),
        );
        buf.applySyncFrame(
          _makeFrame(frameSeq: 4, cols: 80, rows: 20, totalScrollbackRows: 10),
        );
        expect(buf.reflowGen, greaterThan(genAfterHeightGrow));

        // Stale pre-narrow 80-col live-grid row (storedCols 28 < logicalCols 80) is rejected,
        // while archived SGR journal row wider than current narrow width (storedCols == logicalCols == 55 > 40) is accepted.
        buf.applySyncFrame(
          _makeFrame(frameSeq: 5, cols: 40, rows: 20, totalScrollbackRows: 10),
        );
        final stalePreNarrowPage = TerminalRowsPageData(
          sessionId: 's1',
          startRow: 0,
          rowCount: 1,
          totalScrollbackRows: 10,
          trimmedTopRows: 0,
          eraseScrollbackGen: 0,
          compression: kCellCompressionNone,
          payload: encodeTcg1PlainTextRows(const <String>[
            'stale-pre-narrow-live-row',
          ], cols: 80),
        );
        expect(buf.applyFetchedRows(stalePreNarrowPage), isFalse);

        const archivedWideLine =
            'archived-journal-line-wider-than-forty-narrow-columns!!';
        final wideJournalPage = TerminalRowsPageData(
          sessionId: 's1',
          startRow: 0,
          rowCount: 1,
          totalScrollbackRows: 10,
          trimmedTopRows: 0,
          eraseScrollbackGen: 0,
          compression: kCellCompressionNone,
          payload: encodeTcg1PlainTextRows(const <String>[
            archivedWideLine,
          ], cols: archivedWideLine.length),
        );
        expect(
          buf.applyFetchedRows(
            wideJournalPage,
            expectedReflowGen: buf.reflowGen,
          ),
          isTrue,
        );
        expect(buf.lineAtVirtualRow(0)?.toPlainText(), archivedWideLine);

        // Empty page with advanced trimmedTopRows adjusts totalScrollbackRows by trimDelta.
        final emptyTrimmedPage = TerminalRowsPageData(
          sessionId: 's1',
          startRow: 0,
          rowCount: 0,
          totalScrollbackRows: 0,
          trimmedTopRows: 3,
          eraseScrollbackGen: 0,
          compression: kCellCompressionNone,
          payload: Uint8List(0),
        );
        buf.applyFetchedRows(
          emptyTrimmedPage,
          expectedReflowGen: buf.reflowGen,
        );
        expect(buf.trimmedTopRows, 3);
        expect(buf.totalScrollbackRows, 7);

        // eraseScrollbackGen bump during alt-screen entry clears primary scrollback metadata.
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 6,
            cols: 40,
            rows: 20,
            totalScrollbackRows: 0,
            eraseScrollbackGen: 1,
            modeFlags: kModeAltScreen | kModeCursorVisible | kModeFullViewport,
          ),
        );
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 7,
            cols: 40,
            rows: 20,
            totalScrollbackRows: 0,
            eraseScrollbackGen: 1,
          ),
        );
        expect(buf.trimmedTopRows, 0);
        expect(buf.totalScrollbackRows, 0);
      },
    );

    test(
      'applies pushed scrollback across sawEraseDisplay, invalidates alt-screen col resize, and resets trimmedTopRows on erase gen change',
      () {
        final buf = TerminalCellBuffer(cols: 40, rows: 4);

        // Seed 6 scrollback rows with trimmedTopRows = 4 and missing gaps at [0..2) and [4..6).
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 1,
            cols: 40,
            rows: 4,
            totalScrollbackRows: 6,
            trimmedTopRows: 4,
            pushedScrollbackStartRow: 2,
            pushedScrollbackRowCount: 2,
            pushedScrollbackPayload: encodeTcg1PlainTextRows(const <String>[
              'sb-2',
              'sb-3',
            ], cols: 40),
          ),
        );
        expect(buf.trimmedTopRows, 4);
        final ranges = buf.missingScrollbackRanges(0, 5);
        expect(ranges, const <(int, int)>[(0, 6)]);

        // Boundary pushed scrollback on a `sawEraseDisplay` (`CSI 2J`) frame is retained.
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 2,
            cols: 40,
            rows: 4,
            totalScrollbackRows: 7,
            trimmedTopRows: 4,
            modeFlags:
                kModeCursorVisible |
                kModeAutoWrap |
                kModeFullViewport |
                kModeSawEraseDisplay,
            pushedScrollbackStartRow: 6,
            pushedScrollbackRowCount: 1,
            pushedScrollbackPayload: encodeTcg1PlainTextRows(const <String>[
              'fresh-6',
            ], cols: 40),
          ),
        );
        expect(buf.lineAtVirtualRow(6)?.toPlainText(), 'fresh-6');

        // Enter alt screen at 40 cols, resize alt screen to 20 cols and back to 40 cols:
        // `_sawAltColResize` invalidates stale primary scrollback cache pages on return.
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 3,
            cols: 40,
            rows: 4,
            totalScrollbackRows: 0,
            modeFlags: kModeAltScreen | kModeCursorVisible | kModeFullViewport,
          ),
        );
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 4,
            cols: 20,
            rows: 4,
            totalScrollbackRows: 0,
            modeFlags: kModeAltScreen | kModeCursorVisible | kModeFullViewport,
          ),
        );
        buf.applySyncFrame(
          _makeFrame(
            frameSeq: 5,
            cols: 40,
            rows: 4,
            totalScrollbackRows: 7,
            trimmedTopRows: 4,
            modeFlags: kModeCursorVisible | kModeAutoWrap | kModeFullViewport,
          ),
        );
        expect(buf.lineAtVirtualRow(6), isNull);

        // Erase scrollback (`CSI 3J`) when `totalScrollbackRows == 0` still resets `trimmedTopRows` to 0.
        final zeroScrollBuf = TerminalCellBuffer(cols: 40, rows: 4);
        zeroScrollBuf.applySyncFrame(
          _makeFrame(
            frameSeq: 1,
            cols: 40,
            rows: 4,
            totalScrollbackRows: 0,
            trimmedTopRows: 9,
            eraseScrollbackGen: 0,
          ),
        );
        expect(zeroScrollBuf.trimmedTopRows, 9);
        zeroScrollBuf.applySyncFrame(
          _makeFrame(
            frameSeq: 2,
            cols: 40,
            rows: 4,
            totalScrollbackRows: 0,
            trimmedTopRows: 0,
            eraseScrollbackGen: 1,
          ),
        );
        expect(zeroScrollBuf.trimmedTopRows, 0);
      },
    );
  });
}
