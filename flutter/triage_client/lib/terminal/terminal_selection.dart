import 'package:flutter/foundation.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';

/// Zero-based `(x: col, y: virtualRow)` coordinate in a [TerminalCellBuffer].
@immutable
class CellOffset {
  const CellOffset(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CellOffset && other.x == x && other.y == y);

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'CellOffset($x, $y)';
}

@immutable
class TerminalSelectionSegment {
  const TerminalSelectionSegment({
    required this.line,
    this.start,
    this.end,
  });

  final int line;
  final int? start;
  final int? end;
}

/// Half-open selection range over a [TerminalCellBuffer], tracking both the
/// scrollback clear generation (`eraseScrollbackGen`) and top-trim baseline
/// (`trimmedTopRows`) at the moment the selection was created.
@immutable
class TerminalSelectionRange {
  const TerminalSelectionRange(
    this.base,
    this.extent, {
    this.trimmedTopRows = 0,
    this.eraseScrollbackGen = 0,
    this.isAltScreen = false,
  });

  final CellOffset base;
  final CellOffset extent;
  final int trimmedTopRows;
  final int eraseScrollbackGen;
  final bool isAltScreen;

  bool get isCollapsed => base == extent;

  /// Returns `(begin, end)` in normalized `(row, col)` order without applying
  /// top-trim compensation.
  (CellOffset begin, CellOffset end) get normalized {
    final forward =
        extent.y > base.y || (extent.y == base.y && extent.x >= base.x);
    return forward ? (base, extent) : (extent, base);
  }

  /// Returns `(begin, end)` shifted into [buffer]'s current virtual row space
  /// after accounting for any top retention trims since the selection started.
  (CellOffset begin, CellOffset end) normalizedIn(TerminalCellBuffer buffer) {
    final delta = isAltScreen ? 0 : (trimmedTopRows - buffer.trimmedTopRows);
    final shiftedBase = CellOffset(base.x, base.y + delta);
    final shiftedExtent = CellOffset(extent.x, extent.y + delta);
    final forward =
        shiftedExtent.y > shiftedBase.y ||
        (shiftedExtent.y == shiftedBase.y && shiftedExtent.x >= shiftedBase.x);
    return forward
        ? (shiftedBase, shiftedExtent)
        : (shiftedExtent, shiftedBase);
  }

  /// Per-line half-open `[start, end)` segments in [buffer]'s current virtual
  /// row space.
  Iterable<TerminalSelectionSegment> toSegmentsIn(
    TerminalCellBuffer buffer,
  ) sync* {
    final (begin, end) = normalizedIn(buffer);
    if (begin == end) return;
    if (begin.y == end.y) {
      yield TerminalSelectionSegment(line: begin.y, start: begin.x, end: end.x);
      return;
    }
    yield TerminalSelectionSegment(line: begin.y, start: begin.x);
    for (var row = begin.y + 1; row < end.y; row++) {
      yield TerminalSelectionSegment(line: row);
    }
    if (end.x > 0) {
      yield TerminalSelectionSegment(line: end.y, start: 0, end: end.x);
    }
  }

  /// Column range `[startCol, endCol)` selected on [virtualRow], or `null` when
  /// [virtualRow] is outside the selection.
  (int startCol, int endCol)? selectedColsOnRow(
    TerminalCellBuffer buffer,
    int virtualRow,
  ) {
    if (isAltScreen != buffer.isUsingAltBuffer) return null;
    if (eraseScrollbackGen != buffer.eraseScrollbackGen) return null;
    final (begin, end) = normalizedIn(buffer);
    if (begin == end) return null;
    if (virtualRow < begin.y || virtualRow > end.y) return null;
    final cols = buffer.viewWidth;
    if (begin.y == end.y) {
      final s = begin.x.clamp(0, cols);
      final e = end.x.clamp(s, cols);
      return e > s ? (s, e) : null;
    }
    if (virtualRow == begin.y) {
      final s = begin.x.clamp(0, cols);
      return cols > s ? (s, cols) : null;
    }
    if (virtualRow == end.y) {
      final e = end.x.clamp(0, cols);
      return e > 0 ? (0, e) : null;
    }
    return cols > 0 ? (0, cols) : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TerminalSelectionRange &&
          other.base == base &&
          other.extent == extent &&
          other.trimmedTopRows == trimmedTopRows &&
          other.eraseScrollbackGen == eraseScrollbackGen &&
          other.isAltScreen == isAltScreen);

