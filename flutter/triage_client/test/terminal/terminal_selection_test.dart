import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';
import 'package:triage_client/terminal/terminal_selection.dart';

// Builds a single cell line of [width] cells from a compact spec: each entry
// is either a single-character glyph or `null` for an unwritten blank
// (codePoint 0) cell, matching the state a TUI leaves behind when moving the
// cursor across a gap instead of writing literal spaces.
TerminalCellLine _line(
  List<String?> cells, {
  int? width,
  bool isWrapped = false,
}) {
  return TerminalCellLine.fromSpec(cells, width: width, wrapsNext: isWrapped);
}

TerminalCellLine _textLine(
  String text, {
  int width = 20,
  bool wrapsNext = false,
}) {
  return TerminalCellLine.fromSpec(
    <String?>[for (final r in text.runes) String.fromCharCode(r)],
    width: width,
    wrapsNext: wrapsNext,
  );
}

void main() {
  group('bufferLineSelectedText', () {
    test('turns interior blank cells into spaces', () {
      final line = _line(['A', 'B', null, null, null, 'C', 'D']);
      expect(bufferLineSelectedText(line, 0, line.length), 'AB   CD');
    });

    test('drops trailing blank cells instead of padding to width', () {
      final line = _line(['A', 'B', null, null, null], width: 10);
      expect(bufferLineSelectedText(line, 0, line.length), 'AB');
    });

    test('preserves literal spaces, including trailing ones', () {
      final line = _line(['A', ' ', 'B', ' ', ' '], width: 8);
      expect(bufferLineSelectedText(line, 0, line.length), 'A B  ');
    });

    test('does not add a stray space after a wide (CJK) glyph', () {
      final line = _line(['A', '世', null, 'B']);
      expect(bufferLineSelectedText(line, 0, line.length), 'A世B');
    });

    test('fills a gap that sits before a wide glyph', () {
      final line = _line(['A', null, '世', null, 'B']);
      expect(bufferLineSelectedText(line, 0, line.length), 'A 世B');
    });

    test('honors a half-open sub-range', () {
      final line = _line(['A', 'B', null, 'C', 'D']);
      expect(bufferLineSelectedText(line, 1, 4), 'B C');
    });

    test('drops a wide glyph whose trailing half is outside the range', () {
      final line = _line(['A', '世', null, 'B']);
      expect(bufferLineSelectedText(line, 0, 2), 'A');
    });
  });

  group('terminalSelectionText', () {
    test('restores spaces a cursor-move gap left behind', () {
      final buffer = TerminalCellBuffer(cols: 20, rows: 5);
      buffer.seedLinesForTest(
        cols: 20,
        rows: 5,
        viewport: <TerminalCellLine>[
          _line(['A', 'B', null, null, null, 'C', 'D'], width: 20),
        ],
      );

      final range = TerminalSelectionRange(
        const CellOffset(0, 0),
        CellOffset(buffer.viewWidth, 0),
      );
      expect(terminalSelectionText(buffer, range), 'AB   CD');
    });

    test(
      'joins hard-broken rows with newlines and suppresses soft-wrap newlines',
      () {
        final buffer = TerminalCellBuffer(cols: 20, rows: 5);
        buffer.seedLinesForTest(
          cols: 20,
          rows: 5,
          viewport: <TerminalCellLine>[
            _line(['A', null, null, 'B'], width: 20),
            _line(['C', null, null, 'D'], width: 20, isWrapped: true),
            _line(['E', 'F'], width: 20),
          ],
        );

        final range = TerminalSelectionRange(
          const CellOffset(0, 0),
          CellOffset(buffer.viewWidth, 2),
        );
        expect(terminalSelectionText(buffer, range), 'A  B\nC  DEF');
      },
    );

    test('compensates for top retention trims via trimmedTopRows', () {
      final buffer = TerminalCellBuffer(cols: 20, rows: 2);
      buffer.seedLinesForTest(
        cols: 20,
        rows: 2,
        scrollback: <TerminalCellLine>[
          _textLine('row 0'),
          _textLine('row 1'),
          _textLine('row 2'),
        ],
        viewport: <TerminalCellLine>[_textLine('row 3'), _textLine('row 4')],
      );

      final range = TerminalSelectionRange(
        const CellOffset(0, 2),
        const CellOffset(5, 2),
        trimmedTopRows: buffer.trimmedTopRows,
        eraseScrollbackGen: buffer.eraseScrollbackGen,
      );
      expect(terminalSelectionText(buffer, range), 'row 2');

      // Append a new line with maxTotalLines=5 so 1 top line is trimmed and
      // 'row 2' shifts from virtual row 2 to virtual row 1.
      buffer.appendOutputLineForTest(_textLine('row 5'), maxTotalLines: 5);
      expect(buffer.trimmedTopRows, 1);
      expect(terminalSelectionIsLive(buffer, range), isTrue);
      expect(terminalSelectionText(buffer, range), 'row 2');
    });
  });

  group('resolveSelectionEndpoints', () {
    test(
      'forward and backward selections over the same cells produce identical text',
      () {
        final buffer = TerminalCellBuffer(cols: 20, rows: 5);
        buffer.seedLinesForTest(
          cols: 20,
          rows: 5,
          viewport: <TerminalCellLine>[
            _textLine('hello world'),
            _textLine('second line'),
          ],
        );

        final forward = resolveSelectionEndpoints(
          anchorCell: const CellOffset(2, 0),
          targetCell: const CellOffset(8, 1),
          viewWidth: buffer.viewWidth,
          lineCount: buffer.totalLines,
        )!;
        final backward = resolveSelectionEndpoints(
          anchorCell: const CellOffset(8, 1),
          targetCell: const CellOffset(2, 0),
          viewWidth: buffer.viewWidth,
          lineCount: buffer.totalLines,
        )!;

        final forwardText = terminalSelectionText(
          buffer,
          TerminalSelectionRange(forward.$1, forward.$2),
        );
        final backwardText = terminalSelectionText(
          buffer,
          TerminalSelectionRange(backward.$1, backward.$2),
        );

        expect(forwardText, 'llo world\nsecond li');
        expect(backwardText, forwardText);
      },
    );

    test('backward single-line selection includes the anchor cell', () {
      final buffer = TerminalCellBuffer(cols: 20, rows: 5);
      buffer.seedLinesForTest(
        cols: 20,
        rows: 5,
        viewport: <TerminalCellLine>[_textLine('abcdef')],
      );

      final backward = resolveSelectionEndpoints(
        anchorCell: const CellOffset(4, 0),
        targetCell: const CellOffset(1, 0),
        viewWidth: buffer.viewWidth,
        lineCount: buffer.totalLines,
      )!;
      final text = terminalSelectionText(
        buffer,
        TerminalSelectionRange(backward.$1, backward.$2),
      );
      expect(text, 'bcde');
    });

    test(
      'backward multi-line selection at right margin includes rightmost cell',
      () {
        final buffer = TerminalCellBuffer(cols: 10, rows: 5);
        buffer.seedLinesForTest(
          cols: 10,
          rows: 5,
          viewport: <TerminalCellLine>[
            _textLine('0123456789', width: 10),
            _textLine('abcdefghij', width: 10),
          ],
        );

        final backward = resolveSelectionEndpoints(
          anchorCell: CellOffset(buffer.viewWidth - 1, 1),
          targetCell: CellOffset(buffer.viewWidth - 1, 0),
          viewWidth: buffer.viewWidth,
          lineCount: buffer.totalLines,
        )!;
        expect(backward.$1.x, buffer.viewWidth);
        expect(backward.$2.x, buffer.viewWidth - 1);

        final text = terminalSelectionText(
          buffer,
          TerminalSelectionRange(backward.$1, backward.$2),
        );
        expect(text, '9\nabcdefghij');
      },
    );
  });

  group('selectWordRangeAt', () {
    test('selects identifier/path token around clicked cell', () {
      final buffer = TerminalCellBuffer(cols: 30, rows: 2);
      buffer.seedLinesForTest(
        cols: 30,
        rows: 2,
        viewport: <TerminalCellLine>[
          _textLine('run /usr/local/bin/triaged --ok', width: 30),
        ],
      );

      final range = selectWordRangeAt(buffer, const CellOffset(8, 0))!;
      expect(terminalSelectionText(buffer, range), '/usr/local/bin/triaged');
    });

    test('snaps trailing cell of wide CJK glyph to the leading cell', () {
      final buffer = TerminalCellBuffer(cols: 10, rows: 2);
      buffer.seedLinesForTest(
        cols: 10,
        rows: 2,
        viewport: <TerminalCellLine>[
          _line([' ', '世', null, '界', null, ' '], width: 10),
        ],
      );

      final range = selectWordRangeAt(buffer, const CellOffset(2, 0))!;
      expect(terminalSelectionText(buffer, range), '世界');
    });
  });

  group('shiftCellOffsetForHistoryPage', () {
    test('shifts row by addedLines and clamps to lineCount - 1', () {
      expect(
        shiftCellOffsetForHistoryPage(
          offset: const CellOffset(5, 10),
          addedLines: 25,
          lineCount: 101,
        ),
        const CellOffset(5, 35),
      );
      expect(
        shiftCellOffsetForHistoryPage(
          offset: const CellOffset(5, 90),
          addedLines: 25,
          lineCount: 101,
        ),
        const CellOffset(5, 100),
      );
    });

    test('preserves cell offset unchanged when addedLines is 0', () {
      expect(
        shiftCellOffsetForHistoryPage(
          offset: const CellOffset(7, 42),
          addedLines: 0,
          lineCount: 100,
        ),
        const CellOffset(7, 42),
      );
    });
  });

  group('isWebSelectAllShortcut', () {
    test(
      'matches Cmd+A without extra modifiers and Ctrl+Shift+A without Meta/Alt',
      () {
        expect(
          isWebSelectAllShortcut(
            key: 'a',
            ctrlKey: false,
            metaKey: true,
            shiftKey: false,
            altKey: false,
          ),
          isTrue,
        );
        expect(
          isWebSelectAllShortcut(
            key: 'A',
            ctrlKey: true,
            metaKey: false,
            shiftKey: true,
            altKey: false,
          ),
          isTrue,
        );
      },
    );

    test('rejects plain Ctrl+A, extra modifiers, and non-A keys', () {
      expect(
        isWebSelectAllShortcut(
          key: 'a',
          ctrlKey: true,
          metaKey: false,
          shiftKey: false,
          altKey: false,
        ),
        isFalse,
      );
      expect(
        isWebSelectAllShortcut(
          key: 'a',
          ctrlKey: false,
          metaKey: true,
          shiftKey: true,
          altKey: false,
        ),
        isFalse,
      );
      expect(
        isWebSelectAllShortcut(
          key: 'a',
          ctrlKey: true,
          metaKey: false,
          shiftKey: true,
          altKey: true,
        ),
        isFalse,
      );
      expect(
        isWebSelectAllShortcut(
          key: 'c',
          ctrlKey: false,
          metaKey: true,
          shiftKey: false,
          altKey: false,
        ),
        isFalse,
      );
    });
  });

  group('shiftWebSelectionForHistoryPage', () {
    test('shifts single-line and multi-line selections by addedLines', () {
      expect(
        shiftWebSelectionForHistoryPage(
          selection: const WebSelectionRange(
            startX: 3,
            startY: 10,
            endX: 15,
            endY: 10,
          ),
          addedLines: 25,
          lineCount: 100,
          cols: 80,
        ),
        (column: 3, row: 35, length: 12),
      );
      expect(
        shiftWebSelectionForHistoryPage(
          selection: const WebSelectionRange(
            startX: 5,
            startY: 10,
            endX: 12,
            endY: 12,
          ),
          addedLines: 20,
          lineCount: 100,
          cols: 80,
        ),
        (column: 5, row: 30, length: 2 * 80 - 5 + 12),
      );
    });

    test('clamps coordinates to buffer bounds and returns null when empty', () {
      expect(
        shiftWebSelectionForHistoryPage(
          selection: const WebSelectionRange(
            startX: -4,
            startY: 90,
            endX: 120,
            endY: 95,
          ),
          addedLines: 20,
          lineCount: 100,
          cols: 80,
        ),
        (column: 0, row: 99, length: 80),
      );
      expect(
        shiftWebSelectionForHistoryPage(
          selection: const WebSelectionRange(
            startX: 10,
            startY: 5,
            endX: 10,
            endY: 5,
          ),
          addedLines: 10,
          lineCount: 100,
          cols: 80,
        ),
        isNull,
      );
      expect(
        shiftWebSelectionForHistoryPage(
          selection: const WebSelectionRange(
            startX: 0,
            startY: 0,
            endX: 5,
            endY: 0,
          ),
          addedLines: 10,
          lineCount: 100,
          cols: 0,
        ),
        isNull,
      );
    });

    test(
      'skips unloaded scrollback holes without blank lines and invalidates across alt-screen',
      () {
        final buffer = TerminalCellBuffer(cols: 20, rows: 2);
        buffer.applySyncFrame(
          TerminalSyncFrameData(
            frameSeq: 1,
            rows: 2,
            cols: 20,
            totalScrollbackRows: 3, // virtual rows 0..2 are unloaded null holes
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
              'vp row 0',
              'vp row 1',
            ], cols: 20),
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 0,
            pushedScrollbackCompression: kCellCompressionNone,
            pushedScrollbackPayload: Uint8List(0),
          ),
        );

        final range = TerminalSelectionRange(
          const CellOffset(0, 0),
          const CellOffset(20, 4),
          trimmedTopRows: buffer.trimmedTopRows,
          eraseScrollbackGen: buffer.eraseScrollbackGen,
          isAltScreen: buffer.isUsingAltBuffer,
        );
        expect(terminalSelectionText(buffer, range), 'vp row 0\nvp row 1');

        // Enter alt-screen: primary-screen selection is no longer live.
        buffer.applySyncFrame(
          TerminalSyncFrameData(
            frameSeq: 2,
            rows: 2,
            cols: 20,
            totalScrollbackRows: 0,
            trimmedTopRows: 0,
            eraseScrollbackGen: 0,
            cursorX: 0,
            cursorY: 0,
            cursorStyle: 2,
            modeFlags: kModeAltScreen | kModeCursorVisible | kModeFullViewport,
            mouseMode: 0,
            mouseReportMode: 0,
            kittyKeyboardFlags: 0,
            title: null,
            viewportCompression: kCellCompressionNone,
            viewportPayload: encodeTcg1PlainTextRows(const <String>[
              'alt 0',
              'alt 1',
            ], cols: 20),
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 0,
            pushedScrollbackCompression: kCellCompressionNone,
            pushedScrollbackPayload: Uint8List(0),
          ),
        );
        expect(terminalSelectionIsLive(buffer, range), isFalse);
        expect(terminalSelectionText(buffer, range), isEmpty);
      },
    );

    test(
      'terminalSelectionIsLive checks bounds and selectWordRangeAt handles Unicode words and wide journal lines',
      () {
        final buffer = TerminalCellBuffer(cols: 10, rows: 2);
        buffer.seedLinesForTest(
          cols: 10,
          rows: 2,
          scrollback: <TerminalCellLine>[
            // Archived SGR journal line wider than current 10-col viewport:
            _textLine('café\u00A0привет\u3000tail_word', width: 28),
          ],
          viewport: <TerminalCellLine>[
            _textLine('row0', width: 10),
            _textLine('row1', width: 10),
          ],
        );

        // Selection completely past buffer.totalLines (3) is not live.
        final belowBuffer = TerminalSelectionRange(
          const CellOffset(0, 5),
          const CellOffset(4, 6),
          trimmedTopRows: 0,
          eraseScrollbackGen: 0,
          isAltScreen: false,
        );
        expect(terminalSelectionIsLive(buffer, belowBuffer), isFalse);

        // Unicode word selection groups Latin accented and Cyrillic words, stops at NBSP / ideographic space,
        // and spans beyond buffer.viewWidth on wide journal rows.
        final latinWord = selectWordRangeAt(buffer, const CellOffset(2, 0));
        expect(latinWord, isNotNull);
        expect(terminalSelectionText(buffer, latinWord!), 'café');

        final nbspRun = selectWordRangeAt(buffer, const CellOffset(4, 0));
        expect(nbspRun, isNotNull);
        expect(nbspRun!.base.x, 4);
        expect(nbspRun.extent.x, 5);

        final cyrillicWord = selectWordRangeAt(buffer, const CellOffset(6, 0));
        expect(cyrillicWord, isNotNull);
        expect(terminalSelectionText(buffer, cyrillicWord!), 'привет');

        final wideTail = selectWordRangeAt(buffer, const CellOffset(14, 0));
        expect(wideTail, isNotNull);
        expect(terminalSelectionText(buffer, wideTail!), 'tail_word');

        // Selection extending past buffer.viewWidth (10) on a wide journal row (28 cols)
        // extracts the full span up to line.length without clamping at viewWidth.
        final wideSpan = TerminalSelectionRange(
          const CellOffset(12, 0),
          const CellOffset(28, 0),
          trimmedTopRows: 0,
          eraseScrollbackGen: 0,
          isAltScreen: false,
        );
        expect(terminalSelectionText(buffer, wideSpan), 'tail_word');

        // Combining marks (`e\u0301`) and ZWJ emoji clusters stay grouped during word selection.
        final clusterBuf = TerminalCellBuffer(cols: 12, rows: 1);
        clusterBuf.seedLinesForTest(
          cols: 12,
          rows: 1,
          scrollback: const <TerminalCellLine>[],
          viewport: <TerminalCellLine>[
            _line(<String?>[
              'c',
              'a',
              'f',
              'e\u0301',
              ' ',
              '\u{1F468}\u{200D}\u{1F4BB}',
              null,
              ' ',
            ], width: 12),
          ],
        );
        final decomposedWord = selectWordRangeAt(
          clusterBuf,
          const CellOffset(3, 0),
        );
        expect(decomposedWord, isNotNull);
        expect(
          terminalSelectionText(clusterBuf, decomposedWord!),
          'cafe\u0301',
        );

        final zwjEmoji = selectWordRangeAt(clusterBuf, const CellOffset(5, 0));
        expect(zwjEmoji, isNotNull);
        expect(
          terminalSelectionText(clusterBuf, zwjEmoji!),
          '\u{1F468}\u{200D}\u{1F4BB}',
        );
      },
    );
  });
}
