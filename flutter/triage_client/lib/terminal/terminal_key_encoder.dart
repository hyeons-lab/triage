import 'package:flutter/services.dart';
import 'package:triage_client/terminal/control_bytes.dart';

const int kKittyDisambiguateEscapeCodes = 1 << 0;

/// Encodes a Flutter hardware [KeyEvent] into VT / xterm / Kitty keyboard
/// terminal input characters, or returns `null` when the event should not emit
/// PTY bytes.
String? encodeTerminalKeyEvent(
  KeyEvent event, {
  required bool shift,
  required bool ctrl,
  required bool alt,
  required bool meta,
  required TargetPlatform platform,
  bool appCursorKeys = false,
  int kittyKeyboardFlags = 0,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return null;
  }

  final key = event.logicalKey;
  if (_isPureModifier(key)) {
    return null;
  }

  final isApple =
      platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  final kittyDisambiguate =
      (kittyKeyboardFlags & kKittyDisambiguateEscapeCodes) != 0;

  // macOS shell navigation chords (Cmd+Left / Cmd+Right / Cmd+Backspace).
  if (isApple && meta && !ctrl && !alt && !shift) {
    if (key == LogicalKeyboardKey.arrowLeft) return '\x01';
    if (key == LogicalKeyboardKey.arrowRight) return '\x05';
    if (key == LogicalKeyboardKey.backspace) return '\x15';
    // Leave other Cmd+<Key> application/browser shortcuts alone.
    return null;
  }
  if (meta) {
    return null;
  }

  final modParam = _xtermModifierParam(shift: shift, alt: alt, ctrl: ctrl);

  // Enter / NumpadEnter
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    final shiftEnter = bytesForEnterKey(
      shift: shift,
      ctrl: ctrl,
      alt: alt,
      meta: meta,
    );
    if (shiftEnter != null) {
      return kittyDisambiguate ? '\x1b[13;2u' : shiftEnter;
    }
    if (kittyDisambiguate && modParam > 1) {
      return '\x1b[13;${modParam}u';
    }
    if (alt && !ctrl && !shift) {
      return '\x1b\r';
    }
    if (!ctrl && !alt && !shift) {
      return '\r';
    }
    return null;
  }

  // Tab
  if (key == LogicalKeyboardKey.tab) {
    if (ctrl || alt) return null;
    return shift ? '\x1b[Z' : '\t';
  }

  // Escape
  if (key == LogicalKeyboardKey.escape) {
    if (kittyDisambiguate && modParam > 1) {
      return '\x1b[27;${modParam}u';
    }
    if (kittyDisambiguate && !alt && !ctrl && !shift) {
      return '\x1b[27u';
    }
    return alt ? '\x1b\x1b' : '\x1b';
  }

  // Backspace
  if (key == LogicalKeyboardKey.backspace) {
    final base = ctrl ? '\x08' : '\x7f';
    return alt ? '\x1b$base' : base;
  }

  // Cursor arrows
  final arrowFinal = switch (key) {
    LogicalKeyboardKey.arrowUp => 'A',
    LogicalKeyboardKey.arrowDown => 'B',
    LogicalKeyboardKey.arrowRight => 'C',
    LogicalKeyboardKey.arrowLeft => 'D',
    _ => null,
  };
  if (arrowFinal != null) {
    if (modParam > 1) {
      return '\x1b[1;$modParam$arrowFinal';
    }
    return appCursorKeys ? '\x1bO$arrowFinal' : '\x1b[$arrowFinal';
  }

  // Home / End
  final homeEndFinal = switch (key) {
    LogicalKeyboardKey.home => 'H',
    LogicalKeyboardKey.end => 'F',
    _ => null,
  };
  if (homeEndFinal != null) {
    if (modParam > 1) {
      return '\x1b[1;$modParam$homeEndFinal';
    }
    return appCursorKeys ? '\x1bO$homeEndFinal' : '\x1b[$homeEndFinal';
  }

  // Tilde keys: Insert, Delete, PageUp, PageDown
  final tildeCode = switch (key) {
    LogicalKeyboardKey.insert => 2,
    LogicalKeyboardKey.delete => 3,
    LogicalKeyboardKey.pageUp => 5,
    LogicalKeyboardKey.pageDown => 6,
    _ => null,
  };
  if (tildeCode != null) {
    if (modParam > 1) {
      return '\x1b[$tildeCode;$modParam~';
    }
    return '\x1b[$tildeCode~';
  }

  // Function keys F1-F4
  final f1To4Final = switch (key) {
    LogicalKeyboardKey.f1 => 'P',
    LogicalKeyboardKey.f2 => 'Q',
    LogicalKeyboardKey.f3 => 'R',
    LogicalKeyboardKey.f4 => 'S',
    _ => null,
  };
  if (f1To4Final != null) {
    if (modParam > 1) {
      return '\x1b[1;$modParam$f1To4Final';
    }
    return '\x1bO$f1To4Final';
  }

  // Function keys F5-F12
  final fnCode = switch (key) {
    LogicalKeyboardKey.f5 => 15,
    LogicalKeyboardKey.f6 => 17,
    LogicalKeyboardKey.f7 => 18,
    LogicalKeyboardKey.f8 => 19,
    LogicalKeyboardKey.f9 => 20,
    LogicalKeyboardKey.f10 => 21,
    LogicalKeyboardKey.f11 => 23,
    LogicalKeyboardKey.f12 => 24,
    _ => null,
  };
  if (fnCode != null) {
    if (modParam > 1) {
      return '\x1b[$fnCode;$modParam~';
    }
    return '\x1b[$fnCode~';
  }

  // Control key combinations
  if (ctrl) {
    final ctrlChar = _controlSeqForLogicalKey(key, shift: shift);
    if (ctrlChar != null) {
      return alt ? '\x1b$ctrlChar' : ctrlChar;
    }
    if (kittyDisambiguate) {
      final cp = _asciiKeyCodePoint(key);
      if (cp != null) {
        return '\x1b[$cp;${modParam}u';
      }
    }
    return null;
  }

  // Printable character (with optional Alt prefix)
  final ch = event.character;
  if (ch != null && ch.isNotEmpty) {
    final firstUnit = ch.codeUnitAt(0);
    if (firstUnit >= 0x20 && firstUnit != 0x7f) {
      return alt ? '\x1b$ch' : ch;
    }
  }

  if (key == LogicalKeyboardKey.space) {
    return alt ? '\x1b ' : ' ';
  }

  if (alt) {
    final cp = _asciiKeyCodePoint(key);
    if (cp != null) {
      final letter = shift
          ? String.fromCharCode(cp).toUpperCase()
          : String.fromCharCode(cp);
      return '\x1b$letter';
    }
  }

  return null;
}

