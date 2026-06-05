/// Intents for the unidirectional terminal pipeline.
///
/// Every mutation of the terminal model is expressed as a [TerminalIntent] and
/// dispatched to a single `TerminalStore`, which reduces it through one ordered
/// write path. The single source of truth is the raw PTY byte stream; the xterm
/// emulator behind the sink is the model.
library;

/// Base type for all terminal intents. Sealed so the reducer's `switch` is
/// exhaustive.
sealed class TerminalIntent {
  const TerminalIntent();
}

/// Raw PTY bytes from the live `Output` stream.
///
/// [outputSeq] is the host's per-chunk counter; used to drop chunks already
/// covered by a preceding [HistoryBytes] tail (no gap, no overlap).
final class LiveBytes extends TerminalIntent {
  const LiveBytes(this.bytes, {this.outputSeq});

  final List<int> bytes;
  final int? outputSeq;
}

/// Raw output-history tail delivered on attach/resync (the host's `raw_output`).
///
/// The bytes are re-emulated at [cols] x [rows] — the client's target replay
/// size, i.e. the current emulator/view grid (the client re-emulates raw bytes
/// at its own size rather than the host's capture size). [throughOutputSeq] is
/// the host's `output_seq` at the byte boundary the tail ends on; live chunks
/// with `outputSeq <= throughOutputSeq` are dropped as duplicates.
final class HistoryBytes extends TerminalIntent {
  const HistoryBytes(
    this.bytes, {
    required this.cols,
    required this.rows,
    this.throughOutputSeq,
  });

  final List<int> bytes;
  final int cols;
  final int rows;
  final int? throughOutputSeq;
}

/// The view's measured viewport changed (debounced fit detection).
final class Resize extends TerminalIntent {
  const Resize(this.cols, this.rows);

  final int cols;
  final int rows;
}

/// A keystroke/paste from the user, to be forwarded to the host.
final class UserInput extends TerminalIntent {
  const UserInput(this.data);

  final String data;
}

/// Session attach started; the store enters `awaitingHistory`.
final class Attach extends TerminalIntent {
  const Attach();
}

/// Session detached; live/history writes stop until the next [Attach].
final class Detach extends TerminalIntent {
  const Detach();
}

/// The remote process exited; further [UserInput] is suppressed.
final class Exited extends TerminalIntent {
  const Exited();
}

/// Clear the emulator (hard reset of the visible buffer + scrollback).
final class Clear extends TerminalIntent {
  const Clear();
}
