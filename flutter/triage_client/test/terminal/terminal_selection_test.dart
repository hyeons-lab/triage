import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_selection.dart';
import 'package:xterm/xterm.dart' as xt;

// Builds a single buffer line of [width] cells from a compact spec: each entry
// is either a single-character glyph or `null` for a blank (codePoint 0) cell —
// the same state a program leaves behind when it moves the cursor over a gap
// instead of writing a literal space.
xt.BufferLine _line(List<String?> cells, {int? width, bool isWrapped = false}) {
  final line = xt.BufferLine(width ?? cells.length, isWrapped: isWrapped);
  for (var i = 0; i < cells.length; i++) {
    final cell = cells[i];
    if (cell != null) {
      line.setCodePoint(i, cell.runes.first);
    }
  }
  return line;
}

void main() {
  group('bufferLineSelectedText', () {
    test('turns interior blank cells into spaces', () {
      // "AB" then a 3-cell cursor-move gap then "CD".
      final line = _line(['A', 'B', null, null, null, 'C', 'D']);
      expect(bufferLineSelectedText(line, 0, line.length), 'AB   CD');
    });

    test('drops trailing blank cells instead of padding to width', () {
      final line = _line(['A', 'B', null, null, null], width: 10);
      expect(bufferLineSelectedText(line, 0, line.length), 'AB');
    });

    test('preserves literal spaces, including trailing ones', () {
      // A literal space is codePoint 0x20, not a blank cell, so it survives.
      final line = _line(['A', ' ', 'B', ' ', ' '], width: 8);
      expect(bufferLineSelectedText(line, 0, line.length), 'A B  ');
    });

    test('does not add a stray space after a wide (CJK) glyph', () {
      // '世' occupies two cells; its trailing half is a codePoint-0 cell that
      // must not be mistaken for a gap.
      final line = _line(['A', '世', null, 'B']);
      expect(bufferLineSelectedText(line, 0, line.length), 'A世B');
    });

    test('fills a gap that sits before a wide glyph', () {
      final line = _line(['A', null, '世', null, 'B']);
      expect(bufferLineSelectedText(line, 0, line.length), 'A 世B');
    });

    test('honors a half-open sub-range', () {
      final line = _line(['A', 'B', null, 'C', 'D']);
      // Columns [1, 4): 'B', a gap, 'C'.
      expect(bufferLineSelectedText(line, 1, 4), 'B C');
    });

    test('drops a wide glyph whose trailing half is outside the range', () {
      // Mirrors Buffer.getText: a wide glyph straddling `to` is not emitted.
      final line = _line(['A', '世', null, 'B']);
      expect(bufferLineSelectedText(line, 0, 2), 'A');
    });
  });

  group('terminalSelectionText', () {
    // The visible top row maps to this absolute buffer line.
    int topRow(xt.Terminal t) => t.buffer.height - t.viewHeight;

    test('restores spaces a cursor-move gap left behind', () {
      final terminal = xt.Terminal(maxLines: 100);
      terminal.resize(20, 5);
      // "AB", move the cursor 3 columns right, then "CD" — the gap cells stay
      // blank, exactly how a TUI lays out columns.
      terminal.write('AB\x1b[3CCD');

      final row = topRow(terminal);
      final range = xt.BufferRangeLine(
        xt.CellOffset(0, row),
        xt.CellOffset(terminal.viewWidth, row),
      );
      expect(terminalSelectionText(terminal.buffer, range), 'AB   CD');
    });

    test('joins selected rows with newlines', () {
      final terminal = xt.Terminal(maxLines: 100);
      terminal.resize(20, 5);
      terminal.write('A\x1b[2CB\r\nC\x1b[2CD');

      final row = topRow(terminal);
      final range = xt.BufferRangeLine(
        xt.CellOffset(0, row),
        xt.CellOffset(terminal.viewWidth, row + 1),
      );
      expect(terminalSelectionText(terminal.buffer, range), 'A  B\nC  D');
    });
  });

  group('resolveSelectionEndpoints', () {
    test(
      'forward and backward selections over the same cells produce identical text',
      () {
        final terminal = xt.Terminal(maxLines: 100);
        terminal.resize(20, 5);
        terminal.write('hello world\r\nsecond line');
        final top = terminal.buffer.height - terminal.viewHeight;

        final forward = resolveSelectionEndpoints(
          anchorCell: xt.CellOffset(2, top),
          targetCell: xt.CellOffset(8, top + 1),
          viewWidth: terminal.viewWidth,
          lineCount: terminal.buffer.lines.length,
        )!;
        final backward = resolveSelectionEndpoints(
          anchorCell: xt.CellOffset(8, top + 1),
          targetCell: xt.CellOffset(2, top),
          viewWidth: terminal.viewWidth,
          lineCount: terminal.buffer.lines.length,
        )!;

        final forwardText = terminalSelectionText(
          terminal.buffer,
          xt.BufferRangeLine(forward.$1, forward.$2),
        );
        final backwardText = terminalSelectionText(
          terminal.buffer,
          xt.BufferRangeLine(backward.$1, backward.$2),
        );

        expect(forwardText, 'llo world\nsecond li');
        expect(backwardText, forwardText);
      },
    );

    test('backward single-line selection includes the anchor cell', () {
      final terminal = xt.Terminal(maxLines: 100);
      terminal.resize(20, 5);
      terminal.write('abcdef');
      final top = terminal.buffer.height - terminal.viewHeight;

      final backward = resolveSelectionEndpoints(
        anchorCell: xt.CellOffset(4, top),
        targetCell: xt.CellOffset(1, top),
        viewWidth: terminal.viewWidth,
        lineCount: terminal.buffer.lines.length,
      )!;
      final text = terminalSelectionText(
        terminal.buffer,
        xt.BufferRangeLine(backward.$1, backward.$2),
      );
      expect(text, 'bcde');
    });

    test(
      'backward multi-line selection at right margin creates valid buffer anchors and includes rightmost cell',
      () {
        final terminal = xt.Terminal(maxLines: 100);
        terminal.resize(10, 5);
        terminal.write('0123456789\r\nabcdefghij');
        final top = terminal.buffer.height - terminal.viewHeight;

        final backward = resolveSelectionEndpoints(
          anchorCell: xt.CellOffset(terminal.viewWidth - 1, top + 1),
          targetCell: xt.CellOffset(terminal.viewWidth - 1, top),
          viewWidth: terminal.viewWidth,
          lineCount: terminal.buffer.lines.length,
        )!;
        final baseAnchor = terminal.buffer.createAnchorFromOffset(backward.$1);
        final extentAnchor = terminal.buffer.createAnchorFromOffset(
          backward.$2,
        );
        expect(baseAnchor.x, terminal.viewWidth);
        expect(extentAnchor.x, terminal.viewWidth - 1);

        final text = terminalSelectionText(
          terminal.buffer,
          xt.BufferRangeLine(backward.$1, backward.$2),
        );
        expect(text, '9\nabcdefghij');
      },
    );
  });

  group('shiftCellOffsetForHistoryPage', () {
    test('shifts row by addedLines and clamps to lineCount - 1', () {
      expect(
        shiftCellOffsetForHistoryPage(
          offset: const xt.CellOffset(5, 10),
          addedLines: 25,
          lineCount: 101,
        ),
        const xt.CellOffset(5, 35),
      );
      expect(
        shiftCellOffsetForHistoryPage(
          offset: const xt.CellOffset(5, 90),
          addedLines: 25,
          lineCount: 101,
        ),
        const xt.CellOffset(5, 100),
      );
    });

    test('preserves cell offset unchanged when addedLines is 0', () {
      expect(
        shiftCellOffsetForHistoryPage(
          offset: const xt.CellOffset(7, 42),
          addedLines: 0,
          lineCount: 100,
        ),
        const xt.CellOffset(7, 42),
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
  });
}