int _xtermModifierParam({
  required bool shift,
  required bool alt,
  required bool ctrl,
}) {
  var mod = 1;
  if (shift) mod += 1;
  if (alt) mod += 2;
  if (ctrl) mod += 4;
  return mod;
}

bool _isPureModifier(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.shift ||
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.control ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.alt ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight ||
      key == LogicalKeyboardKey.meta ||
      key == LogicalKeyboardKey.capsLock ||
      key == LogicalKeyboardKey.fn;
}

String? _controlSeqForLogicalKey(LogicalKeyboardKey key, {required bool shift}) {
  if (key == LogicalKeyboardKey.space ||
      (key == LogicalKeyboardKey.digit2 && shift)) {
    return '\x00';
  }
  if (key == LogicalKeyboardKey.digit6 && shift) {
    return '\x1e';
  }
  if (key == LogicalKeyboardKey.minus && shift) {
    return '\x1f';
  }
  if (key == LogicalKeyboardKey.slash) {
    return '\x1f';
  }
  if (key == LogicalKeyboardKey.bracketLeft) return '\x1b';
  if (key == LogicalKeyboardKey.backslash) return '\x1c';
  if (key == LogicalKeyboardKey.bracketRight) return '\x1d';

  final cp = _asciiKeyCodePoint(key);
  if (cp != null) {
    return controlByteForChar(String.fromCharCode(cp));
  }
  return null;
}

int? _asciiKeyCodePoint(LogicalKeyboardKey key) {
  final id = key.keyId;
  if (id >= 0x20 && id <= 0x7e) {
    return id;
  }
  return null;
}