  @override
  int get hashCode => Object.hash(
    base,
    extent,
    trimmedTopRows,
    eraseScrollbackGen,
    isAltScreen,
  );
}

/// Whether [range] still refers to live rows in [buffer] on its original
/// screen without having been invalidated by `CSI 3J` or trimmed past row 0.
bool terminalSelectionIsLive(
  TerminalCellBuffer buffer,
  TerminalSelectionRange range,
) {
  if (range.isCollapsed) return false;
  if (range.eraseScrollbackGen != buffer.eraseScrollbackGen) return false;
  final (begin, end) = range.normalizedIn(buffer);
  return begin.y >= 0 && end.y < buffer.totalLines;
}

/// Computes the `(base, extent)` cell offsets for a selection anchored at
/// [anchorCell] and extended to [targetCell].
///
/// Normalized `[begin, end)` ranges are half-open on the end column. When
/// [targetCell] is at or after [anchorCell], `extent.x` is incremented by 1 so
/// [targetCell] is included. When [targetCell] precedes [anchorCell], `base.x`
/// is incremented by 1 so [anchorCell] stays included after normalization swaps
/// the endpoints.
(CellOffset base, CellOffset extent)? resolveSelectionEndpoints({
  required CellOffset anchorCell,
  required CellOffset targetCell,
  required int viewWidth,
  required int lineCount,
}) {
  final lastRow = lineCount - 1;
  if (lastRow < 0 || viewWidth <= 0) return null;
  final maxCol = viewWidth - 1;
  final safeAnchor = CellOffset(
    anchorCell.x.clamp(0, maxCol),
    anchorCell.y.clamp(0, lastRow),
  );
  final safeTarget = CellOffset(
    targetCell.x.clamp(0, maxCol),
    targetCell.y.clamp(0, lastRow),
  );
  final forward =
      safeTarget.y > safeAnchor.y ||
      (safeTarget.y == safeAnchor.y && safeTarget.x >= safeAnchor.x);
  final base = CellOffset(
    forward ? safeAnchor.x : safeAnchor.x + 1,
    safeAnchor.y,
  );
  final extent = CellOffset(
    forward ? safeTarget.x + 1 : safeTarget.x,
    safeTarget.y,
  );
  return (base, extent);
}

/// Shifts [offset] down by [addedLines] and clamps into `[0, lineCount - 1]`.
CellOffset? shiftCellOffsetForHistoryPage({
  required CellOffset offset,
  required int addedLines,
  required int lineCount,
}) {
  final lastRow = lineCount - 1;
  if (lastRow < 0) return null;
  return CellOffset(offset.x, (offset.y + addedLines).clamp(0, lastRow));
}

/// Whether a keyboard event matches the terminal select-all shortcut:
/// Cmd+A (without Ctrl/Alt/Shift) or Ctrl+Shift+A (without Meta/Alt) so plain
/// Ctrl+A (0x01 / start-of-line) still reaches the PTY.
bool isWebSelectAllShortcut({
  required String? key,
  required bool ctrlKey,
  required bool metaKey,
  required bool shiftKey,
  required bool altKey,
}) {
  if (key != 'a' && key != 'A') return false;
  return (metaKey && !ctrlKey && !altKey && !shiftKey) ||
      (ctrlKey && shiftKey && !metaKey && !altKey);
}

class WebSelectionRange {
  const WebSelectionRange({
    required this.startX,
    required this.startY,
    required this.endX,
    required this.endY,
  });

  final int startX;
  final int startY;
  final int endX;
  final int endY;
}

({int column, int row, int length})? shiftWebSelectionForHistoryPage({
  required WebSelectionRange selection,
  required int addedLines,
  required int lineCount,
  required int cols,
}) {
  if (lineCount <= 0 || cols <= 0) return null;
  final shift = addedLines > 0 ? addedLines : 0;
  final newStartY = (selection.startY + shift).clamp(0, lineCount - 1);
  final newEndY = (selection.endY + shift).clamp(0, lineCount - 1);
  final startX = selection.startX.clamp(0, cols);
  final endX = selection.endX.clamp(0, cols);
  final length = (newEndY - newStartY) * cols - startX + endX;
  if (length <= 0) return null;
  return (column: startX, row: newStartY, length: length);
}

