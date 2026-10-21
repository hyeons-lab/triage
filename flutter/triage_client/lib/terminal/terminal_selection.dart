import 'package:xterm/xterm.dart' as xt;

/// Whether [range] still refers to rows that are inside [buffer].
///
/// A selection normally dies with its lines: ageing out of a full buffer
/// detaches them, and the controller then stops returning a range at all. A
/// scrollback clear (`ESC[3J`) does not work that way. It drops lines through
/// `trimStart`, which leaves them attached deliberately, because anchors still
/// holding them guard access with `assert(attached)` alone and would throw in
/// release builds if they were detached. The controller therefore goes on
/// handing out a range for a selection whose text is gone, with rows that have
/// gone negative now that they sit before the start of the buffer.
///
/// Callers use this to retire such a selection themselves, which the fix for
/// that trim leaves as their job.
bool terminalSelectionIsLive(xt.Buffer buffer, xt.BufferRange range) {
  final normalized = range.normalized;
  return normalized.begin.y >= 0 && normalized.end.y < buffer.lines.length;
}

/// Computes the `(base, extent)` cell offsets to pass to
/// `TerminalController.setSelection` for a selection anchored at [anchorCell]
/// and extended to [targetCell].
///
/// `BufferRangeLine` treats its normalized `[begin, end)` range as half-open on
/// the end column. When [targetCell] is at or after [anchorCell] in `(row, col)`
/// order, `extent.x` is incremented by 1 so [targetCell] is included. When
/// [targetCell] is before [anchorCell] (a backward drag or Shift-click),
/// `BufferRangeLine.normalized` swaps `base` and `extent`, making `base` the
/// exclusive upper bound; `base.x` is therefore incremented by 1 so
/// [anchorCell] itself stays included.
(xt.CellOffset base, xt.CellOffset extent)? resolveSelectionEndpoints({
  required xt.CellOffset anchorCell,
  required xt.CellOffset targetCell,
  required int viewWidth,
  required int lineCount,
}) {
  final lastRow = lineCount - 1;
  if (lastRow < 0 || viewWidth <= 0) return null;
  final maxCol = viewWidth - 1;
  final safeAnchor = xt.CellOffset(
    anchorCell.x.clamp(0, maxCol),
    anchorCell.y.clamp(0, lastRow),
  );
  final safeTarget = xt.CellOffset(
    targetCell.x.clamp(0, maxCol),
    targetCell.y.clamp(0, lastRow),
  );
  final forward =
      safeTarget.y > safeAnchor.y ||
      (safeTarget.y == safeAnchor.y && safeTarget.x >= safeAnchor.x);
  final base = xt.CellOffset(
    forward ? safeAnchor.x : safeAnchor.x + 1,
    safeAnchor.y,
  );
  final extent = xt.CellOffset(
    forward ? safeTarget.x + 1 : safeTarget.x,
    safeTarget.y,
  );
  return (base, extent);
}

/// Shifts [offset] down by [addedLines] after a scrollback page prepends older
/// rows at the top of the buffer, clamping into `[0, lineCount - 1]`.
xt.CellOffset? shiftCellOffsetForHistoryPage({
  required xt.CellOffset offset,
  required int addedLines,
  required int lineCount,
}) {
  final lastRow = lineCount - 1;
  if (lastRow < 0) return null;
  return xt.CellOffset(offset.x, (offset.y + addedLines).clamp(0, lastRow));
}

/// Whether a web keyboard event matches the terminal select-all shortcut:
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

/// Snapshot of xterm.js `getSelectionPosition()` buffer coordinates (`start`
/// inclusive, `end` exclusive) captured before a scrollback history page.
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

/// Computes the `(column, row, length)` arguments for xterm.js
/// `term.select(column, row, length)` after a scrollback page adds [addedLines]
/// older rows at the top of a buffer with [lineCount] total lines and [cols]
/// columns. Returns `null` when the grid is empty or the resulting selection
/// has non-positive length.
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

/// Rebuilds the plain text for a terminal selection [range], preserving the
/// spaces that xterm.dart's own `Buffer.getText` drops.
///
/// `BufferLine.getText` emits nothing for any cell whose codePoint is 0, so the
/// blank cells a program leaves behind when it lays out columns by *moving the
/// cursor* (`ESC[C`, a tab, `ESC[G`) instead of writing literal spaces vanish on
/// copy and the visible columns concatenate. ratatui-style TUIs (e.g. Claude
/// Code) render exactly this way. This helper is the native (xterm.dart)
/// counterpart of the web copy path: xterm.js's own `getSelection()` already
/// backfills those nulls with spaces, so on web the fix is to prefer it over
/// the browser's DOM selection rather than to reconstruct text here (see
/// `terminal_pane_web.dart`).
///
/// The output is a strict superset of `Buffer.getText`'s: glyph cells (literal
/// spaces included) are written verbatim, interior blank cells become a single
/// space, trailing blanks stay dropped (so lines are not padded to full width),
/// and the trailing half of a wide (CJK) glyph is skipped so it gains no stray
/// space.
String terminalSelectionText(xt.Buffer buffer, xt.BufferRange range) {
  final normalized = range.normalized;
  final out = StringBuffer();
  for (final segment in normalized.toSegments()) {
    if (segment.line < 0 || segment.line >= buffer.height) {
      continue;
    }
    final line = buffer.lines[segment.line];
    // Mirror Buffer.getText's newline rule: no separator before the first
    // selected line, before line 0, or before a soft-wrapped continuation.
    if (!(segment.line == normalized.begin.y ||
        segment.line == 0 ||
        line.isWrapped)) {
      out.write('\n');
    }
    out.write(
      bufferLineSelectedText(
        line,
        segment.start ?? 0,
        segment.end ?? line.length,
      ),
    );
  }
  return out.toString();
}

/// Text for one line's selected half-open column range `[from, to)`. See
/// [terminalSelectionText] for the cell-by-cell rule.
String bufferLineSelectedText(xt.BufferLine line, int from, int to) {
  from = from.clamp(0, line.length);
  to = to.clamp(from, line.length);

  // Last cell in the range that actually holds a glyph. Blank cells past it are
  // trailing padding and stay dropped, matching the original trim-on-copy.
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
      // Glyph cell — written exactly as Buffer.getText would, keeping a wide
      // glyph only when its trailing half is inside the range.
      if (i + line.getWidth(i) <= to) {
        out.writeCharCode(codePoint);
      }
    } else if (i < lastGlyph) {
      // Interior blank. The trailing half of a wide glyph (previous cell has
      // width 2) carries codePoint 0 by design — skip it; every other interior
      // blank becomes a space.
      final isWideTrailer = i > 0 && line.getWidth(i - 1) == 2;
      if (!isWideTrailer) {
        out.write(' ');
      }
    }
  }
  return out.toString();
}
