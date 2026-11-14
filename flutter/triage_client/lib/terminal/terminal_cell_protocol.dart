import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:triage_client/models/terminal_models.dart';

const int kCellWords = 4;
const int kTcg1Magic = 0x31474354; // b"TCG1" little-endian

const int kCellCompressionNone = 0;
const int kCellCompressionZlib = 1;

const int kMaxDecompressedTcg1Bytes = 16 * 1024 * 1024;
const int kMaxEncodedCols = 0x0FFF;

const int kLineFlagWrapsNext = 1 << 0;
const int kLineFlagHasCombining = 1 << 1;

const int kModeAltScreen = 1 << 0;
const int kModeCursorVisible = 1 << 1;
const int kModeBracketedPaste = 1 << 2;
const int kModeAppCursorKeys = 1 << 3;
const int kModeAppKeypad = 1 << 4;
const int kModeOrigin = 1 << 5;
const int kModeAutoWrap = 1 << 6;
const int kModeReportFocus = 1 << 7;
const int kModeSawEraseScrollback = 1 << 8;
const int kModeSawEraseDisplay = 1 << 9;
const int kModeBellRang = 1 << 10;
const int kModeTitleChanged = 1 << 11;
const int kModeReverseVideo = 1 << 12;
const int kModeFullViewport = 1 << 13;

const int kColorTypeShift = 25;
const int kColorTypeMask = 0x3;
const int kColorNormal = 0;
const int kColorNamed = 1 << kColorTypeShift;
const int kColorPalette = 2 << kColorTypeShift;
const int kColorRgb = 3 << kColorTypeShift;

const int kAttrBold = 1 << 0;
const int kAttrFaint = 1 << 1;
const int kAttrItalic = 1 << 2;
const int kAttrUnderline = 1 << 3;
const int kAttrBlink = 1 << 4;
const int kAttrInverse = 1 << 5;
const int kAttrInvisible = 1 << 6;
const int kAttrStrikethrough = 1 << 7;
const int kAttrOverline = 1 << 8;
const int kAttrDoubleUnderline = 1 << 9;
const int kAttrUndercurl = 1 << 10;
const int kAttrDottedUnderline = 1 << 11;
const int kAttrDashedUnderline = 1 << 12;

const int kContentCodepointMask = 0x1FFFFF;
const int kContentHasCombining = 1 << 21;
const int kContentWidthShift = 22;

enum TerminalCursorShape {
  defaultShape,
  blinkingBlock,
  steadyBlock,
  blinkingUnderline,
  steadyUnderline,
  blinkingBar,
  steadyBar;

  static TerminalCursorShape fromCode(int code) {
    return switch (code) {
      1 => TerminalCursorShape.blinkingBlock,
      2 => TerminalCursorShape.steadyBlock,
      3 => TerminalCursorShape.blinkingUnderline,
      4 => TerminalCursorShape.steadyUnderline,
      5 => TerminalCursorShape.blinkingBar,
      6 => TerminalCursorShape.steadyBar,
      _ => TerminalCursorShape.defaultShape,
    };
  }
}

/// Triage terminal color palette and 256-color / TrueColor resolver.
class TriageTerminalPalette {
  const TriageTerminalPalette._();

  static const Color foreground = Color(0xffd9e5e3);
  static const Color background = Color(0xff0d1113);
  static const Color cursor = Color(0xff7fd1c7);
  static const Color selection = Color(0x3366cccc);

  static const List<Color> ansi16 = <Color>[
    Color(0xff1f2b30), // 0 black
    Color(0xfff2777a), // 1 red
    Color(0xff99cc99), // 2 green
    Color(0xffffcc66), // 3 yellow
    Color(0xff6699cc), // 4 blue
    Color(0xffcc99cc), // 5 magenta
    Color(0xff66cccc), // 6 cyan
    Color(0xffd9e5e3), // 7 white
    Color(0xff74838a), // 8 brightBlack
    Color(0xfff2777a), // 9 brightRed
    Color(0xff99cc99), // 10 brightGreen
    Color(0xffffcc66), // 11 brightYellow
    Color(0xff6699cc), // 12 brightBlue
    Color(0xffcc99cc), // 13 brightMagenta
    Color(0xff66cccc), // 14 brightCyan
    Color(0xffffffff), // 15 brightWhite
  ];

