const int kMouseModeOff = 0;
const int kMouseModeX10 = 1;
const int kMouseModeNormal = 2;
const int kMouseModeButtonEvent = 3;
const int kMouseModeAnyEvent = 4;

const int kMouseReportNormal = 0;
const int kMouseReportUtf8 = 1;
const int kMouseReportSgr = 2;

enum TerminalMouseButton {
  left(0),
  middle(1),
  right(2),
  wheelUp(64),
  wheelDown(65);

  const TerminalMouseButton(this.code);
  final int code;
}

/// Encodes terminal mouse button, drag, hover motion, and wheel events into
/// SGR (`?1006`) or normal X10/VT200 escape sequences using 0-based viewport
/// `(col, row)` coordinates.
String? encodeTerminalMouseEvent({
  required int mouseMode,
  required int mouseReportMode,
  required TerminalMouseButton button,
  required int col,
  required int row,
  required bool pressed,
  bool motion = false,
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
}) {
  if (mouseMode <= 0) return null;
  final isWheel =
      button == TerminalMouseButton.wheelUp ||
      button == TerminalMouseButton.wheelDown;
  if (mouseMode == 1 && (!pressed || isWheel)) {
    // X10 (?9) reports button press only (no release and no wheel).
    return null;
  }
  if (motion) {
    // Only button-event (3 / ?1002) and any-event (4 / ?1003) report motion.
    if (mouseMode < 3) return null;
  }

  final x1 = (col < 0 ? 0 : col) + 1;
  final y1 = (row < 0 ? 0 : row) + 1;

  var cb = button.code;
  if (motion) {
    cb += 32;
  }
  if (shift) cb += 4;
  if (alt) cb += 8;
  if (ctrl) cb += 16;

  // SGR mouse report mode (?1006 -> mouseReportMode == 2)
  if (mouseReportMode == 2) {
    final suffix = (!pressed &&
            button != TerminalMouseButton.wheelUp &&
            button != TerminalMouseButton.wheelDown)
        ? 'm'
        : 'M';
    return '\x1b[<$cb;$x1;$y1$suffix';
  }

  // Normal X10 / VT200 fallback (coordinates capped at 223).
  if (x1 > 223 || y1 > 223) {
    return null;
  }
  final wireBtn = (!pressed &&
          button != TerminalMouseButton.wheelUp &&
          button != TerminalMouseButton.wheelDown)
      ? ((3 + (shift ? 4 : 0) + (alt ? 8 : 0) + (ctrl ? 16 : 0)) & 0xFF)
      : (cb & 0xFF);
  return String.fromCharCodes(<int>[
    0x1b,
    0x5b, // '['
    0x4d, // 'M'
    32 + wireBtn,
    32 + x1,
    32 + y1,
  ]);
}

/// Encodes vertical scroll steps in alternate-screen mode when the foreground
/// application has not enabled mouse tracking (e.g. `less`, `man`, `git log`).
String encodeAltScreenFallbackWheel({
  required bool up,
  required bool appCursorKeys,
  int steps = 3,
}) {
  final unit = up
      ? (appCursorKeys ? '\x1bOA' : '\x1b[A')
      : (appCursorKeys ? '\x1bOB' : '\x1b[B');
  final count = steps < 1 ? 1 : steps;
  return unit * count;
}
