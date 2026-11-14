import 'dart:math' show max, min;

import 'package:flutter/foundation.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_selection.dart';

const int _kMaxWrappedRowSpan = 32;

/// Half-open column span `[startCol, endCol)` on a single [virtualRow] covered
/// by a detected [TerminalLink].
@immutable
class TerminalLinkSegment {
  const TerminalLinkSegment({
    required this.virtualRow,
    required this.startCol,
    required this.endCol,
  });

  final int virtualRow;
  final int startCol;
  final int endCol;

  bool containsCol(int col) => col >= startCol && col < endCol;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TerminalLinkSegment &&
          other.virtualRow == virtualRow &&
          other.startCol == startCol &&
          other.endCol == endCol);

  @override
  int get hashCode => Object.hash(virtualRow, startCol, endCol);

  @override
  String toString() =>
      'TerminalLinkSegment(row: $virtualRow, cols: [$startCol, $endCol))';
}

/// A clickable `http://` or `https://` URL detected across one or more
/// logical terminal rows.
@immutable
class TerminalLink {
  const TerminalLink({
    required this.url,
    required this.uri,
    required this.segments,
  });

  final String url;
  final Uri uri;
  final List<TerminalLinkSegment> segments;

  bool containsCell(CellOffset cell) {
    for (final seg in segments) {
      if (seg.virtualRow == cell.y && seg.containsCol(cell.x)) {
        return true;
      }
    }
    return false;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TerminalLink &&
          other.url == url &&
          listEquals(other.segments, segments));

  @override
  int get hashCode => Object.hash(url, Object.hashAll(segments));

  @override
  String toString() => 'TerminalLink($url, segments: $segments)';
}

final RegExp _urlPattern = RegExp(
  r'''https?://[^\s\x00-\x1f\x7f<>"'`\\^{}|\u2500-\u259f]+''',
  caseSensitive: false,
);

/// Detects all clickable `http://` and `https://` URLs whose logical lines
/// intersect `[firstRow, lastRowExclusive)` in [buffer].
///
/// Soft-wrapped rows (`wrapsNext == true`) are joined across row boundaries so
/// wrapped URLs are returned as a single [TerminalLink] with per-row segments.
List<TerminalLink> detectLinksInRowRange(
  TerminalCellBuffer buffer,
  int firstRow,
  int lastRowExclusive,
) {
  final total = buffer.totalLines;
  if (total <= 0 || buffer.viewWidth <= 0) {
    return const <TerminalLink>[];
  }
  final start = firstRow.clamp(0, total);
  final end = lastRowExclusive.clamp(start, total);
  if (start >= end) {
    return const <TerminalLink>[];
  }

  final links = <TerminalLink>[];
  var row = start;
  while (row < end) {
    if (buffer.lineAtVirtualRow(row) == null) {
      row += 1;
      continue;
    }

    var logicalStart = row;
    while (logicalStart > 0 && (row - logicalStart) < _kMaxWrappedRowSpan) {
      final prev = buffer.lineAtVirtualRow(logicalStart - 1);
      if (prev == null || !prev.wrapsNext) {
        break;
      }
      logicalStart -= 1;
    }

    var logicalEnd = row;
    while (logicalEnd + 1 < total &&
        (logicalEnd - logicalStart) < _kMaxWrappedRowSpan) {
      final cur = buffer.lineAtVirtualRow(logicalEnd);
      if (cur == null || !cur.wrapsNext) {
        break;
      }
      if (buffer.lineAtVirtualRow(logicalEnd + 1) == null) {
        break;
      }
      logicalEnd += 1;
    }

    _extractLinksFromLogicalLine(buffer, logicalStart, logicalEnd, links);
    row = logicalEnd + 1;
  }

  return links;
}

/// Returns the [TerminalLink] at [cell] in [buffer], or `null` if none covers
/// that cell.
TerminalLink? detectLinkAtCell(TerminalCellBuffer buffer, CellOffset cell) {
  if (cell.y < 0 || cell.y >= buffer.totalLines) {
    return null;
  }
  if (cell.x < 0 || cell.x >= buffer.viewWidth) {
    return null;
  }
  final links = detectLinksInRowRange(buffer, cell.y, cell.y + 1);
  for (final link in links) {
    if (link.containsCell(cell)) {
      return link;
    }
  }
  return null;
}