  static final List<Color> _xterm256 = _buildXterm256();

  static List<Color> _buildXterm256() {
    final out = List<Color>.filled(256, foreground);
    for (var i = 0; i < 16; i++) {
      out[i] = ansi16[i];
    }
    const levels = <int>[0, 95, 135, 175, 215, 255];
    for (var idx = 16; idx < 232; idx++) {
      final n = idx - 16;
      final r = levels[(n ~/ 36) % 6];
      final g = levels[(n ~/ 6) % 6];
      final b = levels[n % 6];
      out[idx] = Color(0xFF000000 | (r << 16) | (g << 8) | b);
    }
    for (var idx = 232; idx < 256; idx++) {
      final v = 8 + (idx - 232) * 10;
      out[idx] = Color(0xFF000000 | (v << 16) | (v << 8) | v);
    }
    return out;
  }

  static Color resolveForeground(int encoded) {
    final kind = (encoded >>> kColorTypeShift) & kColorTypeMask;
    return switch (kind) {
      0 => foreground,
      1 || 2 => _xterm256[encoded & 0xFF],
      3 => Color(0xFF000000 | (encoded & 0x00FFFFFF)),
      _ => foreground,
    };
  }

  static Color resolveBackground(int encoded) {
    final kind = (encoded >>> kColorTypeShift) & kColorTypeMask;
    return switch (kind) {
      0 => background,
      1 || 2 => _xterm256[encoded & 0xFF],
      3 => Color(0xFF000000 | (encoded & 0x00FFFFFF)),
      _ => background,
    };
  }
}

/// Extracts binary payload bytes from either a FlatBuffers [Uint8List]/[List<int>]
/// or a JSON Base64-encoded [String].
Uint8List tcg1BytesFromField(dynamic raw) {
  if (raw == null) return Uint8List(0);
  if (raw is Uint8List) return raw;
  if (raw is List) {
    final out = Uint8List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      final elem = raw[i];
      if (elem is! int || elem < 0 || elem > 255) {
        return Uint8List(0);
      }
      out[i] = elem;
    }
    return out;
  }
  if (raw is String) {
    if (raw.isEmpty) return Uint8List(0);
    try {
      return base64Decode(raw);
    } catch (_) {
      return Uint8List(0);
    }
  }
  return Uint8List(0);
}

/// Decoded single row from a `TCG1` cell batch.
class DecodedTcg1Row {
  const DecodedTcg1Row({
    required this.rowIndex,
    required this.storedCols,
    required this.logicalCols,
    required this.flags,
    required this.cellWords,
    this.combining,
  });

  final int rowIndex;
  final int storedCols;
  final int logicalCols;
  final int flags;

  /// Packed `storedCols * 4` words (`[fg, bg, attrFlags, content]`).
  final Uint32List cellWords;

  /// Optional map from `col` -> extra combining codepoints on that cell.
  final Map<int, List<int>>? combining;

  bool get wrapsNext => (flags & kLineFlagWrapsNext) != 0;
}

/// Normalizes a decoded wire scalar value to a valid Unicode scalar (`0` for
/// empty cells, `0xFFFD` for UTF-16 surrogates or values above `0x10FFFF`).
int sanitizeTerminalCodePoint(int cp) {
  if (cp <= 0) return 0;
  if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
    return 0xFFFD;
  }
  return cp;
}

class _BoundedOutputMemoryStream extends OutputMemoryStream {
  _BoundedOutputMemoryStream({required this.maxBytes}) : super(size: 0x8000);

  final int maxBytes;

  void _checkAdd(int count) {
    if (length + count > maxBytes) {
      throw FormatException(
        'Decompressed TCG1 batch exceeds 16 MiB cap (${length + count})',
      );
    }
  }

