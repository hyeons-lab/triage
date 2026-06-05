/// Immutable control state for the terminal pipeline.
///
/// This holds *control* state only — the grid/scrollback live in the xterm
/// model behind the sink. The store emits a new [TerminalState] after each
/// reduced intent so a thin view can rebuild.
library;

/// Where the session is in the attach lifecycle.
enum AttachPhase {
  /// Not attached; live/history writes are ignored.
  detached,

  /// Attached, waiting for the [HistoryBytes] tail before going live.
  awaitingHistory,

  /// History applied (or none expected); live bytes write straight through.
  live,
}

/// Value-typed control state. Use [copyWith] to derive the next state.
class TerminalState {
  const TerminalState({
    this.cols = 0,
    this.rows = 0,
    this.sized = false,
    this.phase = AttachPhase.detached,
    this.exited = false,
    this.scrollbackReady = false,
    this.lastSentCols,
    this.lastSentRows,
    this.historyHighWaterSeq,
  });

  /// Current emulator width/height in cells.
  final int cols;
  final int rows;

  /// True once a valid (>= minimum) size has been applied at least once.
  final bool sized;

  final AttachPhase phase;

  /// The remote process has exited; input is suppressed.
  final bool exited;

  /// History has been applied (or explicitly none); scrollback is coherent.
  final bool scrollbackReady;

  /// Last size emitted to the host via `onResize` (de-dupes resize echoes).
  final int? lastSentCols;
  final int? lastSentRows;

  /// Highest `output_seq` covered by applied history; live chunks at or below
  /// this are duplicates and dropped.
  final int? historyHighWaterSeq;

  TerminalState copyWith({
    int? cols,
    int? rows,
    bool? sized,
    AttachPhase? phase,
    bool? exited,
    bool? scrollbackReady,
    int? lastSentCols,
    int? lastSentRows,
    int? historyHighWaterSeq,
  }) {
    return TerminalState(
      cols: cols ?? this.cols,
      rows: rows ?? this.rows,
      sized: sized ?? this.sized,
      phase: phase ?? this.phase,
      exited: exited ?? this.exited,
      scrollbackReady: scrollbackReady ?? this.scrollbackReady,
      lastSentCols: lastSentCols ?? this.lastSentCols,
      lastSentRows: lastSentRows ?? this.lastSentRows,
      historyHighWaterSeq: historyHighWaterSeq ?? this.historyHighWaterSeq,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TerminalState &&
        other.cols == cols &&
        other.rows == rows &&
        other.sized == sized &&
        other.phase == phase &&
        other.exited == exited &&
        other.scrollbackReady == scrollbackReady &&
        other.lastSentCols == lastSentCols &&
        other.lastSentRows == lastSentRows &&
        other.historyHighWaterSeq == historyHighWaterSeq;
  }

  @override
  int get hashCode => Object.hash(
        cols,
        rows,
        sized,
        phase,
        exited,
        scrollbackReady,
        lastSentCols,
        lastSentRows,
        historyHighWaterSeq,
      );

  @override
  String toString() =>
      'TerminalState(${cols}x$rows sized=$sized phase=$phase exited=$exited '
      'scrollbackReady=$scrollbackReady sent=$lastSentCols x$lastSentRows '
      'historyHighWaterSeq=$historyHighWaterSeq)';
}
