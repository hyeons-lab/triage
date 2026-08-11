import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_scroll_anchor.dart';
import 'package:triage_client/terminal/terminal_selection.dart';
import 'package:xterm/xterm.dart' as xt;

/// Drives a real `ESC[3J` through the emulator rather than simulating a trim,
/// so these cover the behaviour the terminal actually produces.
void main() {
  const lineHeight = 10.0;

  xt.Terminal terminalWithScrollback() {
    final terminal = xt.Terminal(maxLines: 100);
    terminal.resize(20, 5);
    for (var i = 0; i < 20; i++) {
      terminal.write('line $i\r\n');
    }
    return terminal;
  }

  group('after a scrollback clear', () {
    test(
      'a trimmed line stays attached but reports a row before the buffer',
      () {
        final terminal = terminalWithScrollback();
        final top = terminal.buffer.lines[0];
        expect(top.attached, isTrue);
        expect(top.index, 0);

        terminal.write('\x1b[3J');

        // The premise the rest of this rests on: xterm deliberately does not
        // detach these, so `attached` cannot be used to spot them.
        expect(top.attached, isTrue);
        expect(
          top.index,
          lessThan(0),
          reason: 'a cleared line sits before the start of the buffer',
        );
      },
    );

    test('surviving lines keep reporting their true row', () {
      final terminal = terminalWithScrollback();
      terminal.write('\x1b[3J');

      // This is what the fork's trimStart fix buys: without it every survivor
      // reads high by the number trimmed.
      for (var row = 0; row < terminal.buffer.lines.length; row++) {
        expect(terminal.buffer.lines[row].index, row);
      }
    });

    test('the scroll anchor releases instead of pinning to the top', () {
      final terminal = terminalWithScrollback();
      final anchor = TerminalScrollAnchor();
      anchor.capture(
        buffer: terminal.buffer,
        pixels: 30,
        maxScrollExtent: 200,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);
      expect(
        anchor.desiredOffset(maxScrollExtent: 200, lineHeight: lineHeight),
        30,
      );

      terminal.write('\x1b[3J');

      // Without the negative-row guard this clamps to 0.0 and pins the viewport
      // to the top of the buffer rather than letting it follow the bottom.
      expect(
        anchor.desiredOffset(maxScrollExtent: 200, lineHeight: lineHeight),
        isNull,
      );
      expect(anchor.hasAnchor, isFalse);
    });

    test('a selection over cleared rows is no longer live', () {
      final terminal = terminalWithScrollback();
      final controller = xt.TerminalController();
      controller.setSelection(
        xt.CellAnchor(0, owner: terminal.buffer.lines[0]),
        xt.CellAnchor(6, owner: terminal.buffer.lines[0]),
      );
      final before = controller.selection;
      expect(before, isNotNull);
      expect(terminalSelectionIsLive(terminal.buffer, before!), isTrue);

      terminal.write('\x1b[3J');

      final after = controller.selection;
      // The controller still offers a range, which is exactly the trap.
      expect(after, isNotNull);
      expect(terminalSelectionIsLive(terminal.buffer, after!), isFalse);
    });

    test('a selection over surviving rows stays live', () {
      final terminal = terminalWithScrollback();
      terminal.write('\x1b[3J');
      final controller = xt.TerminalController();
      final line = terminal.buffer.lines[1];
      controller.setSelection(
        xt.CellAnchor(0, owner: line),
        xt.CellAnchor(3, owner: line),
      );

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(terminalSelectionIsLive(terminal.buffer, selection!), isTrue);
    });
  });

  // A width change reflows, which rebuilds the line list wholesale. Doing that
  // on a buffer a clear has already trimmed is the one path where the
  // "negative row means cleared away" rule above can be made to lie, so it
  // gets its own coverage.
  group('after a scrollback clear and a width change', () {
    xt.Terminal clearedThenResized(int newWidth) {
      final terminal = terminalWithScrollback();
      terminal.write('\x1b[3J');
      terminal.resize(newWidth, 5);
      return terminal;
    }

    for (final width in const [30, 12]) {
      test('every row reports its true position at width $width', () {
        final terminal = clearedThenResized(width);

        for (var row = 0; row < terminal.buffer.lines.length; row++) {
          expect(
            terminal.buffer.lines[row].index,
            row,
            reason: 'row $row misreports after reflow',
          );
        }
      });

      test('cleared lines are not handed back out at width $width', () {
        final terminal = terminalWithScrollback();
        final cleared = terminal.buffer.lines[0];
        terminal.write('\x1b[3J');
        terminal.resize(width, 5);

        // The failure this guards is a reflow rotating the line list so the
        // rows a clear removed are readable again at the top of the buffer.
        for (var row = 0; row < terminal.buffer.lines.length; row++) {
          expect(identical(terminal.buffer.lines[row], cleared), isFalse);
        }
      });
    }

    test('a live selection survives the reflow', () {
      final terminal = clearedThenResized(30);
      final controller = xt.TerminalController();
      final line = terminal.buffer.lines[1];
      controller.setSelection(
        xt.CellAnchor(0, owner: line),
        xt.CellAnchor(3, owner: line),
      );

      // Rows that are genuinely present must not be mistaken for cleared ones,
      // or a selection gets dropped out from under the user on every resize.
      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(terminalSelectionIsLive(terminal.buffer, selection!), isTrue);
    });

    test('a scroll anchor on a surviving line still pins', () {
      final terminal = terminalWithScrollback();
      terminal.write('\x1b[3J');
      final anchor = TerminalScrollAnchor();
      anchor.capture(
        buffer: terminal.buffer,
        pixels: 20,
        maxScrollExtent: 200,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);
      final anchored = terminal.buffer.lines[2];

      terminal.resize(30, 5);

      // These lines are short enough that widening merges nothing, so the
      // anchored row must not move. The offset alone does not prove that: it
      // reads 20 on the unfixed emulator too, because the rotation happens to
      // give that line the same absolute index. What differs is which line
      // actually sits at row 2, so assert both.
      expect(identical(terminal.buffer.lines[2], anchored), isTrue);
      expect(
        anchor.desiredOffset(maxScrollExtent: 200, lineHeight: lineHeight),
        20,
      );
    });
  });
}
