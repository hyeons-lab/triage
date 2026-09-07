import 'package:xterm/xterm.dart' as xt;

/// How close to the bottom a downward scroll must land before the pin is
/// released. Wider than the single line `TerminalScrollAnchor.capture` uses to
/// decide it is already at the bottom, so a user chasing live output is handed
/// over before the pin can re-apply.
const int kScrollPinReleaseGraceLines = 3;

/// Whether a released pin should immediately snap the viewport to the bottom.
///
/// The snap cannot run while the user is still working the viewport: `jumpTo`
/// calls `goIdle()`, which tears down the drag, hold, or fling in progress. A
/// held pointer matters on its own because a finger placed down to stop a
/// fling installs a hold activity, and a hold reports *not* scrolling, so the
/// scroll state alone would call that settled. [hasAnchor] means the user
/// re-pinned on the way and no longer wants the bottom.
bool shouldFinishBottomSnap({
  required bool isScrolling,
  required bool pointerDown,
  required double pixels,
  required double maxScrollExtent,
  required bool hasAnchor,
}) {
  if (isScrolling || pointerDown || hasAnchor || pixels < 0) return false;
  return pixels < maxScrollExtent;
}

/// Whether a scroll event should release a held scroll pin and hand the
/// viewport back to the emulator's stick-to-bottom following.
///
/// A pinned viewport plus a steadily growing buffer is a treadmill: every new
/// line pushes the bottom further away while the pin holds the same line, so a
/// user chasing live output (e.g. a composer at the very bottom of a busy agent
/// session) can never arrive. Releasing when the user is actively scrolling
/// *down* and already within [kScrollPinReleaseGraceLines] of the bottom tells
/// the caller to drop the pin and snap the last few lines to the bottom, while
/// upward or distant scrolling keeps the pin so background output never steals
/// a reading position. Takes only scroll metrics and no widget state, so it is
/// unit-testable without a laid-out render tree.
bool shouldReleaseScrollPin({
  required double? lastPixels,
  required double pixels,
  required double maxScrollExtent,
  required double lineHeight,
}) {
  if (lastPixels == null ||
      lineHeight <= 0 ||
      maxScrollExtent <= 0 ||
      pixels < 0) {
    return false;
  }
  if (pixels <= lastPixels) {
    return false;
  }
  return pixels >= maxScrollExtent - kScrollPinReleaseGraceLines * lineHeight;
}

/// Pins a terminal viewport to a specific scrollback line so that scrollback
/// trims don't drift the visible content.
///
/// xterm.dart measures the scroll offset from the top of the buffer and does
/// not compensate `offset.pixels` when a full buffer trims lines off the top
/// (once `maxLines` is reached, every new line drops the oldest). A scrolled-up
/// viewport therefore creeps upward — one line per trimmed line.
///
/// We exploit xterm.dart's `BufferLine.index`, which is the line's current row
/// in the buffer and decreases by exactly the number of lines trimmed above it.
/// Pinning the viewport to `index * lineHeight` cancels the drift. This type is
/// pure logic over the buffer + scroll metrics so it is unit-testable without a
/// laid-out render tree.
///
/// A line can leave the buffer two ways, and they do not look alike. Ageing out
/// of a full buffer detaches it, so `attached` turns false. A scrollback clear
/// (`ESC[3J`) drops it through `trimStart`, which leaves it attached on purpose:
/// anchors still holding it would throw in release builds if it were detached.
/// Such a line reports a negative index, since it now sits before the start of
/// the buffer, and that is what identifies it here.
class TerminalScrollAnchor {
  xt.BufferLine? _line;
  double _withinLine = 0;

  /// Whether a live anchor is held. When false the caller should follow the
  /// bottom and leave xterm.dart's stick-to-bottom in control.
  bool get hasAnchor => _line != null;

  /// Drop the anchor (e.g. on a session/terminal swap).
  void clear() => _line = null;

  /// Clone this anchor.
  TerminalScrollAnchor clone() {
    final copy = TerminalScrollAnchor();
    copy._line = _line;
    copy._withinLine = _withinLine;
    return copy;
  }

  /// Copy anchor state from another anchor.
  void copyFrom(TerminalScrollAnchor other) {
    _line = other._line;
    _withinLine = other._withinLine;
  }

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
        pixels >= maxScrollExtent - lineHeight) {
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
    // Cleared out of the scrollback rather than aged out. Without this the
    // negative row would compute a negative offset, clamp to zero, and pin the
    // viewport to the top of the buffer instead of releasing it.
    if (line.index < 0) {
      _line = null;
      return null;
    }
    if (lineHeight <= 0) return null;
    final desired = line.index * lineHeight + _withinLine;
    return desired.clamp(0.0, maxScrollExtent);
  }
}