  @override
  void writeByte(int value) {
    _checkAdd(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final writeLen = length ?? bytes.length;
    _checkAdd(writeLen);
    super.writeBytes(bytes, length: writeLen);
  }

  @override
  void writeStream(InputStream stream) {
    _checkAdd(stream.length);
    super.writeStream(stream);
  }
}

/// Pure-Dart bounded zlib decompressor used on Flutter Web (and exposed for
/// direct VM unit testing). Retains the 4-byte big-endian Adler-32 trailer on
/// [InputMemoryStream] so `Inflate`'s 15-bit Huffman lookahead is never starved
/// at block boundaries, and verifies `CINFO <= 7`, stream consumption, and the
/// Adler-32 checksum.
@visibleForTesting
Uint8List decompressTcg1ZlibPureDart(Uint8List payload, int maxBytes) {
  if (payload.length < 6) {
    throw const FormatException('Truncated TCG1 zlib stream');
  }
  final cmf = payload[0];
  final flg = payload[1];
  if ((cmf & 0x0F) != 8 || (cmf >>> 4) > 7 || (((cmf << 8) | flg) % 31) != 0) {
    throw const FormatException('Invalid TCG1 zlib header');
  }
  if ((flg & 0x20) != 0) {
    throw const FormatException('Preset dictionary not supported in TCG1');
  }
  final input = InputMemoryStream(
    payload,
    byteOrder: ByteOrder.bigEndian,
    offset: 2,
  );
  final bounded = _BoundedOutputMemoryStream(maxBytes: maxBytes);
  Inflate.stream(input, output: bounded);
  if (input.length != 4) {
    throw FormatException(
      'Trailing or truncated TCG1 zlib stream (remaining=${input.length})',
    );
  }
  final expectedAdler = input.readUint32().toUnsigned(32);
  final out = bounded.getBytes();
  final actualAdler = getAdler32(out).toUnsigned(32);
  if (actualAdler != expectedAdler) {
    throw FormatException(
      'TCG1 zlib Adler-32 mismatch (expected=0x${expectedAdler.toRadixString(16)}, actual=0x${actualAdler.toRadixString(16)})',
    );
  }
  return out;
}

Uint8List _decompressZlibBounded(Uint8List payload, int maxBytes) {
  try {
    if (kIsWeb) {
      return decompressTcg1ZlibPureDart(payload, maxBytes);
    }
    final bounded = _BoundedOutputMemoryStream(maxBytes: maxBytes);
    final ok = const ZLibDecoder().decodeStream(
      InputMemoryStream(payload),
      bounded,
    );
    if (!ok) {
      throw const FormatException('Failed to decompress TCG1 zlib payload');
    }
    return bounded.getBytes();
  } on FormatException {
    rethrow;
  } on Object catch (err) {
    throw FormatException('Invalid TCG1 zlib payload: $err');
  }
}

/// Decodes a `TCG1` payload (`compression == 0` raw or `compression == 1` zlib)
/// into structured cell rows.
List<DecodedTcg1Row> decodeTcg1Batch(int compression, Uint8List payload) {
  if (payload.isEmpty) {
    return const <DecodedTcg1Row>[];
  }

  Uint8List raw;
  switch (compression) {
    case kCellCompressionNone:
      if (payload.length > kMaxDecompressedTcg1Bytes) {
        throw FormatException(
          'Raw TCG1 batch exceeds 16 MiB cap (${payload.length})',
        );
      }
      raw = payload;
    case kCellCompressionZlib:
      raw = _decompressZlibBounded(payload, kMaxDecompressedTcg1Bytes);
    default:
      throw FormatException('Unsupported TCG1 compression code: $compression');
  }

  if (raw.length < 12 || (raw.length & 3) != 0) {
    throw FormatException('Invalid TCG1 byte length: ${raw.length}');
  }

  final bd = ByteData.sublistView(raw);
  final totalWords = raw.length >>> 2;
  int wordAt(int wordIdx) => bd.getUint32(wordIdx << 2, Endian.little);

  final magic = wordAt(0);
  if (magic != kTcg1Magic) {
    throw FormatException('Invalid TCG1 magic: 0x${magic.toRadixString(16)}');
  }
  final lineCount = wordAt(1);
  final combiningCount = wordAt(2);
  final headersEnd = 3 + lineCount * 2;
  if (lineCount < 0 || lineCount > 0x10000 || headersEnd > totalWords) {
    throw const FormatException('TCG1 truncated or oversized in line headers');
  }

  final rows = <DecodedTcg1Row>[];
  var cellCursor = headersEnd;
  for (var i = 0; i < lineCount; i++) {
    final rowIndex = wordAt(3 + i * 2);
    final meta = wordAt(3 + i * 2 + 1);
    final storedCols = meta & 0x0FFF;
    final logicalCols = (meta >>> 12) & 0x0FFF;
    final flags = (meta >>> 24) & 0xFF;
    if (rowIndex < 0 || rowIndex >= 0x10000) {
      throw FormatException('TCG1 row index out of bounds: $rowIndex');
    }
    if (storedCols > logicalCols) {
      throw FormatException(
        'TCG1 storedCols ($storedCols) exceeds logicalCols ($logicalCols)',
      );
    }
    final wordsLen = storedCols * kCellWords;
    if (cellCursor + wordsLen > totalWords) {
      throw const FormatException('TCG1 truncated in cell words');
    }

    final Uint32List cellWords;
    if (wordsLen == 0) {
      cellWords = Uint32List(0);
    } else if (Endian.host == Endian.little &&
        ((raw.offsetInBytes + (cellCursor << 2)) & 3) == 0) {
      // Copy into compact owned Uint32List so retaining a single scrolled row
      // never pins the entire decompressed frame buffer in memory.
      cellWords = Uint32List.fromList(
        Uint32List.sublistView(
          raw,
          cellCursor << 2,
          (cellCursor + wordsLen) << 2,
        ),
      );
    } else {
      cellWords = Uint32List(wordsLen);
      for (var w = 0; w < wordsLen; w++) {
        cellWords[w] = wordAt(cellCursor + w);
      }
    }
    for (var col = 0; col < storedCols; col++) {
      final contentIdx = col * kCellWords + 3;
      final content = cellWords[contentIdx];
      final cp = content & kContentCodepointMask;
      if (cp != 0) {
        final safeCp = sanitizeTerminalCodePoint(cp);
        if (safeCp != cp) {
          cellWords[contentIdx] = (content & ~kContentCodepointMask) | safeCp;
        }
      }
    }
    cellCursor += wordsLen;
    rows.add(
      DecodedTcg1Row(
        rowIndex: rowIndex,
        storedCols: storedCols,
        logicalCols: logicalCols,
        flags: flags,
        cellWords: cellWords,
        combining: (flags & kLineFlagHasCombining) != 0
            ? <int, List<int>>{}
            : null,
      ),
    );
  }

  final combWords = combiningCount * 3;
  if (combiningCount < 0 || cellCursor + combWords != totalWords) {
    throw const FormatException('TCG1 word count mismatch');
  }
  for (var c = 0; c < combiningCount; c++) {
    final base = cellCursor + c * 3;
    final lineIdx = wordAt(base);
    final col = wordAt(base + 1);
    final rawCp = wordAt(base + 2);
    if (lineIdx < 0 || lineIdx >= rows.length) {
      throw FormatException(
        'TCG1 combining line index out of bounds: $lineIdx',
      );
    }
    final target = rows[lineIdx];
    if (col < 0 || col >= target.storedCols) {
      throw FormatException('TCG1 combining column out of bounds: $col');
    }
    final safeCp = sanitizeTerminalCodePoint(rawCp == 0 ? 0xFFFD : rawCp);
    final map = target.combining;
    if (map != null) {
      (map[col] ??= <int>[]).add(safeCp);
    }
  }

  return rows;
}

/// Encodes plain text or styled rows into an uncompressed `TCG1` payload.
/// Useful for unit tests and `FakeTriageWebSocketClient`.
Uint8List encodeTcg1PlainTextRows(
  List<String> lines, {
  int cols = 80,
  int startRowIndex = 0,
  Set<int> wrappedRowIndices = const <int>{},
}) {
  if (lines.isEmpty) return Uint8List(0);
  final clampedStart = startRowIndex.clamp(0, 0xFFFF);
  final maxLineCount = (0x10000 - clampedStart).clamp(0, lines.length);
  if (maxLineCount <= 0) return Uint8List(0);
  final clampedCols = cols.clamp(1, kMaxEncodedCols);
  final headers = <int>[];
  final cells = <int>[];
  final combining = <int>[];

  for (var i = 0; i < maxLineCount; i++) {
    final rowIndex = clampedStart + i;
    final text = lines[i];
    final runes = text.runes.toList();
    final rowWords = <int>[];
    var col = 0;
    var lastBaseCol = -1;
    var hasCombining = false;
    for (final rune in runes) {
      if (_isControlRune(rune)) {
        continue;
      }
      final width = _approxRuneCellWidth(rune);
      if (width == 0) {
        if (lastBaseCol >= 0) {
          final safeComb = sanitizeTerminalCodePoint(rune);
          combining
            ..add(i)
            ..add(lastBaseCol)
            ..add(safeComb);
          rowWords[lastBaseCol * kCellWords + 3] |= kContentHasCombining;
          hasCombining = true;
        }
        continue;
      }
      if (col >= clampedCols) {
        lastBaseCol = -1;
        break;
      }
      final effectiveWidth = (width == 2 && col + 1 >= clampedCols) ? 1 : width;
      final safeRune = sanitizeTerminalCodePoint(rune);
      final content =
          (safeRune & kContentCodepointMask) |
          (effectiveWidth << kContentWidthShift);
      lastBaseCol = col;
      rowWords
        ..add(kColorNormal)
        ..add(kColorNormal)
        ..add(0)
        ..add(content);
      if (effectiveWidth == 2) {
        rowWords
          ..add(kColorNormal)
          ..add(kColorNormal)
          ..add(0)
          ..add(0);
        col += 2;
      } else {
        col += 1;
      }
    }
    final storedCols = col.clamp(0, clampedCols);
    var flags = wrappedRowIndices.contains(rowIndex) ? kLineFlagWrapsNext : 0;
    if (hasCombining) flags |= kLineFlagHasCombining;
    final meta = storedCols | (clampedCols << 12) | (flags << 24);
    headers
      ..add(rowIndex)
      ..add(meta);
    cells.addAll(rowWords.take(storedCols * kCellWords));
  }

  final totalWords = 3 + headers.length + cells.length + combining.length;
  final out = Uint8List(totalWords * 4);
  final bd = ByteData.sublistView(out);
  var cursor = 0;
  void writeWord(int w) {
    bd.setUint32(cursor, w, Endian.little);
    cursor += 4;
  }

  writeWord(kTcg1Magic);
  writeWord(maxLineCount);
  writeWord(combining.length ~/ 3);
  for (final w in headers) {
    writeWord(w);
  }
  for (final w in cells) {
    writeWord(w);
  }
  for (final w in combining) {
    writeWord(w);
  }
  return out;
}

/// Encodes [StyledRow] items into an uncompressed `TCG1` payload, preserving
/// bold, dim, italic, underline, reverse, and RGB foreground/background colors.
Uint8List encodeTcg1StyledRows(
  List<StyledRow> rows, {
  int cols = 80,
  int startRowIndex = 0,
}) {
  if (rows.isEmpty) return Uint8List(0);
  final clampedStart = startRowIndex.clamp(0, 0xFFFF);
  final maxRowCount = (0x10000 - clampedStart).clamp(0, rows.length);
  if (maxRowCount <= 0) return Uint8List(0);
  final clampedCols = cols.clamp(1, kMaxEncodedCols);
  final headers = <int>[];
  final cells = <int>[];
  final combining = <int>[];

  for (var i = 0; i < maxRowCount; i++) {
    final rowIndex = clampedStart + i;
    final rowWords = <int>[];
    var col = 0;
    var lastBaseCol = -1;
    var hasCombining = false;
    var truncated = false;
    for (final span in rows[i].spans) {
      if (truncated) break;
      final style = span.style;
      final fg = style.foreground == null
          ? kColorNormal
          : (kColorRgb |
                ((style.foreground!.red & 0xFF) << 16) |
                ((style.foreground!.green & 0xFF) << 8) |
                (style.foreground!.blue & 0xFF));
      final bg = style.background == null
          ? kColorNormal
          : (kColorRgb |
                ((style.background!.red & 0xFF) << 16) |
                ((style.background!.green & 0xFF) << 8) |
                (style.background!.blue & 0xFF));
      var attrs = 0;
      if (style.bold) attrs |= kAttrBold;
      if (style.dim) attrs |= kAttrFaint;
      if (style.italic) attrs |= kAttrItalic;
      if (style.underline) attrs |= kAttrUnderline;
      if (style.reverse) attrs |= kAttrInverse;

      for (final rune in span.text.runes) {
        if (_isControlRune(rune)) {
          continue;
        }
        final width = _approxRuneCellWidth(rune);
        if (width == 0) {
          if (lastBaseCol >= 0) {
            final safeComb = sanitizeTerminalCodePoint(rune);
            combining
              ..add(i)
              ..add(lastBaseCol)
              ..add(safeComb);
            rowWords[lastBaseCol * kCellWords + 3] |= kContentHasCombining;
            hasCombining = true;
          }
          continue;
        }
        if (col >= clampedCols) {
          lastBaseCol = -1;
          truncated = true;
          break;
        }
        final effectiveWidth = (width == 2 && col + 1 >= clampedCols)
            ? 1
            : width;
        final safeRune = sanitizeTerminalCodePoint(rune);
        final content =
            (safeRune & kContentCodepointMask) |
            (effectiveWidth << kContentWidthShift);
        lastBaseCol = col;
        rowWords
          ..add(fg)
          ..add(bg)
          ..add(attrs)
          ..add(content);
        if (effectiveWidth == 2) {
          rowWords
            ..add(fg)
            ..add(bg)
            ..add(attrs)
            ..add(0);
          col += 2;
        } else {
          col += 1;
        }
      }
    }
    final storedCols = col.clamp(0, clampedCols);
    final flags = hasCombining ? kLineFlagHasCombining : 0;
    final meta = storedCols | (clampedCols << 12) | (flags << 24);
    headers
      ..add(rowIndex)
      ..add(meta);
    cells.addAll(rowWords.take(storedCols * kCellWords));
  }

  final totalWords = 3 + headers.length + cells.length + combining.length;
  final out = Uint8List(totalWords * 4);
  final bd = ByteData.sublistView(out);
  var cursor = 0;
  void writeWord(int w) {
    bd.setUint32(cursor, w, Endian.little);
    cursor += 4;
  }

  writeWord(kTcg1Magic);
  writeWord(maxRowCount);
  writeWord(combining.length ~/ 3);
  for (final w in headers) {
    writeWord(w);
  }
  for (final w in cells) {
    writeWord(w);
  }
  for (final w in combining) {
    writeWord(w);
  }
  return out;
}

/// Upper bound on decoded viewport height so malformed envelopes cannot trigger
/// unbounded line-buffer allocations.
const int kMaxViewportRows = 4096;

/// Upper bounds on virtual scrollback row counts and trimmed-top offsets so
/// malformed wire envelopes cannot overflow 64-bit integers, exceed JS 53-bit
/// safe-integer precision on Web, or stall scrollback range loops.
const int kMaxScrollbackRows = 1 << 24;
const int kMaxTrimmedTopRows = 1 << 50;
const int kMaxWireSafeInt = 0x1FFFFFFFFFFFFF;

bool _isControlRune(int rune) => rune < 0x20 || (rune >= 0x7F && rune < 0xA0);

int _wireIntField(Map<String, dynamic> map, String key, int fallback) {
  final raw = map[key];
  if (raw is int) {
    return raw.clamp(-kMaxWireSafeInt, kMaxWireSafeInt);
  }
  if (raw is num && raw.isFinite) {
    if (raw >= kMaxWireSafeInt) return kMaxWireSafeInt;
    if (raw <= -kMaxWireSafeInt) return -kMaxWireSafeInt;
    return raw.toInt();
  }
  return fallback;
}

String? _wireOptionalStringField(Map<String, dynamic> map, String key) {
  final raw = map[key];
  return raw is String ? raw : null;
}

int _approxRuneCellWidth(int rune) {
  if (_isControlRune(rune)) return 0;
  if ((rune >= 0x0300 && rune <= 0x036F) ||
      (rune >= 0x1AB0 && rune <= 0x1AFF) ||
      (rune >= 0x1DC0 && rune <= 0x1DFF) ||
      (rune >= 0x20D0 && rune <= 0x20FF) ||
      (rune >= 0xFE20 && rune <= 0xFE2F)) {
    return 0;
  }
  if (rune >= 0x1100 &&
      (rune <= 0x115F ||
          rune == 0x2329 ||
          rune == 0x232A ||
          (rune >= 0x2E80 && rune <= 0xA4CF && rune != 0x303F) ||
          (rune >= 0xAC00 && rune <= 0xD7A3) ||
          (rune >= 0xF900 && rune <= 0xFAFF) ||
          (rune >= 0xFE10 && rune <= 0xFE19) ||
          (rune >= 0xFE30 && rune <= 0xFE6F) ||
          (rune >= 0xFF00 && rune <= 0xFF60) ||
          (rune >= 0xFFE0 && rune <= 0xFFE6) ||
          (rune >= 0x1F300 && rune <= 0x1F9FF) ||
          (rune >= 0x20000 && rune <= 0x3FFFD))) {
    return 2;
  }
  return 1;
}

/// Decoded wire envelope for `TerminalSyncFrame`.
class TerminalSyncFrameData {
  const TerminalSyncFrameData({
    required this.frameSeq,
    required this.rows,
    required this.cols,
    required this.totalScrollbackRows,
    required this.trimmedTopRows,
    required this.eraseScrollbackGen,
    required this.cursorX,
    required this.cursorY,
    required this.cursorStyle,
    required this.modeFlags,
    required this.mouseMode,
    required this.mouseReportMode,
    required this.kittyKeyboardFlags,
    required this.title,
    required this.viewportCompression,
    required this.viewportPayload,
    required this.pushedScrollbackStartRow,
    required this.pushedScrollbackRowCount,
    required this.pushedScrollbackCompression,
    required this.pushedScrollbackPayload,
  });

