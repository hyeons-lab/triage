/// Takeover logic for touch-drag scrolling on web.
///
/// xterm.js scrolls its viewport from its own touch handlers, but the browser
/// silently drops the rest of a touch stream when the touchstart target — a
/// DOM-renderer text span — is detached by live-output re-rendering
/// mid-gesture. Pointer events keep flowing with fresh hit-testing in exactly
/// those cases, so the pane drives scrolling from pointermove while xterm's
/// own touch path is silent for the gesture.
///
/// This class holds the per-gesture decision state; it is DOM-free so it can
/// be unit-tested. The pane feeds it pointer/touch observations and applies
/// the returned row counts via `scrollToLine`, which still fires xterm's
/// `onScroll` (so scroll-save and near-top paging keep working).
class TouchScrollTakeover {
  TouchScrollTakeover({this.quietWindowMs = 120});

  /// How long after the last observed touchmove xterm's path still owns the
  /// gesture. Past this with pointermoves flowing, the touch stream is dead
  /// and this unit takes over.
  final int quietWindowMs;

  double? _lastY;
  double _carryRows = 0;
  int _touchAliveUntilMs = 0;

  /// A new press started; forget the previous gesture.
  void onPointerDown(int nowMs) {
    _lastY = null;
    _carryRows = 0;
    _touchAliveUntilMs = 0;
  }

  /// A touchmove reached the terminal: xterm's own path is alive.
  void onTouchMove(int nowMs) {
    _touchAliveUntilMs = nowMs + quietWindowMs;
  }

  /// Advances the gesture to [y] and returns signed whole rows to scroll
  /// (positive toward newer, negative toward older). Returns 0 while xterm
  /// owns the gesture, while anchoring the first move, or when [canDrive] is
  /// false (multi-touch, mouse drag-select). The anchor updates on every
  /// move either way, so a mid-gesture takeover never jumps.
  int onPointerMove({
    required int nowMs,
    required double y,
    required double rowPx,
    required bool canDrive,
  }) {
    final last = _lastY;
    _lastY = y;
    if (last == null || !canDrive || rowPx <= 0) return 0;
    if (nowMs < _touchAliveUntilMs) {
      _carryRows = 0;
      return 0;
    }
    _carryRows += (last - y) / rowPx;
    final rows = _carryRows.truncate();
    _carryRows -= rows;
    return rows;
  }
}
