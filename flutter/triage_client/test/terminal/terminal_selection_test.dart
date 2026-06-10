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
}