  factory TerminalSyncFrameData.fromMap(Map<String, dynamic> map) {
    return TerminalSyncFrameData(
      frameSeq: _wireIntField(map, 'frame_seq', 0),
      rows: _wireIntField(map, 'rows', 24).clamp(1, kMaxViewportRows),
      cols: _wireIntField(map, 'cols', 80).clamp(1, kMaxEncodedCols),
      totalScrollbackRows: _wireIntField(
        map,
        'total_scrollback_rows',
        0,
      ).clamp(0, kMaxScrollbackRows),
      trimmedTopRows: _wireIntField(
        map,
        'trimmed_top_rows',
        0,
      ).clamp(0, kMaxTrimmedTopRows),
      eraseScrollbackGen: _wireIntField(
        map,
        'erase_scrollback_gen',
        0,
      ).clamp(0, kMaxWireSafeInt),
      cursorX: _wireIntField(map, 'cursor_x', 0),
      cursorY: _wireIntField(map, 'cursor_y', 0),
      cursorStyle: _wireIntField(map, 'cursor_style', 0),
      modeFlags: _wireIntField(map, 'mode_flags', 0),
      mouseMode: _wireIntField(map, 'mouse_mode', 0),
      mouseReportMode: _wireIntField(map, 'mouse_report_mode', 0),
      kittyKeyboardFlags: _wireIntField(map, 'kitty_keyboard_flags', 0),
      title: _wireOptionalStringField(map, 'title'),
      viewportCompression: _wireIntField(map, 'viewport_compression', 0),
      viewportPayload: tcg1BytesFromField(map['viewport_payload']),
      pushedScrollbackStartRow: _wireIntField(
        map,
        'pushed_scrollback_start_row',
        0,
      ).clamp(-1, kMaxScrollbackRows),
      pushedScrollbackRowCount: _wireIntField(
        map,
        'pushed_scrollback_row_count',
        0,
      ).clamp(-1, kMaxScrollbackRows),
      pushedScrollbackCompression: _wireIntField(
        map,
        'pushed_scrollback_compression',
        0,
      ),
      pushedScrollbackPayload: tcg1BytesFromField(
        map['pushed_scrollback_payload'],
      ),
    );
  }

