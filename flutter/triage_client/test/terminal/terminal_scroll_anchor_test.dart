import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_scroll_anchor.dart';
import 'package:xterm/xterm.dart' as xt;

const _viewHeight = 5;

/// Fills the terminal until its buffer is full (every further write trims a line
/// off the top), then writes a few extra lines so the buffer is firmly capped
/// and the trim path has actually run before the test inspects it.
xt.Terminal _fullTerminal({
  required int maxLines,
  int viewHeight = _viewHeight,
}) {
  final terminal = xt.Terminal(maxLines: maxLines);
  terminal.resize(40, viewHeight);
  var i = 0;
  while (terminal.buffer.lines.length < maxLines) {
    terminal.write('line${i++}\r\n');
  }
  for (var extra = 0; extra < 3; extra++) {
    terminal.write('cap$extra\r\n');
  }
  return terminal;
}

/// The scroll position's `maxScrollExtent` is the content height minus the
/// viewport height — not the full content height — so anchor clamping and
/// bottom detection see the same value the widget wiring passes in.
double _maxExtent(xt.Terminal terminal, double lineHeight) =>
    (terminal.buffer.lines.length - _viewHeight) * lineHeight;

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
      final maxExtent = _maxExtent(terminal, lineHeight);

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
      final maxExtent = _maxExtent(terminal, lineHeight);
      const pixels = 100.0; // topRow == 10

      anchor.capture(
        buffer: terminal.buffer,
        pixels: pixels,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );

      expect(anchor.hasAnchor, isTrue);
      expect(
        anchor.desiredOffset(
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        pixels,
      );
    });

    test('pinned offset tracks the anchored line as scrollback trims', () {
      final terminal = _fullTerminal(maxLines: 30);
      final buffer = terminal.buffer;
      final maxExtent = _maxExtent(terminal, lineHeight);
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
        anchor.desiredOffset(
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        pinnedLine.index * lineHeight,
      );
    });

    test('anchor is dropped once its line is trimmed out of the buffer', () {
      final terminal = _fullTerminal(maxLines: 30);
      final buffer = terminal.buffer;
      final maxExtent = _maxExtent(terminal, lineHeight);
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
        anchor.desiredOffset(
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        isNull,
      );
      expect(anchor.hasAnchor, isFalse);
    });

    test('clone and copyFrom preserve anchor state and desired offset', () {
      final terminal = _fullTerminal(maxLines: 30);
      final anchor = TerminalScrollAnchor();
      final maxExtent = _maxExtent(terminal, lineHeight);
      const anchorRow = 10;

      anchor.capture(
        buffer: terminal.buffer,
        pixels: anchorRow * lineHeight,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);

      final cloned = anchor.clone();
      expect(cloned.hasAnchor, isTrue);
      expect(
        cloned.desiredOffset(
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        anchor.desiredOffset(
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
      );

      final target = TerminalScrollAnchor();
      target.copyFrom(cloned);
      expect(target.hasAnchor, isTrue);
      expect(
        target.desiredOffset(
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        anchor.desiredOffset(
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
      );
    });
  });

  group('shouldReleaseScrollPin', () {
    const lineHeight = 10.0;
    const maxExtent = 1000.0;
    const graceBand = kScrollPinReleaseGraceLines * lineHeight;

    test('no previous position never releases', () {
      expect(
        shouldReleaseScrollPin(
          lastPixels: null,
          pixels: maxExtent,
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        isFalse,
      );
    });

    test('scrolling up keeps the pin', () {
      expect(
        shouldReleaseScrollPin(
          lastPixels: 500,
          pixels: 400,
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        isFalse,
      );
    });

    test('scrolling down far from the bottom keeps the pin', () {
      expect(
        shouldReleaseScrollPin(
          lastPixels: 100,
          pixels: 200,
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        isFalse,
      );
    });

    test('scrolling down within the grace releases the pin', () {
      expect(
        shouldReleaseScrollPin(
          lastPixels: maxExtent - graceBand - 20,
          pixels: maxExtent - graceBand + 1,
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        isTrue,
      );
    });

    test('scrolling up inside the grace band keeps the pin', () {
      // The direction guard is the whole premise of the feature, and proximity
      // alone cannot carry this: both offsets sit inside the grace band, so
      // only `pixels <= lastPixels` can reject it.
      expect(
        shouldReleaseScrollPin(
          lastPixels: maxExtent,
          pixels: maxExtent - 5,
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        isFalse,
      );
    });

    test('a scroll that does not move keeps the pin', () {
      expect(
        shouldReleaseScrollPin(
          lastPixels: maxExtent - 5,
          pixels: maxExtent - 5,
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        isFalse,
      );
    });

    test('a non-positive line height never releases', () {
      // Scrolling down onto the bottom, so only the line-height guard can
      // reject this: with `pixels <= lastPixels` the call would return false
      // for the wrong reason and the test could not fail.
      expect(
        shouldReleaseScrollPin(
          lastPixels: 0,
          pixels: maxExtent,
          maxScrollExtent: maxExtent,
          lineHeight: 0,
        ),
        isFalse,
      );
    });

    test('a non-positive max scroll extent never releases', () {
      expect(
        shouldReleaseScrollPin(
          lastPixels: -20,
          pixels: -10,
          maxScrollExtent: 0,
          lineHeight: lineHeight,
        ),
        isFalse,
      );
    });

    test('a negative pixel offset during top overscroll never releases', () {
      expect(
        shouldReleaseScrollPin(
          lastPixels: -25,
          pixels: -10,
          maxScrollExtent: 15,
          lineHeight: lineHeight,
        ),
        isFalse,
      );
    });
  });

  group('shouldFinishBottomSnap', () {
    test('settled below the bottom with no pin finishes the snap', () {
      expect(
        shouldFinishBottomSnap(
          isScrolling: false,
          pointerDown: false,
          pixels: 900,
          maxScrollExtent: 1000,
          hasAnchor: false,
        ),
        isTrue,
      );
    });

    test(
      'a negative pixel offset during top overscroll never finishes snap',
      () {
        expect(
          shouldFinishBottomSnap(
            isScrolling: false,
            pointerDown: false,
            pixels: -10,
            maxScrollExtent: 1000,
            hasAnchor: false,
          ),
          isFalse,
        );
      },
    );

    test('a scroll still in flight waits', () {
      expect(
        shouldFinishBottomSnap(
          isScrolling: true,
          pointerDown: false,
          pixels: 900,
          maxScrollExtent: 1000,
          hasAnchor: false,
        ),
        isFalse,
      );
    });

    test('a held pointer waits even though a hold reports not scrolling', () {
      expect(
        shouldFinishBottomSnap(
          isScrolling: false,
          pointerDown: true,
          pixels: 900,
          maxScrollExtent: 1000,
          hasAnchor: false,
        ),
        isFalse,
      );
    });

    test('re-pinning on the way abandons the snap', () {
      expect(
        shouldFinishBottomSnap(
          isScrolling: false,
          pointerDown: false,
          pixels: 900,
          maxScrollExtent: 1000,
          hasAnchor: true,
        ),
        isFalse,
      );
    });

    test('a gesture that reached the bottom leaves nothing to finish', () {
      expect(
        shouldFinishBottomSnap(
          isScrolling: false,
          pointerDown: false,
          pixels: 1000,
          maxScrollExtent: 1000,
          hasAnchor: false,
        ),
        isFalse,
      );
    });
  });
}
