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
  static final RegExp _unicodeWordCharRegex = RegExp(
    r'^[\p{L}\p{N}]$',
    unicode: true,
  );

  bool _lastEndedWithWordChar = false;
  bool _lastEndedWithUnspacedScript = false;

  bool get lastEndedWithWordChar => _lastEndedWithWordChar;

  /// Resets the tracker. Must be called when the user taps or clicks
  /// the terminal viewport, on session switch, or when control codes are emitted.
  void reset() {
    _lastEndedWithWordChar = false;
    _lastEndedWithUnspacedScript = false;
  }

  /// Evaluates incoming mobile input [text] and returns either the original [text]
  /// or [text] prepended with a single space if a word boundary was crossed.
  String processInput(String text) {
    if (text.isEmpty) return text;

    var result = text;
    final firstCodePoint = _firstCodePoint(text);
    final incomingIsUnspaced = _isUnspacedScript(firstCodePoint);

    // A surrogate pair representing a single astral plane (SMP) character has
    // text.length == 2; only treat inputs with multiple Unicode characters as
    // multi-character word chunks.
    final isMultiChar =
        text.length > 1 && !(text.length == 2 && firstCodePoint >= 0x10000);

    // If incoming text is a multi-character word chunk (such as from gesture/swipe
    // typing, autocomplete chips, or IME commits) starting with an alphanumeric
    // character, and the preceding input ended with an alphanumeric character
    // without an intervening space or reset, auto-insert a space. Scripts without
    // inter-word spacing (CJK, Thai, Lao, Khmer) are excluded to prevent inserting
    // corrupting spaces into continuous words.
    if (_lastEndedWithWordChar &&
        isMultiChar &&
        isWordChar(firstCodePoint) &&
        !_lastEndedWithUnspacedScript &&
        !incomingIsUnspaced) {
      result = ' $text';
    }

    // Update state based on the last code point of the emitted text.
    final lastCodePoint = _lastCodePoint(result);
    _lastEndedWithWordChar = isWordChar(lastCodePoint);
    _lastEndedWithUnspacedScript = _isUnspacedScript(lastCodePoint);

    return result;
  }

  static int _firstCodePoint(String str) {
    final first = str.codeUnitAt(0);
    if (first >= 0xd800 && first <= 0xdbff && str.length > 1) {
      final second = str.codeUnitAt(1);
      if (second >= 0xdc00 && second <= 0xdfff) {
        return 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00);
      }
    }
    return first;
  }

  static int _lastCodePoint(String str) {
    final last = str.codeUnitAt(str.length - 1);
    if (last >= 0xdc00 && last <= 0xdfff && str.length > 1) {
      final penultimate = str.codeUnitAt(str.length - 2);
      if (penultimate >= 0xd800 && penultimate <= 0xdbff) {
        return 0x10000 + ((penultimate - 0xd800) << 10) + (last - 0xdc00);
      }
    }
    return last;
  }

  /// Whether a code point belongs to a script that does not use inter-word spaces.
  static bool _isUnspacedScript(int codePoint) {
    // CJK Unified Ideographs, Extensions, Compatibility
    if ((codePoint >= 0x4e00 && codePoint <= 0x9fff) ||
        (codePoint >= 0x3400 && codePoint <= 0x4dbf) ||
        (codePoint >= 0x20000 && codePoint <= 0x2fa1f) ||
        (codePoint >= 0xf900 && codePoint <= 0xfaff)) {
      return true;
    }
    // Japanese Hiragana & Katakana
    if ((codePoint >= 0x3040 && codePoint <= 0x30ff) ||
        (codePoint >= 0x31f0 && codePoint <= 0x31ff)) {
      return true;
    }
    // Thai, Lao, Khmer, Myanmar
    if ((codePoint >= 0x0e00 && codePoint <= 0x0eff) ||
        (codePoint >= 0x1780 && codePoint <= 0x17ff) ||
        (codePoint >= 0x1000 && codePoint <= 0x109f)) {
      return true;
    }
    return false;
  }

  /// Whether a character code point represents an alphanumeric word character.
  /// Supports ASCII, Latin-1, and global Unicode scripts (letters and numbers).
  static bool isWordChar(int codePoint) {
    if (codePoint < 0x80) {
      return (codePoint >= 0x30 && codePoint <= 0x39) || // 0-9
          (codePoint >= 0x41 && codePoint <= 0x5a) || // A-Z
          (codePoint >= 0x61 && codePoint <= 0x7a); // a-z
    }
    if (codePoint >= 0xc0 &&
        codePoint <= 0xff &&
        codePoint != 0xd7 &&
        codePoint != 0xf7) {
      return true;
    }
    if (codePoint >= 0xd800 && codePoint <= 0xdfff) {
      return false;
    }
    // High-frequency global scripts fast path (zero allocations)
    if ((codePoint >= 0x0400 && codePoint <= 0x04ff) || // Cyrillic
        (codePoint >= 0x0370 && codePoint <= 0x03ff) || // Greek
        (codePoint >= 0xac00 && codePoint <= 0xd7af) || // Hangul Syllables
        (codePoint >= 0x4e00 && codePoint <= 0x9fff)) { // CJK Unified Ideographs
      return true;
    }
    return _unicodeWordCharRegex.hasMatch(String.fromCharCode(codePoint));
  }
}
