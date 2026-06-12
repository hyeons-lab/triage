import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_scroll_anchor.dart';
import 'package:xterm/xterm.dart' as xt;

/// Fills the terminal until its buffer is full (every further write trims a line
/// off the top), then writes a few extra lines so the buffer is firmly capped.
xt.Terminal _fullTerminal({required int maxLines, int viewHeight = 5}) {
  final terminal = xt.Terminal(maxLines: maxLines);
  terminal.resize(40, viewHeight);
  var i = 0;
  while (terminal.buffer.lines.length < maxLines) {
    terminal.write('line${i++}\r\n');
  }
  return terminal;
}

void main() {
  const lineHeight = 10.0;

  group('TerminalScrollAnchor', () {
    test('no anchor by default', () {
      final anchor = TerminalScrollAnchor();
      expect(anchor.hasAnchor, isFalse);
      expect(
        anchor.desiredOffset(maxScrollExtent: 100, lineHeight: lineHeight),
        isNull,
      );
    });

    test('capturing at the bottom follows the bottom (no anchor)', () {
      final terminal = _fullTerminal(maxLines: 30);
      final anchor = TerminalScrollAnchor();
      final maxExtent = terminal.buffer.lines.length * lineHeight;

      anchor.capture(
        buffer: terminal.buffer,
        pixels: maxExtent, // pinned to the very bottom
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );

      expect(anchor.hasAnchor, isFalse);
    });

    test('capturing above the bottom pins the top viewport line', () {
      final terminal = _fullTerminal(maxLines: 30);
      final anchor = TerminalScrollAnchor();
      final maxExtent = terminal.buffer.lines.length * lineHeight;
      const pixels = 100.0; // topRow == 10

      anchor.capture(
        buffer: terminal.buffer,
        pixels: pixels,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );

      expect(anchor.hasAnchor, isTrue);
      expect(
        anchor.desiredOffset(maxScrollExtent: maxExtent, lineHeight: lineHeight),
        pixels,
      );
    });

    test('pinned offset tracks the anchored line as scrollback trims', () {
      final terminal = _fullTerminal(maxLines: 30);
      final buffer = terminal.buffer;
      final maxExtent = buffer.lines.length * lineHeight;
      const anchorRow = 10;

      // The same BufferLine the anchor will capture, tracked independently so we
      // can assert the anchor follows it exactly.
      final pinnedLine = buffer.lines[anchorRow];
      expect(pinnedLine.index, anchorRow);

      final anchor = TerminalScrollAnchor();
      anchor.capture(
        buffer: buffer,
        pixels: anchorRow * lineHeight,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );

      // Stream more output. The buffer is full, so each new line trims one off
      // the top and the pinned line's index drops by one.
      for (var i = 0; i < 5; i++) {
        terminal.write('more$i\r\n');
      }

      expect(pinnedLine.attached, isTrue);
      expect(pinnedLine.index, lessThan(anchorRow));

      // The anchor's desired offset must equal the pinned line's current
      // position — i.e. it cancels the trim drift instead of staying at the old
      // pixel offset.
      expect(
        anchor.desiredOffset(maxScrollExtent: maxExtent, lineHeight: lineHeight),
        pinnedLine.index * lineHeight,
      );
    });

    test('anchor is dropped once its line is trimmed out of the buffer', () {
      final terminal = _fullTerminal(maxLines: 30);
      final buffer = terminal.buffer;
      final maxExtent = buffer.lines.length * lineHeight;
      const anchorRow = 3; // near the top, trimmed away quickly

      final anchor = TerminalScrollAnchor();
      anchor.capture(
        buffer: buffer,
        pixels: anchorRow * lineHeight,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);

      // Write well past the anchor's depth so the pinned line is trimmed off.
      for (var i = 0; i < anchorRow + 5; i++) {
        terminal.write('flush$i\r\n');
      }

      expect(
        anchor.desiredOffset(maxScrollExtent: maxExtent, lineHeight: lineHeight),
        isNull,
      );
      expect(anchor.hasAnchor, isFalse);
    });
  });
}
