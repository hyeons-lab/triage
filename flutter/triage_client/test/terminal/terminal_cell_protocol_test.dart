import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';

Uint8List _wordsToBytes(List<int> words) {
  final out = Uint8List(words.length * 4);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < words.length; i++) {
    bd.setUint32(i * 4, words[i], Endian.little);
  }
  return out;
}

void main() {
  group('decodeTcg1Batch', () {
    test('returns empty list on empty payload', () {
      expect(decodeTcg1Batch(kCellCompressionNone, Uint8List(0)), isEmpty);
      expect(decodeTcg1Batch(kCellCompressionZlib, Uint8List(0)), isEmpty);
    });

    test('decodes raw and zlib-compressed batches identically', () {
      final raw = encodeTcg1PlainTextRows(
        const <String>['hello world', '中文字体 wide', 'wrapped line'],
        cols: 40,
        startRowIndex: 3,
        wrappedRowIndices: const <int>{5},
      );
      final compressed = Uint8List.fromList(const ZLibEncoder().encode(raw));

      final decodedRaw = decodeTcg1Batch(kCellCompressionNone, raw);
      final decodedZlib = decodeTcg1Batch(kCellCompressionZlib, compressed);

      expect(decodedRaw, hasLength(3));
      expect(decodedZlib, hasLength(3));

      expect(decodedZlib[0].rowIndex, 3);
      expect(decodedZlib[0].logicalCols, 40);
      expect(decodedZlib[0].wrapsNext, isFalse);
      expect(
        TerminalCellLine.fromDecoded(decodedZlib[0]).toPlainText(),
        'hello world',
      );

      final wideLine = TerminalCellLine.fromDecoded(decodedZlib[1]);
      expect(wideLine.toPlainText(), '中文字体 wide');
      expect(wideLine.getWidth(0), 2);
      expect(wideLine.getWidth(1), 0);
      expect(wideLine.getCodePoint(1), 0);
      expect(wideLine.getWidth(2), 2);

      expect(decodedZlib[2].rowIndex, 5);
      expect(decodedZlib[2].wrapsNext, isTrue);
    });

    test('decodes combining marks attached to cells', () {
      // One row, 2 stored cols, 80 logical cols, kLineFlagHasCombining set.
      final meta = 2 | (80 << 12) | (kLineFlagHasCombining << 24);
      final raw = _wordsToBytes(<int>[
        kTcg1Magic,
        1, // lineCount
        2, // combiningCount
        0, // rowIndex
        meta,
        // col 0: 'e'
        kColorNormal,
        kColorNormal,
        0,
        0x65 | (1 << kContentWidthShift),
        // col 1: 'a'
        kColorNormal,
        kColorNormal,
        0,
        0x61 | (1 << kContentWidthShift),
        // combining 0: line 0, col 0, U+0301 (acute accent)
        0,
        0,
        0x0301,
        // combining 1: line 0, col 0, U+0327 (cedilla)
        0,
        0,
        0x0327,
      ]);

      final rows = decodeTcg1Batch(kCellCompressionNone, raw);
      expect(rows, hasLength(1));
      final line = TerminalCellLine.fromDecoded(rows.single);
      expect(line.cellGlyph(0), 'e\u0301\u0327');
      expect(line.cellGlyph(1), 'a');
      expect(line.toPlainText(), 'e\u0301\u0327a');
    });

    test(
      'preserves styled spans and RGB colors across encodeTcg1StyledRows',
      () {
        const styled = <StyledRow>[
          StyledRow(
            spans: <StyledSpan>[
              StyledSpan(
                text: 'ERR ',
                style: TerminalStyle(
                  foreground: TerminalColor(red: 240, green: 80, blue: 90),
                  background: TerminalColor(red: 20, green: 30, blue: 40),
                  bold: true,
                  underline: true,
                ),
              ),
              StyledSpan(
                text: 'ok',
                style: TerminalStyle(italic: true, dim: true, reverse: true),
              ),
            ],
          ),
        ];
        final raw = encodeTcg1StyledRows(styled, cols: 20);
        final decoded = decodeTcg1Batch(kCellCompressionNone, raw);
        final line = TerminalCellLine.fromDecoded(decoded.single);
        expect(line.toPlainText(), 'ERR ok');
        expect(line.getAttrs(0) & kAttrBold, isNonZero);
        expect(line.getAttrs(0) & kAttrUnderline, isNonZero);
        expect(
          TriageTerminalPalette.resolveForeground(line.getFg(0)),
          const Color(0xFFF0505A),
        );
        expect(
          TriageTerminalPalette.resolveBackground(line.getBg(0)),
          const Color(0xFF141E28),
        );
        expect(line.getAttrs(4) & kAttrItalic, isNonZero);
        expect(line.getAttrs(4) & kAttrFaint, isNonZero);
        expect(line.getAttrs(4) & kAttrInverse, isNonZero);
      },
    );

    test(
      'rejects invalid magic, truncated buffers, and unsupported compression',
      () {
        expect(
          () => decodeTcg1Batch(99, Uint8List.fromList(<int>[1, 2, 3, 4])),
          throwsFormatException,
        );
        expect(
          () => decodeTcg1Batch(kCellCompressionNone, Uint8List(8)),
          throwsFormatException,
        );
        expect(
          () => decodeTcg1Batch(
            kCellCompressionNone,
            _wordsToBytes(<int>[0xDEADBEEF, 0, 0]),
          ),
          throwsFormatException,
        );
        // Claims 2 lines but contains no line headers.
        expect(
          () => decodeTcg1Batch(
            kCellCompressionNone,
            _wordsToBytes(<int>[kTcg1Magic, 2, 0]),
          ),
          throwsFormatException,
        );
        // Claims 4 stored cells on line 0 but contains zero cell words.
        expect(
          () => decodeTcg1Batch(
            kCellCompressionNone,
            _wordsToBytes(<int>[kTcg1Magic, 1, 0, 0, 4 | (80 << 12)]),
          ),
          throwsFormatException,
        );
        // Trailing extra word mismatches combiningCount.
        expect(
          () => decodeTcg1Batch(
            kCellCompressionNone,
            _wordsToBytes(<int>[kTcg1Magic, 0, 0, 123]),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'enforces 16 MiB decompressed zlib cap against decompression bombs',
      () {
        final oversized = Uint8List(kMaxDecompressedTcg1Bytes + 4);
        final compressed = Uint8List.fromList(
          const ZLibEncoder().encode(oversized),
        );
        expect(
          () => decodeTcg1Batch(kCellCompressionZlib, compressed),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('16 MiB cap'),
            ),
          ),
        );
      },
    );
  });

  group('TriageTerminalPalette & wire helpers', () {
    test('resolves default, ANSI-16, 6x6x6 cube, grayscale, and TrueColor', () {
      expect(
        TriageTerminalPalette.resolveForeground(kColorNormal),
        TriageTerminalPalette.foreground,
      );
      expect(
        TriageTerminalPalette.resolveBackground(kColorNormal),
        TriageTerminalPalette.background,
      );
      expect(
        TriageTerminalPalette.resolveForeground(kColorNamed | 1),
        TriageTerminalPalette.ansi16[1],
      );
      // Palette index 196 is pure red (r=5 -> 255, g=0, b=0) in 6x6x6 cube.
      expect(
        TriageTerminalPalette.resolveForeground(kColorPalette | 196),
        const Color(0xFFFF0000),
      );
      // Palette index 232 is darkest grayscale step (v = 8).
      expect(
        TriageTerminalPalette.resolveBackground(kColorPalette | 232),
        const Color(0xFF080808),
      );
      expect(
        TriageTerminalPalette.resolveForeground(kColorRgb | 0x12AB34),
        const Color(0xFF12AB34),
      );
    });

    test('tcg1BytesFromField normalizes Uint8List, List<int>, and Base64', () {
      final sample = Uint8List.fromList(<int>[10, 20, 30, 40]);
      expect(tcg1BytesFromField(null), isEmpty);
      expect(tcg1BytesFromField(''), isEmpty);
      expect(tcg1BytesFromField('!!!not-base64!!!'), isEmpty);
      expect(tcg1BytesFromField(sample), equals(sample));
      expect(tcg1BytesFromField(<int>[10, 20, 30, 40]), equals(sample));
      expect(tcg1BytesFromField(<int>[10, -1, 30]), isEmpty);
      expect(tcg1BytesFromField(<int>[10, 256, 30]), isEmpty);
      expect(tcg1BytesFromField(base64Encode(sample)), equals(sample));
    });

    test(
      'decodeTcg1Batch rejects malformed alignment, row bounds, and scalars',
      () {
        // Non-4-byte-aligned payload.
        expect(
          () => decodeTcg1Batch(kCellCompressionNone, Uint8List(13)),
          throwsFormatException,
        );

        // rowIndex >= 0x10000 in line header word0 (1 line, 0 combining).
        final badRowIdx = _wordsToBytes(<int>[
          kTcg1Magic,
          1, // lineCount
          0, // combiningCount
          0x10000, // rowIndex = 65536 (exceeds 0xFFFF)
          0 | (10 << 12), // storedCols = 0, logicalCols = 10
        ]);
        expect(
          () => decodeTcg1Batch(kCellCompressionNone, badRowIdx),
          throwsFormatException,
        );

        // storedCols (5) > logicalCols (3).
        final badStoredCols = _wordsToBytes(<int>[
          kTcg1Magic,
          1,
          0,
          0,
          5 | (3 << 12),
        ]);
        expect(
          () => decodeTcg1Batch(kCellCompressionNone, badStoredCols),
          throwsFormatException,
        );

        // Combining entry referencing invalid Unicode surrogate scalar 0xD800:
        // decoder sanitizes surrogate scalars to U+FFFD without throwing UTF-16 error.
        final surrogateCombining = _wordsToBytes(<int>[
          kTcg1Magic,
          1, // lineCount
          1, // combiningCount
          0, // rowIndex
          1 | (2 << 12) | (kLineFlagHasCombining << 24),
          kColorNormal,
          kColorNormal,
          0,
          0x0065 | (1 << kContentWidthShift), // 'e', width 1
          0, // lineIdx = 0
          0, // col = 0
          0xD800, // surrogate codepoint -> sanitized to U+FFFD
        ]);
        final sanitizedRows = decodeTcg1Batch(
          kCellCompressionNone,
          surrogateCombining,
        );
        expect(
          TerminalCellLine.fromDecoded(sanitizedRows.single).cellGlyph(0),
          'e\uFFFD',
        );

        // Combining entry with out-of-bounds col >= storedCols throws FormatException.
        final badCombiningCol = _wordsToBytes(<int>[
          kTcg1Magic,
          1,
          1,
          0,
          1 | (2 << 12) | (kLineFlagHasCombining << 24),
          kColorNormal,
          kColorNormal,
          0,
          0x0065 | (1 << kContentWidthShift),
          0, // lineIdx = 0
          5, // col = 5 (>= storedCols 1)
          0x0301,
        ]);
        expect(
          () => decodeTcg1Batch(kCellCompressionNone, badCombiningCol),
          throwsFormatException,
        );
      },
    );

    test(
      'plain and styled encoders preserve combining marks and SMP emoji',
      () {
        final plainBytes = encodeTcg1PlainTextRows(const <String>[
          'cafe\u0301 🚀!',
        ], cols: 16);
        final plainDecoded = decodeTcg1Batch(kCellCompressionNone, plainBytes);
        expect(plainDecoded, hasLength(1));
        final plainLine = TerminalCellLine.fromDecoded(plainDecoded.single);
        expect(plainLine.toPlainText(), 'cafe\u0301 🚀!');
        expect(plainLine.cellGlyph(3), 'e\u0301');
        expect(plainLine.cellGlyph(5), '🚀');
        expect(plainLine.getWidth(5), 2);
        expect(plainLine.getWidth(6), 0);
        expect(plainLine.cellGlyph(7), '!');

        final styledBytes = encodeTcg1StyledRows(const <StyledRow>[
          StyledRow(
            spans: <StyledSpan>[
              StyledSpan(text: 'e\u0301🚀x', style: TerminalStyle()),
            ],
          ),
        ], cols: 12);
        final styledDecoded = decodeTcg1Batch(
          kCellCompressionNone,
          styledBytes,
        );
        final styledLine = TerminalCellLine.fromDecoded(styledDecoded.single);
        expect(styledLine.toPlainText(), 'e\u0301🚀x');
        expect(styledLine.cellGlyph(0), 'e\u0301');
        expect(styledLine.cellGlyph(1), '🚀');
        expect(styledLine.getWidth(1), 2);
        expect(styledLine.getWidth(2), 0);
        expect(styledLine.cellGlyph(3), 'x');
      },
    );

    test('TerminalCursorShape maps DECSCUSR codes 0..6', () {
      expect(TerminalCursorShape.fromCode(0), TerminalCursorShape.defaultShape);
      expect(
        TerminalCursorShape.fromCode(1),
        TerminalCursorShape.blinkingBlock,
      );
      expect(TerminalCursorShape.fromCode(2), TerminalCursorShape.steadyBlock);
      expect(
        TerminalCursorShape.fromCode(3),
        TerminalCursorShape.blinkingUnderline,
      );
      expect(
        TerminalCursorShape.fromCode(4),
        TerminalCursorShape.steadyUnderline,
      );
      expect(TerminalCursorShape.fromCode(5), TerminalCursorShape.blinkingBar);
      expect(TerminalCursorShape.fromCode(6), TerminalCursorShape.steadyBar);
      expect(
        TerminalCursorShape.fromCode(99),
        TerminalCursorShape.defaultShape,
      );
    });

    test(
      'encoders skip C0/DEL/C1 control runes and wire fromMap clamps bounds safely',
      () {
        final plainBytes = encodeTcg1PlainTextRows(const <String>[
          'a\x00\x1b\x7f\u0085b\u0301',
        ], cols: 10);
        final plainLine = TerminalCellLine.fromDecoded(
          decodeTcg1Batch(kCellCompressionNone, plainBytes).single,
        );
        expect(plainLine.toPlainText(), 'ab\u0301');
        expect(plainLine.cellGlyph(0), 'a');
        expect(plainLine.cellGlyph(1), 'b\u0301');

        final styledBytes = encodeTcg1StyledRows(const <StyledRow>[
          StyledRow(
            spans: <StyledSpan>[
              StyledSpan(text: 'x\x07\u009by', style: TerminalStyle()),
            ],
          ),
        ], cols: 8);
        final styledLine = TerminalCellLine.fromDecoded(
          decodeTcg1Batch(kCellCompressionNone, styledBytes).single,
        );
        expect(styledLine.toPlainText(), 'xy');

        final frame = TerminalSyncFrameData.fromMap(<String, dynamic>{
          'frame_seq': '42',
          'cursor_x': double.infinity,
          'cursor_y': 7.0,
          'rows': 999999,
          'cols': 999999,
          'title': 12345,
        });
        expect(frame.frameSeq, 0);
        expect(frame.cursorX, 0);
        expect(frame.cursorY, 7);
        expect(frame.rows, kMaxViewportRows);
        expect(frame.cols, kMaxEncodedCols);
        expect(frame.title, isNull);

        final page = TerminalRowsPageData.fromMap(<String, dynamic>{
          'session_id': 99,
          'start_row': '10',
          'row_count': 999999,
        });
        expect(page.sessionId, '');
        expect(page.startRow, 0);
        expect(page.rowCount, 0x10000);
      },
    );
  });
}
