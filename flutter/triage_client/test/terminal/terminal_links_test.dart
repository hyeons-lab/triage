import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';
import 'package:triage_client/terminal/terminal_links.dart';
import 'package:triage_client/terminal/terminal_selection.dart';

TerminalCellBuffer _bufferWithLines(
  List<String> lines, {
  int cols = 40,
  Set<int> wrappedRowIndices = const <int>{},
  int totalScrollbackRows = 0,
  int pushedScrollbackStartRow = 0,
  List<String> pushedScrollbackLines = const <String>[],
  Set<int> pushedWrappedIndices = const <int>{},
}) {
  final buffer = TerminalCellBuffer(cols: cols, rows: lines.length);
  addTearDown(buffer.dispose);
  buffer.applySyncFrame(
    TerminalSyncFrameData(
      frameSeq: 1,
      rows: lines.length,
      cols: cols,
      totalScrollbackRows: totalScrollbackRows,
      trimmedTopRows: 0,
      eraseScrollbackGen: 0,
      cursorX: 0,
      cursorY: 0,
      cursorStyle: 2,
      modeFlags: kModeCursorVisible | kModeAutoWrap | kModeFullViewport,
      mouseMode: 0,
      mouseReportMode: 0,
      kittyKeyboardFlags: 0,
      title: null,
      viewportCompression: kCellCompressionNone,
      viewportPayload: encodeTcg1PlainTextRows(
        lines,
        cols: cols,
        wrappedRowIndices: wrappedRowIndices,
      ),
      pushedScrollbackStartRow: pushedScrollbackStartRow,
      pushedScrollbackRowCount: pushedScrollbackLines.length,
      pushedScrollbackCompression: kCellCompressionNone,
      pushedScrollbackPayload: pushedScrollbackLines.isEmpty
          ? Uint8List(0)
          : encodeTcg1PlainTextRows(
              pushedScrollbackLines,
              cols: cols,
              wrappedRowIndices: pushedWrappedIndices,
            ),
    ),
  );
  return buffer;
}

