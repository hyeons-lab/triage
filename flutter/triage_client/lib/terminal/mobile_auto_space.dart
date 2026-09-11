/// Tracks mobile text input chunks and auto-inserts a space separator between
/// consecutive word chunks (such as from gesture/swipe typing, autocomplete
/// suggestion chips, or IME composition commits).
///
/// Because mobile terminal views clear their underlying text buffers immediately
/// to remain synchronized with the remote PTY, mobile virtual keyboards (Gboard,
/// iOS QuickType, etc.) lose text context and cannot auto-insert leading spaces
/// when swiping or committing words. This tracker restores natural word spacing
/// on mobile while preserving single-keystroke typing, flags, paths, and punctuation.
class MobileAutoSpaceTracker {
  bool _lastEndedWithWordChar = false;

  bool get lastEndedWithWordChar => _lastEndedWithWordChar;

  /// Resets the tracker. Must be called when the terminal receives host output
  /// (such as shell prompts or command output), when the user taps or clicks
  /// the terminal viewport, on session switch, or when control codes are emitted.
  void reset() {
    _lastEndedWithWordChar = false;
  }

  /// Evaluates incoming mobile input [text] and returns either the original [text]
  /// or [text] prepended with a single space if a word boundary was crossed.
  String processInput(String text) {
    if (text.isEmpty) return text;

    var result = text;
    final firstUnit = text.codeUnitAt(0);

    // If incoming text is a multi-character word chunk (length > 1) starting
    // with an alphanumeric character, and the preceding input ended with an
    // alphanumeric character without an intervening space or reset, auto-insert
    // a space.
    if (_lastEndedWithWordChar && text.length > 1 && isWordChar(firstUnit)) {
      result = ' $text';
    }

    // Update state based on the last code unit of the emitted text.
    final lastUnit = result.codeUnitAt(result.length - 1);
    _lastEndedWithWordChar = isWordChar(lastUnit);

    return result;
  }

  /// Whether a character code unit represents an alphanumeric word character.
  /// Includes ASCII letters and digits, as well as Latin-1 accented letters.
  static bool isWordChar(int codeUnit) {
    return (codeUnit >= 0x30 && codeUnit <= 0x39) || // 0-9
        (codeUnit >= 0x41 && codeUnit <= 0x5a) || // A-Z
        (codeUnit >= 0x61 && codeUnit <= 0x7a) || // a-z
        (codeUnit >= 0xc0 &&
            codeUnit <= 0xff &&
            codeUnit != 0xd7 &&
            codeUnit != 0xf7); // Latin-1 letters
  }
}