void _extractLinksFromLogicalLine(
  TerminalCellBuffer buffer,
  int logicalStart,
  int logicalEnd,
  List<TerminalLink> out,
) {
  // Fast pre-check: avoid allocating buffers when no row contains `:`.
  var mightHaveUrl = false;
  for (var r = logicalStart; r <= logicalEnd; r++) {
    final line = buffer.lineAtVirtualRow(r);
    if (line == null) continue;
    final maxCols = min(line.storedCols, buffer.viewWidth);
    for (var c = 0; c < maxCols; c++) {
      if (line.getCodePoint(c) == 0x3A /* ':' */ ) {
        mightHaveUrl = true;
        break;
      }
    }
    if (mightHaveUrl) break;
  }
  if (!mightHaveUrl) return;

  final textBuf = StringBuffer();
  final unitRows = <int>[];
  final unitCols = <int>[];
  final unitWidths = <int>[];

  void emitCodePoint(int cp, int row, int col, int width) {
    final prevLen = textBuf.length;
    textBuf.writeCharCode(cp);
    final units = textBuf.length - prevLen;
    for (var i = 0; i < units; i++) {
      unitRows.add(row);
      unitCols.add(col);
      unitWidths.add(width);
    }
  }

  for (var r = logicalStart; r <= logicalEnd; r++) {
    final line = buffer.lineAtVirtualRow(r);
    if (line == null) break;
    final maxCols = min(line.storedCols, buffer.viewWidth);

    var lastGlyph = -1;
    for (var c = 0; c < maxCols; c++) {
      if (line.getCodePoint(c) != 0) {
        lastGlyph = c;
      }
    }
    if (lastGlyph < 0) continue;

    for (var c = 0; c <= lastGlyph; c++) {
      final cp = line.getCodePoint(c);
      if (cp != 0) {
        final width = line.getWidth(c) == 2 ? 2 : 1;
        emitCodePoint(cp, r, c, width);
        final extra = line.getCombining(c);
        if (extra != null) {
          for (final comb in extra) {
            emitCodePoint(comb, r, c, width);
          }
        }
      } else {
        final isWideTrailer =
            c > 0 && line.getWidth(c - 1) == 2 && line.getWidth(c) == 0;
        if (!isWideTrailer) {
          emitCodePoint(0x20, r, c, 1);
        }
      }
    }
  }

  final text = textBuf.toString();
  if (text.isEmpty) return;

  for (final match in _urlPattern.allMatches(text)) {
    final start = match.start;
    var end = _trimTrailingPunctuation(text, start, match.end);
    if (end <= start) continue;

    final candidate = text.substring(start, end);
    final uri = Uri.tryParse(candidate);
    if (uri == null) continue;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') continue;
    if (uri.host.isEmpty) continue;
    if (candidate.length <= scheme.length + 3) continue;

    final segments = _buildSegments(
      unitRows: unitRows,
      unitCols: unitCols,
      unitWidths: unitWidths,
      start: start,
      end: end,
    );
    if (segments.isEmpty) continue;

    out.add(TerminalLink(url: candidate, uri: uri, segments: segments));
  }
}

int _trimTrailingPunctuation(String text, int start, int end) {
  while (end > start) {
    final cu = text.codeUnitAt(end - 1);
    if (cu == 0x2E /* . */ ||
        cu == 0x2C /* , */ ||
        cu == 0x3B /* ; */ ||
        cu == 0x3A /* : */ ||
        cu == 0x21 /* ! */ ||
        cu == 0x3F /* ? */ ||
        cu == 0x27 /* ' */ ||
        cu == 0x22 /* " */ ||
        cu == 0x60 /* ` */ ||
        cu == 0x3E /* > */ ||
        cu == 0x3C /* < */ ||
        cu == 0x5C /* \ */ ||
        cu == 0x7C /* | */ ||
        cu == 0x7D /* } */ ||
        cu == 0x7B /* { */ ) {
      end -= 1;
      continue;
    }
    if (cu == 0x29 /* ) */ ) {
      if (_countCodeUnit(text, start, end, 0x29) >
          _countCodeUnit(text, start, end, 0x28)) {
        end -= 1;
        continue;
      }
      break;
    }
    if (cu == 0x5D /* ] */ ) {
      if (_countCodeUnit(text, start, end, 0x5D) >
          _countCodeUnit(text, start, end, 0x5B)) {
        end -= 1;
        continue;
      }
      break;
    }
    break;
  }
  return end;
}

int _countCodeUnit(String text, int start, int end, int target) {
  var count = 0;
  for (var i = start; i < end; i++) {
    if (text.codeUnitAt(i) == target) {
      count += 1;
    }
  }
  return count;
}

List<TerminalLinkSegment> _buildSegments({
  required List<int> unitRows,
  required List<int> unitCols,
  required List<int> unitWidths,
  required int start,
  required int end,
}) {
  final segments = <TerminalLinkSegment>[];
  int? curRow;
  var curStartCol = 0;
  var curEndCol = 0;

  for (var i = start; i < end; i++) {
    final r = unitRows[i];
    final c = unitCols[i];
    final w = unitWidths[i];
    if (curRow == null) {
      curRow = r;
      curStartCol = c;
      curEndCol = c + w;
    } else if (curRow == r) {
      curStartCol = min(curStartCol, c);
      curEndCol = max(curEndCol, c + w);
    } else {
      segments.add(
        TerminalLinkSegment(
          virtualRow: curRow,
          startCol: curStartCol,
          endCol: curEndCol,
        ),
      );
      curRow = r;
      curStartCol = c;
      curEndCol = c + w;
    }
  }

  if (curRow != null) {
    segments.add(
      TerminalLinkSegment(
        virtualRow: curRow,
        startCol: curStartCol,
        endCol: curEndCol,
      ),
    );
  }
  return segments;
}