/// Resolves a double-tap / long-press word selection around [cell] on loaded
/// cells in [buffer].
TerminalSelectionRange? selectWordRangeAt(
  TerminalCellBuffer buffer,
  CellOffset cell,
) {
  final total = buffer.totalLines;
  if (total <= 0 || buffer.viewWidth <= 0) return null;
  final row = cell.y.clamp(0, total - 1);
  final line = buffer.lineAtVirtualRow(row);
  if (line == null) return null;
  final cols = buffer.viewWidth;
  var col = cell.x.clamp(0, cols - 1);
  if (col > 0 && line.getCodePoint(col) == 0 && line.getWidth(col - 1) == 2) {
    col -= 1;
  }

  int classOf(int c) {
    final cp = line.getCodePoint(c);
    if (cp == 0 || cp == 0x20) return 0;
    final ch = String.fromCharCode(cp);
    if (_wordCharPattern.hasMatch(ch)) return 1;
    return 2;
  }

  final targetClass = classOf(col);
  if (targetClass == 0) {
    // Select single cell on blank space.
    final width = line.getWidth(col).clamp(1, 2);
    return TerminalSelectionRange(
      CellOffset(col, row),
      CellOffset((col + width).clamp(0, cols), row),
      trimmedTopRows: buffer.trimmedTopRows,
      eraseScrollbackGen: buffer.eraseScrollbackGen,
      isAltScreen: buffer.isUsingAltBuffer,
    );
  }

  var start = col;
  while (start > 0) {
    var prev = start - 1;
    if (prev > 0 &&
        line.getCodePoint(prev) == 0 &&
        line.getWidth(prev - 1) == 2) {
      prev -= 1;
    }
    if (classOf(prev) != targetClass) break;
    start = prev;
  }

  var end = col + line.getWidth(col).clamp(1, 2);
  while (end < cols) {
    if (classOf(end) != targetClass) break;
    end += line.getWidth(end).clamp(1, 2);
  }

  return TerminalSelectionRange(
    CellOffset(start, row),
    CellOffset(end.clamp(start + 1, cols), row),
    trimmedTopRows: buffer.trimmedTopRows,
    eraseScrollbackGen: buffer.eraseScrollbackGen,
    isAltScreen: buffer.isUsingAltBuffer,
  );
}

final RegExp _wordCharPattern = RegExp(r'[A-Za-z0-9_./~:-]');

/// Rebuilds the plain text for [range] in [buffer], preserving interior gap
/// spaces while trimming trailing blank padding and suppressing newlines across
/// soft-wrapped rows.
String terminalSelectionText(
  TerminalCellBuffer buffer,
  TerminalSelectionRange range,
) {
  final (begin, _) = range.normalizedIn(buffer);
  final out = StringBuffer();
  var wroteAny = false;
  for (final segment in range.toSegmentsIn(buffer)) {
    if (segment.line < 0 || segment.line >= buffer.totalLines) {
      continue;
    }
    final line = buffer.lineAtVirtualRow(segment.line);
    if (wroteAny &&
        segment.line != begin.y &&
        segment.line > 0 &&
        !buffer.isWrappedContinuation(segment.line)) {
      out.write('\n');
    }
    wroteAny = true;
    if (line != null) {
      out.write(
        bufferLineSelectedText(
          line,
          segment.start ?? 0,
          segment.end ?? line.length,
        ),
      );
    }
  }
  return out.toString();
}

/// Extracts plain text for one line's half-open column range `[from, to)`.
///
/// Glyph cells (including literal spaces `0x20`) are emitted verbatim, interior
/// unwritten cells (`codePoint == 0`) become `' '`, trailing unwritten cells
/// stay dropped, and the trailing half of a wide (`width == 2`) glyph is
/// skipped without adding a stray space.
String bufferLineSelectedText(TerminalCellLine line, int from, int to) {
  from = from.clamp(0, line.length);
  to = to.clamp(from, line.length);

  var lastGlyph = -1;
  for (var i = from; i < to; i++) {
    if (line.getCodePoint(i) != 0) {
      lastGlyph = i;
    }
  }

  final out = StringBuffer();
  for (var i = from; i < to; i++) {
    final codePoint = line.getCodePoint(i);
    if (codePoint != 0) {
      final width = line.getWidth(i);
      if (i + width <= to) {
        out.writeCharCode(codePoint);
        final extra = line.getCombining(i);
        if (extra != null) {
          for (final c in extra) {
            out.writeCharCode(c);
          }
        }
      }
    } else if (i < lastGlyph) {
      final isWideTrailer = i > 0 && line.getWidth(i - 1) == 2;
      if (!isWideTrailer) {
        out.write(' ');
      }
    }
  }
  return out.toString();
}
