import 'package:xterm/xterm.dart' as xt;

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
