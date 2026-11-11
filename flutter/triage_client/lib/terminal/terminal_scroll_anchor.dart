import 'package:triage_client/terminal/terminal_cell_buffer.dart';

/// How close to the bottom a downward scroll must land before the pin is
/// released. Wider than the single line `TerminalScrollAnchor.capture` uses to
/// decide it is already at the bottom, so a user chasing live output is handed
/// over before the pin can re-apply.
const int kScrollPinReleaseGraceLines = 3;

/// Subpixel tolerance in logical pixels used to decide if the viewport has
/// reached the bottom on native Flutter scroll physics.
const double kNativeScrollSubpixelTolerance = 0.5;

/// Whether a released pin's deferred trip to the bottom should now complete.
bool shouldFinishBottomSnap({
  required bool isScrolling,
  required bool pointerDown,
  required double pixels,
  required double maxScrollExtent,
  required bool hasAnchor,
}) {
  if (isScrolling || pointerDown || hasAnchor) return false;
  return pixels < maxScrollExtent;
}

/// Whether a scroll event should release a held scroll pin and hand the
/// viewport back to stick-to-bottom following.
bool shouldReleaseScrollPin({
  required double? lastPixels,
  required double pixels,
  required double maxScrollExtent,
  required double lineHeight,
}) {
  if (lastPixels == null || lineHeight <= 0) return false;
  if (pixels <= lastPixels) return false;
  return pixels >= maxScrollExtent - kScrollPinReleaseGraceLines * lineHeight;
}

/// Pins a terminal viewport to a specific monotonic virtual scrollback line
/// (`absoluteRow = trimmedTopRows + virtualRow`) so retention trims at the top
/// of scrollback do not drift the visible content while the user is reading.
///
/// Works in O(1) arithmetic across the full 210,000-row virtual scrollback
/// range, including unloaded rows, and automatically drops the anchor when the
/// anchored row ages past row 0 or when `CSI 3J` clears scrollback.
class TerminalScrollAnchor {
  TerminalCellBuffer? _buffer;
  int? _anchoredAbsoluteRow;
  int _eraseScrollbackGen = 0;
  bool _isAltScreen = false;
  double _withinLine = 0;
  int? _lastLineIndex;

  bool get hasAnchor => _buffer != null && _anchoredAbsoluteRow != null;

  int? get _currentVirtualRow {
    final buf = _buffer;
    final absRow = _anchoredAbsoluteRow;
    if (buf == null || absRow == null) return null;
    if (buf.eraseScrollbackGen != _eraseScrollbackGen ||
        buf.isUsingAltBuffer != _isAltScreen) {
      return null;
    }
    return absRow - buf.trimmedTopRows;
  }

  /// Whether the anchored line's virtual row index has shifted since the anchor
  /// was last captured or pinned.
  bool get hasLineShifted {
    final idx = _currentVirtualRow;
    if (idx == null || idx <= 0) return false;
    return idx != _lastLineIndex;
  }

  /// Records the anchored line's current virtual row index after re-pinning.
  void markPinned() {
    _lastLineIndex = _currentVirtualRow;
  }

  /// Drops the anchor.
  void clear() {
    _buffer = null;
    _anchoredAbsoluteRow = null;
    _lastLineIndex = null;
  }

  TerminalScrollAnchor clone() {
    final copy = TerminalScrollAnchor();
    copy._buffer = _buffer;
    copy._anchoredAbsoluteRow = _anchoredAbsoluteRow;
    copy._eraseScrollbackGen = _eraseScrollbackGen;
    copy._isAltScreen = _isAltScreen;
    copy._withinLine = _withinLine;
    copy._lastLineIndex = _lastLineIndex;
    return copy;
  }

  void copyFrom(TerminalScrollAnchor other) {
    _buffer = other._buffer;
    _anchoredAbsoluteRow = other._anchoredAbsoluteRow;
    _eraseScrollbackGen = other._eraseScrollbackGen;
    _isAltScreen = other._isAltScreen;
    _withinLine = other._withinLine;
    _lastLineIndex = other._lastLineIndex;
  }

  /// Captures an anchor from the current scroll metrics. Clears the anchor when
  /// the viewport is at the bottom, or at or above row 0.
  void capture({
    required TerminalCellBuffer buffer,
    required double pixels,
    required double maxScrollExtent,
    required double lineHeight,
  }) {
    final lineCount = buffer.totalLines;
    if (lineHeight <= 0 ||
        lineCount <= 0 ||
        buffer.isUsingAltBuffer ||
        pixels <= 0.0 ||
        pixels >= maxScrollExtent - kNativeScrollSubpixelTolerance) {
      clear();
      return;
    }
    final topRow = pixels ~/ lineHeight;
    if (topRow <= 0 || topRow >= lineCount) {
      clear();
      return;
    }
    _buffer = buffer;
    _anchoredAbsoluteRow = buffer.trimmedTopRows + topRow;
    _eraseScrollbackGen = buffer.eraseScrollbackGen;
    _isAltScreen = buffer.isUsingAltBuffer;
    _withinLine = pixels - topRow * lineHeight;
    _lastLineIndex = topRow;
  }

  /// Returns the scroll offset that keeps the anchored line pinned, clamped to
  /// `[0, maxScrollExtent]`, or `null` (clearing the anchor) if the line aged
  /// out or scrollback was cleared.
  double? desiredOffset({
    required double maxScrollExtent,
    required double lineHeight,
  }) {
    final idx = _currentVirtualRow;
    if (idx == null || idx <= 0) {
      clear();
      return null;
    }
    if (lineHeight <= 0 || maxScrollExtent <= 0.0) return null;
    final desired = idx * lineHeight + _withinLine;
    if (desired <= 0.0) {
      clear();
      return null;
    }
    return desired.clamp(0.0, maxScrollExtent);
  }
}