  final int frameSeq;
  final int rows;
  final int cols;
  final int totalScrollbackRows;
  final int trimmedTopRows;
  final int eraseScrollbackGen;
  final int cursorX;
  final int cursorY;
  final int cursorStyle;
  final int modeFlags;
  final int mouseMode;
  final int mouseReportMode;
  final int kittyKeyboardFlags;
  final String? title;
  final int viewportCompression;
  final Uint8List viewportPayload;
  final int pushedScrollbackStartRow;
  final int pushedScrollbackRowCount;
  final int pushedScrollbackCompression;
  final Uint8List pushedScrollbackPayload;

  bool get isAltScreen => (modeFlags & kModeAltScreen) != 0;
  bool get cursorVisible => (modeFlags & kModeCursorVisible) != 0;
  bool get bracketedPaste => (modeFlags & kModeBracketedPaste) != 0;
  bool get appCursorKeys => (modeFlags & kModeAppCursorKeys) != 0;
  bool get appKeypad => (modeFlags & kModeAppKeypad) != 0;
  bool get originMode => (modeFlags & kModeOrigin) != 0;
  bool get autoWrap => (modeFlags & kModeAutoWrap) != 0;
  bool get reportFocus => (modeFlags & kModeReportFocus) != 0;
  bool get sawEraseScrollback => (modeFlags & kModeSawEraseScrollback) != 0;
  bool get sawEraseDisplay => (modeFlags & kModeSawEraseDisplay) != 0;
  bool get bellRang => (modeFlags & kModeBellRang) != 0;
  bool get titleChanged => (modeFlags & kModeTitleChanged) != 0;
  bool get reverseVideo => (modeFlags & kModeReverseVideo) != 0;
  bool get fullViewport => (modeFlags & kModeFullViewport) != 0;
}

/// Decoded wire envelope for `FetchTerminalRowsResponse`.
class TerminalRowsPageData {
  const TerminalRowsPageData({
    required this.sessionId,
    required this.startRow,
    required this.rowCount,
    required this.totalScrollbackRows,
    required this.trimmedTopRows,
    required this.eraseScrollbackGen,
    required this.compression,
    required this.payload,
  });

