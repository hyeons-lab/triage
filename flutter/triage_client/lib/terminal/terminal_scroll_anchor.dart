import 'package:xterm/xterm.dart' as xt;

/// Pins a terminal viewport to a specific scrollback line so that scrollback
/// trims don't drift the visible content.
///
/// xterm.dart measures the scroll offset from the top of the buffer and does
/// not compensate `offset.pixels` when a full buffer trims lines off the top
/// (once `maxLines` is reached, every new line drops the oldest). A scrolled-up
/// viewport therefore creeps upward — one line per trimmed line.
///
/// We exploit xterm.dart's `BufferLine.index`, which is the line's current row
/// in the buffer and decreases by exactly the number of lines trimmed above it
/// (and `attached` flips to `false` once the line itself is trimmed). Pinning
/// the viewport to `index * lineHeight` cancels the drift. This type is pure
/// logic over the buffer + scroll metrics so it is unit-testable without a
/// laid-out render tree.
class TerminalScrollAnchor {
  xt.BufferLine? _line;
  double _withinLine = 0;

  /// Whether a live anchor is held. When false the caller should follow the
  /// bottom and leave xterm.dart's stick-to-bottom in control.
  bool get hasAnchor => _line != null;

  /// Drop the anchor (e.g. on a session/terminal swap).
  void clear() => _line = null;

  /// Capture an anchor from the current scroll metrics. Clears the anchor when
  /// the viewport is at (or within a line of) the bottom, so the caller follows
  /// new output instead of pinning just shy of the bottom.
  void capture({
    required xt.Buffer buffer,
    required double pixels,
    required double maxScrollExtent,
    required double lineHeight,
  }) {
    final lineCount = buffer.lines.length;
    if (lineHeight <= 0 ||
        lineCount <= 0 ||
        pixels >= maxScrollExtent - 1.0) {
      _line = null;
      return;
    }
    final topRow = (pixels ~/ lineHeight).clamp(0, lineCount - 1);
    _line = buffer.lines[topRow];
    _withinLine = pixels - topRow * lineHeight;
  }

  /// The scroll offset that keeps the anchored line pinned, clamped to
  /// `[0, maxScrollExtent]`. Returns null when there is no live anchor — either
  /// none was captured, or the anchored line has been trimmed out of the buffer
  /// (in which case the anchor is dropped and the caller should stop tracking).
  double? desiredOffset({
    required double maxScrollExtent,
    required double lineHeight,
  }) {
    final line = _line;
    if (line == null) return null;
    if (!line.attached) {
      _line = null;
      return null;
    }
    if (lineHeight <= 0) return null;
    final desired = line.index * lineHeight + _withinLine;
    return desired.clamp(0.0, maxScrollExtent);
  }
}
