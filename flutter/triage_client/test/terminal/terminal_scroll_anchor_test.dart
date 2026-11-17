import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';
import 'package:triage_client/terminal/terminal_scroll_anchor.dart';

const _viewHeight = 5;

TerminalCellLine _lineFromText(String text, {int width = 40}) {
  return TerminalCellLine.fromSpec(<String?>[
    for (final r in text.runes) String.fromCharCode(r),
  ], width: width);
}

/// Fills a [TerminalCellBuffer] until its scrollback+viewport capacity reaches
/// [maxLines], then appends extra lines so top retention trimming has run.
TerminalCellBuffer _fullBuffer({
  required int maxLines,
  int viewHeight = _viewHeight,
}) {
  final buffer = TerminalCellBuffer(cols: 40, rows: viewHeight);
  var i = 0;
  while (buffer.totalLines < maxLines) {
    buffer.appendOutputLineForTest(
      _lineFromText('line${i++}'),
      maxTotalLines: maxLines,
    );
  }
  for (var extra = 0; extra < 3; extra++) {
    buffer.appendOutputLineForTest(
      _lineFromText('cap$extra'),
      maxTotalLines: maxLines,
    );
  }
  return buffer;
}

double _maxExtent(TerminalCellBuffer buffer, double lineHeight) =>
    (buffer.totalLines - _viewHeight) * lineHeight;

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
      final buffer = _fullBuffer(maxLines: 30);
      final anchor = TerminalScrollAnchor();
      final maxExtent = _maxExtent(buffer, lineHeight);

      anchor.capture(
        buffer: buffer,
        pixels: maxExtent,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );

      expect(anchor.hasAnchor, isFalse);
    });

    test('capturing just above the bottom holds an anchor', () {
      final buffer = _fullBuffer(maxLines: 30);
      final anchor = TerminalScrollAnchor();
      final maxExtent = _maxExtent(buffer, lineHeight);

      final oneLineAbove = maxExtent - lineHeight;
      anchor.capture(
        buffer: buffer,
        pixels: oneLineAbove,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);
      expect(
        anchor.desiredOffset(
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        oneLineAbove,
      );

      final twoLinesAbove = maxExtent - 2 * lineHeight;
      anchor.capture(
        buffer: buffer,
        pixels: twoLinesAbove,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);
      expect(
        anchor.desiredOffset(
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        twoLinesAbove,
      );

      anchor.capture(
        buffer: buffer,
        pixels: maxExtent - 0.6,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);

      anchor.capture(
        buffer: buffer,
        pixels: maxExtent - 0.3,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isFalse);
    });

    test('capturing above the bottom pins the top viewport line', () {
      final buffer = _fullBuffer(maxLines: 30);
      final anchor = TerminalScrollAnchor();
      final maxExtent = _maxExtent(buffer, lineHeight);
      const pixels = 100.0;

      anchor.capture(
        buffer: buffer,
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

    test(
      'invalidates anchor on eraseScrollbackGen increment or alt-screen entry',
      () {
        final buffer = TerminalCellBuffer(cols: 40, rows: _viewHeight);
        for (var i = 0; i < 20; i++) {
          buffer.appendOutputLineForTest(
            _lineFromText('row$i'),
            maxTotalLines: 30,
          );
        }
        final maxExtent = _maxExtent(buffer, lineHeight);
        final anchor = TerminalScrollAnchor();
        anchor.capture(
          buffer: buffer,
          pixels: 50.0,
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        );
        expect(anchor.hasAnchor, isTrue);

        // Enter alt-screen: anchor must drop instead of resolving against alt rows.
        buffer.applySyncFrame(
          TerminalSyncFrameData(
            frameSeq: 1,
            rows: _viewHeight,
            cols: 40,
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
            viewportPayload: Uint8List(0),
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 0,
            pushedScrollbackCompression: kCellCompressionNone,
            pushedScrollbackPayload: Uint8List(0),
          ),
        );
        expect(
          anchor.desiredOffset(
            maxScrollExtent: maxExtent,
            lineHeight: lineHeight,
          ),
          isNull,
        );
        expect(anchor.hasAnchor, isFalse);
      },
    );

    test('desiredOffset returns null when maxScrollExtent is non-positive', () {
      final buffer = _fullBuffer(maxLines: 30);
      final anchor = TerminalScrollAnchor();
      anchor.capture(
        buffer: buffer,
        pixels: 100.0,
        maxScrollExtent: 300.0,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);
      expect(
        anchor.desiredOffset(maxScrollExtent: 0.0, lineHeight: lineHeight),
        isNull,
      );
      expect(
        anchor.desiredOffset(maxScrollExtent: -10.0, lineHeight: lineHeight),
        isNull,
      );
    });

    test('pinned offset tracks the anchored line as scrollback trims', () {
      final buffer = _fullBuffer(maxLines: 30);
      final maxExtent = _maxExtent(buffer, lineHeight);
      const anchorRow = 10;

      final pinnedText = buffer.lineAtVirtualRow(anchorRow)!.toPlainText();

      final anchor = TerminalScrollAnchor();
      anchor.capture(
        buffer: buffer,
        pixels: anchorRow * lineHeight,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );

      for (var i = 0; i < 5; i++) {
        buffer.appendOutputLineForTest(
          _lineFromText('more$i'),
          maxTotalLines: 30,
        );
      }

      const shiftedRow = anchorRow - 5;
      expect(buffer.lineAtVirtualRow(shiftedRow)!.toPlainText(), pinnedText);
      expect(
        anchor.desiredOffset(
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        ),
        shiftedRow * lineHeight,
      );
    });

    test('capturing at or below zero pixels does not hold an anchor', () {
      final buffer = _fullBuffer(maxLines: 30);
      final anchor = TerminalScrollAnchor();
      final maxExtent = _maxExtent(buffer, lineHeight);

      anchor.capture(
        buffer: buffer,
        pixels: 0.0,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isFalse);

      anchor.capture(
        buffer: buffer,
        pixels: -10.0,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isFalse);
    });

    test('capturing at top row 0 does not hold an anchor', () {
      final buffer = _fullBuffer(maxLines: 30);
      final anchor = TerminalScrollAnchor();
      final maxExtent = _maxExtent(buffer, lineHeight);

      anchor.capture(
        buffer: buffer,
        pixels: lineHeight / 2,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isFalse);
    });

    test(
      'anchor is dropped when trimmed up to row 0 or non-positive desired offset',
      () {
        final buffer = _fullBuffer(maxLines: 30);
        final maxExtent = _maxExtent(buffer, lineHeight);
        const anchorRow = 2;

        final anchor = TerminalScrollAnchor();
        anchor.capture(
          buffer: buffer,
          pixels: anchorRow * lineHeight,
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        );
        expect(anchor.hasAnchor, isTrue);

        for (var i = 0; i < anchorRow; i++) {
          buffer.appendOutputLineForTest(
            _lineFromText('trim$i'),
            maxTotalLines: 30,
          );
        }

        expect(
          anchor.desiredOffset(
            maxScrollExtent: maxExtent,
            lineHeight: lineHeight,
          ),
          isNull,
        );
        expect(anchor.hasAnchor, isFalse);
      },
    );

    test('anchor is dropped once its line is trimmed out of the buffer', () {
      final buffer = _fullBuffer(maxLines: 30);
      final maxExtent = _maxExtent(buffer, lineHeight);
      const anchorRow = 3;

      final anchor = TerminalScrollAnchor();
      anchor.capture(
        buffer: buffer,
        pixels: anchorRow * lineHeight,
        maxScrollExtent: maxExtent,
        lineHeight: lineHeight,
      );
      expect(anchor.hasAnchor, isTrue);

      for (var i = 0; i < anchorRow + 5; i++) {
        buffer.appendOutputLineForTest(
          _lineFromText('flush$i'),
          maxTotalLines: 30,
        );
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
      final buffer = _fullBuffer(maxLines: 30);
      final anchor = TerminalScrollAnchor();
      final maxExtent = _maxExtent(buffer, lineHeight);
      const anchorRow = 10;

      anchor.capture(
        buffer: buffer,
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

    test(
      'hasLineShifted is false until top trim changes anchored line index',
      () {
        final buffer = _fullBuffer(maxLines: 30);
        final anchor = TerminalScrollAnchor();
        final maxExtent = _maxExtent(buffer, lineHeight);

        anchor.capture(
          buffer: buffer,
          pixels: 10 * lineHeight,
          maxScrollExtent: maxExtent,
          lineHeight: lineHeight,
        );
        expect(anchor.hasAnchor, isTrue);
        expect(anchor.hasLineShifted, isFalse);

        // In-place cursor-addressed viewport write does not trim scrollback.
        buffer.setViewportLineForTest(0, _lineFromText('spinner'));
        expect(anchor.hasLineShifted, isFalse);

        // Appending a new line at full capacity trims 1 line off the top,
        // shifting the anchored line's index from 10 to 9.
        buffer.appendOutputLineForTest(
          _lineFromText('next line'),
          maxTotalLines: 30,
        );
        expect(anchor.hasLineShifted, isTrue);

        anchor.markPinned();
        expect(anchor.hasLineShifted, isFalse);
      },
    );

    test(
      'viewport-only anchor tracks live viewport growth and upper-bound shrink invalidates',
      () {
        final buffer = TerminalCellBuffer(cols: 40, rows: 5);
        for (var i = 0; i < 5; i++) {
          buffer.setViewportLineForTest(i, _lineFromText('vp$i'));
        }
        final anchor = TerminalScrollAnchor();
        // Capture when scrollbackRows == 0 (maxScrollExtent > 0 from sub-viewport layout).
        anchor.capture(
          buffer: buffer,
          pixels: 10,
          maxScrollExtent: 40,
          lineHeight: lineHeight,
        );
        expect(anchor.hasAnchor, isTrue);

        // Appending lines at the bottom keeps vp1 pinned at virtual row 1 (10.0 px),
        // and once retention trims 2 rows at the top (maxTotalLines: 5), vp1 ages past row 0 and invalidates.
        buffer.appendOutputLineForTest(_lineFromText('sb0'), maxTotalLines: 50);
        buffer.appendOutputLineForTest(_lineFromText('sb1'), maxTotalLines: 50);
        expect(
          anchor.desiredOffset(maxScrollExtent: 60, lineHeight: lineHeight),
          1 * lineHeight,
        );
        buffer.appendOutputLineForTest(_lineFromText('sb2'), maxTotalLines: 5);
        expect(anchor.hasAnchor, isFalse);

        // Shrinking totalLines below the anchored index invalidates the anchor cleanly.
        final anchorHigh = TerminalScrollAnchor();
        anchorHigh.capture(
          buffer: buffer,
          pixels: 3 * lineHeight,
          maxScrollExtent: 40,
          lineHeight: lineHeight,
        );
        expect(anchorHigh.hasAnchor, isTrue);
        buffer.applySyncFrame(
          TerminalSyncFrameData(
            frameSeq: 1,
            rows: 2,
            cols: 40,
            totalScrollbackRows: 0,
            trimmedTopRows: buffer.trimmedTopRows,
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
            viewportPayload: Uint8List(0),
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: 0,
            pushedScrollbackCompression: kCellCompressionNone,
            pushedScrollbackPayload: Uint8List(0),
          ),
        );
        expect(anchorHigh.hasAnchor, isFalse);
        expect(
          anchorHigh.desiredOffset(maxScrollExtent: 20, lineHeight: lineHeight),
          isNull,
        );
      },
    );
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

    test(
      'successive downward scroll events in grace band consistently release',
      () {
        final buffer = _fullBuffer(maxLines: 30);
        final maxExtent = _maxExtent(buffer, lineHeight);
        final graceThreshold =
            maxExtent - kScrollPinReleaseGraceLines * lineHeight;

        var last = graceThreshold;
        for (final delta in const [2.0, 5.0, 8.0, 10.0]) {
          final current = (graceThreshold + delta).clamp(0.0, maxExtent);
          expect(
            shouldReleaseScrollPin(
              lastPixels: last,
              pixels: current,
              maxScrollExtent: maxExtent,
              lineHeight: lineHeight,
            ),
            isTrue,
          );
          last = current;
        }
      },
    );
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