void main() {
  group('terminal_links detection', () {
    test('detects http and https URLs on a single row', () {
      final buffer = _bufferWithLines(const <String>[
        'see http://a.example/1 and https://b.example/2?x=1&y=2',
      ], cols: 80);

      final links = detectLinksInRowRange(buffer, 0, 1);
      expect(links.length, 2);
      expect(links[0].url, 'http://a.example/1');
      expect(links[0].uri.toString(), 'http://a.example/1');
      expect(links[0].segments, const <TerminalLinkSegment>[
        TerminalLinkSegment(virtualRow: 0, startCol: 4, endCol: 22),
      ]);
      expect(links[1].url, 'https://b.example/2?x=1&y=2');
      expect(links[1].segments, const <TerminalLinkSegment>[
        TerminalLinkSegment(virtualRow: 0, startCol: 27, endCol: 54),
      ]);

      expect(
        detectLinkAtCell(buffer, const CellOffset(4, 0))?.url,
        'http://a.example/1',
      );
      expect(detectLinkAtCell(buffer, const CellOffset(22, 0)), isNull);
    });

    test('joins soft-wrapped URLs across wrapsNext rows', () {
      // 20-col width where the URL wraps mid-path across rows 0, 1, 2.
      final buffer = _bufferWithLines(
        const <String>[
          'open https://example',
          '.com/very/long/path/',
          'item?q=ok done',
        ],
        cols: 20,
        wrappedRowIndices: const <int>{0, 1},
      );

      final links = detectLinksInRowRange(buffer, 0, 3);
      expect(links.length, 1);
      final link = links.single;
      expect(link.url, 'https://example.com/very/long/path/item?q=ok');
      expect(link.segments, const <TerminalLinkSegment>[
        TerminalLinkSegment(virtualRow: 0, startCol: 5, endCol: 20),
        TerminalLinkSegment(virtualRow: 1, startCol: 0, endCol: 20),
        TerminalLinkSegment(virtualRow: 2, startCol: 0, endCol: 9),
      ]);

      // Hit-testing only the middle wrapped row (row 1..2) still resolves the
      // complete logical URL and all of its segments.
      final fromMiddle = detectLinkAtCell(buffer, const CellOffset(3, 1));
      expect(fromMiddle, equals(link));
      expect(detectLinkAtCell(buffer, const CellOffset(8, 2)), equals(link));
      expect(detectLinkAtCell(buffer, const CellOffset(9, 2)), isNull);
    });

    test('does not join across hard line breaks', () {
      final buffer = _bufferWithLines(const <String>[
        'https://example.com/',
        'next-path',
      ], cols: 20);

      final links = detectLinksInRowRange(buffer, 0, 2);
      expect(links.length, 1);
      expect(links.single.url, 'https://example.com/');
      expect(links.single.segments.length, 1);
    });

    test(
      'strips trailing punctuation while preserving balanced parens and IPv6 brackets',
      () {
        final buffer = _bufferWithLines(const <String>[
          '(https://en.wikipedia.org/wiki/Foo_(bar)).',
          'check https://[::1]:8080/status, ok!',
          '<https://example.com/q?a=1;b=2>?',
        ], cols: 60);

        final links = detectLinksInRowRange(buffer, 0, 3);
        expect(links.map((l) => l.url).toList(), <String>[
          'https://en.wikipedia.org/wiki/Foo_(bar)',
          'https://[::1]:8080/status',
          'https://example.com/q?a=1;b=2',
        ]);
      },
    );

    test('stops URLs at box-drawing characters', () {
      final buffer = _bufferWithLines(const <String>[
        '│https://example.com/in-box│',
      ], cols: 40);

      final links = detectLinksInRowRange(buffer, 0, 1);
      expect(links.length, 1);
      expect(links.single.url, 'https://example.com/in-box');
      expect(links.single.segments, const <TerminalLinkSegment>[
        TerminalLinkSegment(virtualRow: 0, startCol: 1, endCol: 27),
      ]);
    });

    test('tracks accurate cell columns after wide CJK glyphs', () {
      // '中文' occupies columns 0..3 (2 cells each + continuation placeholders),
      // space at col 4, URL starts at col 5.
      final buffer = _bufferWithLines(const <String>[
        '中文 https://example.com/cjk',
      ], cols: 40);

      final links = detectLinksInRowRange(buffer, 0, 1);
      expect(links.length, 1);
      expect(links.single.url, 'https://example.com/cjk');
      expect(links.single.segments, const <TerminalLinkSegment>[
        TerminalLinkSegment(virtualRow: 0, startCol: 5, endCol: 28),
      ]);
      expect(
        detectLinkAtCell(buffer, const CellOffset(5, 0))?.url,
        'https://example.com/cjk',
      );
    });

    test('rejects non-http schemes and bare scheme prefixes', () {
      final buffer = _bufferWithLines(const <String>[
        'ftp://files.example file:///tmp/x mailto:a@b.c http:// https://.',
      ], cols: 80);

      expect(detectLinksInRowRange(buffer, 0, 1), isEmpty);
    });

    test('stops safely at unloaded scrollback gaps', () {
      // 4 scrollback rows total; only row 3 (and viewport row 4) are loaded.
      // Row 2 is missing (null). Even though row 3 wraps into row 4, detection
      // from row 4 stops upward at missing row 2 without throwing.
      final buffer = _bufferWithLines(
        const <String>['.org/ready done'],
        cols: 20,
        totalScrollbackRows: 4,
        pushedScrollbackStartRow: 3,
        pushedScrollbackLines: const <String>['see https://triage'],
        pushedWrappedIndices: const <int>{0},
      );

      final links = detectLinksInRowRange(buffer, 0, 5);
      expect(links.length, 1);
      expect(links.single.url, 'https://triage.org/ready');
      expect(links.single.segments, const <TerminalLinkSegment>[
        TerminalLinkSegment(virtualRow: 3, startCol: 4, endCol: 18),
        TerminalLinkSegment(virtualRow: 4, startCol: 0, endCol: 10),
      ]);
      expect(detectLinkAtCell(buffer, const CellOffset(0, 1)), isNull);
    });
  });
}
