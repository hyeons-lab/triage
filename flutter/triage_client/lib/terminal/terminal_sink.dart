/// The only seam that touches a real terminal emulator.
///
/// Concrete sinks wrap `package:xterm` `Terminal` (native) or xterm.js (web).
/// The store performs all decoding, buffering, and ordering, then drives the
/// sink with already-decoded strings. Keeping this surface tiny is what makes
/// the reducer unit-testable against a fake.
library;

/// Minimal emulator surface used by `TerminalStore`.
abstract class TerminalSink {
  /// Write decoded text to the emulator. The store guarantees this is called in
  /// arrival order and never with partial multi-byte sequences split awkwardly
  /// (it owns the UTF-8 carry); the sink may still chunk large strings.
  void write(String data);

  /// Resize the emulator grid. Native sinks reflow; web sinks call `fit`/resize.
  void resize(int cols, int rows);

  /// Hard-clear the visible buffer and scrollback (used before history replay).
  void clear();

  /// Emulator -> host: user produced input (keystroke/paste). Set by the store.
  set onOutput(void Function(String data)? handler);

  /// Emulator -> host: the emulator decided to resize (e.g. after a fit). Set by
  /// the store; the store de-dupes and forwards distinct sizes to the host.
  set onResize(void Function(int cols, int rows)? handler);

  /// Release any emulator resources/listeners. The store calls this on dispose.
  void dispose();
}
