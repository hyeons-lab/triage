const int kMouseModeOff = 0;
const int kMouseModeX10 = 1;
const int kMouseModeNormal = 2;
const int kMouseModeButtonEvent = 3;
const int kMouseModeAnyEvent = 4;

const int kMouseReportNormal = 0;
const int kMouseReportUtf8 = 1;
const int kMouseReportSgr = 2;
const int kMouseReportUrxvt = 3;
const int kMouseReportSgrPixels = 4;

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
/// SGR (`?1006`), urxvt (`?1015`), UTF-8 (`?1005`), or normal X10/VT200 escape
/// sequences using 0-based viewport `(col, row)` coordinates.
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
  if (mouseReportMode == kMouseReportSgrPixels) {
    // Pixel-coordinate SGR (?1016) cannot be synthesized from cell coordinates.
    return null;
  }
  final isWheel =
      button == TerminalMouseButton.wheelUp ||
      button == TerminalMouseButton.wheelDown;
  if (mouseMode == kMouseModeX10 && (!pressed || isWheel || motion)) {
    // X10 (?9) reports button press only (no release, wheel, or motion).
    return null;
  }
  if (motion) {
    // Button-event (?1002 / 3) reports drag while pressed; only any-event
    // (?1003 / 4) reports unpressed hover motion.
    if (mouseMode < kMouseModeButtonEvent) return null;
    if (mouseMode == kMouseModeButtonEvent && !pressed) return null;
  }

  final x1 = (col < 0 ? 0 : col) + 1;
  final y1 = (row < 0 ? 0 : row) + 1;

  final isHoverMotion = motion && !pressed && !isWheel;
  final isRelease = !pressed && !motion && !isWheel;

  var cb = isHoverMotion ? 3 : button.code;
  if (motion) {
    cb += 32;
  }
  if (mouseMode != kMouseModeX10) {
    if (shift) cb += 4;
    if (alt) cb += 8;
    if (ctrl) cb += 16;
  }

  // SGR mouse report mode (?1006 -> mouseReportMode == 2)
  if (mouseReportMode == kMouseReportSgr) {
    final suffix = isRelease ? 'm' : 'M';
    return '\x1b[<$cb;$x1;$y1$suffix';
  }

  final wireBtn = isRelease
      ? ((3 + (shift ? 4 : 0) + (alt ? 8 : 0) + (ctrl ? 16 : 0)) & 0xFF)
      : (cb & 0xFF);

  // urxvt decimal report mode (?1015 -> mouseReportMode == 3)
  if (mouseReportMode == kMouseReportUrxvt) {
    return '\x1b[${32 + wireBtn};$x1;${y1}M';
  }

  // UTF-8 extended report mode (?1005 -> mouseReportMode == 1, up to 2015)
  if (mouseReportMode == kMouseReportUtf8) {
    if (x1 > 2015 || y1 > 2015) {
      return null;
    }
    return String.fromCharCodes(<int>[
      0x1b,
      0x5b,
      0x4d,
      32 + wireBtn,
      32 + x1,
      32 + y1,
    ]);
  }

  // Normal X10 / VT200 report mode (0): keep bytes strictly 7-bit ASCII
  // (`32 + coord <= 127` -> `coord <= 95`) so UTF-8 string encoding never
  // expands coordinates >= 96 into multi-byte UTF-8 sequences on the PTY.
  if (x1 > 95 || y1 > 95 || (32 + wireBtn) > 0x7f) {
    return null;
  }
  return String.fromCharCodes(<int>[
    0x1b,
    0x5b,
    0x4d,
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
  bool isUsingAltBuffer = true,
  int steps = 3,
}) {
  if (!isUsingAltBuffer) return '';
  final unit = up
      ? (appCursorKeys ? '\x1bOA' : '\x1b[A')
      : (appCursorKeys ? '\x1bOB' : '\x1b[B');
  final count = steps < 1 ? 1 : steps;
  return unit * count;
}
