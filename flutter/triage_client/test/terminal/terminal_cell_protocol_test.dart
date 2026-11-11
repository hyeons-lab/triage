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
      expect(TerminalCellLine.fromDecoded(decodedZlib[0]).toPlainText(), 'hello world');

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

    test('preserves styled spans and RGB colors across encodeTcg1StyledRows', () {
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
    });

    test('rejects invalid magic, truncated buffers, and unsupported compression', () {
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
    });

    test('enforces 16 MiB decompressed zlib cap against decompression bombs', () {
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
    });
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
      expect(tcg1BytesFromField(base64Encode(sample)), equals(sample));
    });

    test('TerminalCursorShape maps DECSCUSR codes 0..6', () {
      expect(TerminalCursorShape.fromCode(0), TerminalCursorShape.defaultShape);
      expect(TerminalCursorShape.fromCode(1), TerminalCursorShape.blinkingBlock);
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
      expect(TerminalCursorShape.fromCode(99), TerminalCursorShape.defaultShape);
    });
  });
}