  factory TerminalRowsPageData.fromMap(Map<String, dynamic> map) {
    final inner = map['response'] is Map<String, dynamic>
        ? map['response'] as Map<String, dynamic>
        : (map['response'] is Map
              ? Map<String, dynamic>.from(map['response'] as Map)
              : map);
    return TerminalRowsPageData(
      sessionId: _wireOptionalStringField(inner, 'session_id') ?? '',
      startRow: _wireIntField(
        inner,
        'start_row',
        0,
      ).clamp(-1, kMaxScrollbackRows),
      rowCount: _wireIntField(inner, 'row_count', 0).clamp(-1, 0x10000),
      totalScrollbackRows: _wireIntField(
        inner,
        'total_scrollback_rows',
        0,
      ).clamp(-1, kMaxScrollbackRows),
      trimmedTopRows: _wireIntField(
        inner,
        'trimmed_top_rows',
        0,
      ).clamp(0, kMaxTrimmedTopRows),
      eraseScrollbackGen: _wireIntField(inner, 'erase_scrollback_gen', 0),
      compression: _wireIntField(inner, 'compression', 0),
      payload: tcg1BytesFromField(inner['payload']),
    );
  }

  final String sessionId;
  final int startRow;
  final int rowCount;
  final int totalScrollbackRows;
  final int trimmedTopRows;
  final int eraseScrollbackGen;
  final int compression;
  final Uint8List payload;
}
