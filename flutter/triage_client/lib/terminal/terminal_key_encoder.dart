import 'package:flutter/services.dart';
import 'package:triage_client/terminal/control_bytes.dart';

const int kKittyDisambiguateEscapeCodes = 1 << 0;
const int kKittyReportEventTypes = 1 << 1;
const int kKittyReportAlternateKeys = 1 << 2;
const int kKittyReportAllKeysAsEsc = 1 << 3;
const int kKittyReportAssociatedText = 1 << 4;

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
  bool? capsLock,
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
  final kittyReportAll = (kittyKeyboardFlags & kKittyReportAllKeysAsEsc) != 0;
  final kittyReportAlternate =
      (kittyKeyboardFlags & kKittyReportAlternateKeys) != 0;
  final kittyReportText =
      (kittyKeyboardFlags & kKittyReportAssociatedText) != 0;
  final kittyDisambiguate =
      kittyReportAll ||
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

  final hwCapsLock = _resolveHardwareCapsLock(
    capsLock: capsLock,
    kittyDisambiguate: kittyDisambiguate,
  );
  final modParam = _xtermModifierParam(shift: shift, alt: alt, ctrl: ctrl);
  final kittyModBase = modParam + (hwCapsLock ? 64 : 0);

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
      return kittyDisambiguate ? '\x1b[13;${kittyModBase}u' : shiftEnter;
    }
    if (kittyDisambiguate && kittyModBase > 1) {
      return '\x1b[13;${kittyModBase}u';
    }
    if (alt && !ctrl && !shift) {
      return '\x1b\r';
    }
    if (!ctrl && !alt && !shift) {
      return kittyReportAll ? '\x1b[13u' : '\r';
    }
    return null;
  }

  // Tab
  if (key == LogicalKeyboardKey.tab) {
    if (kittyDisambiguate && kittyModBase > 1) {
      return '\x1b[9;${kittyModBase}u';
    }
    if (kittyReportAll && !ctrl && !alt && !shift) {
      return '\x1b[9u';
    }
    if (ctrl || alt) return null;
    return shift ? '\x1b[Z' : '\t';
  }

  // Escape
  if (key == LogicalKeyboardKey.escape) {
    if (kittyDisambiguate && kittyModBase > 1) {
      return '\x1b[27;${kittyModBase}u';
    }
    if (kittyDisambiguate && !alt && !ctrl && !shift) {
      return '\x1b[27u';
    }
    return alt ? '\x1b\x1b' : '\x1b';
  }

  // Backspace
  if (key == LogicalKeyboardKey.backspace) {
    if (kittyDisambiguate && kittyModBase > 1) {
      return '\x1b[127;${kittyModBase}u';
    }
    if (kittyReportAll && !ctrl && !alt && !shift) {
      return '\x1b[127u';
    }
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

  // Function keys F1-F4 (Kitty encodes F3 as CSI 13 ~ to avoid CPR collision)
  if (key == LogicalKeyboardKey.f3 && kittyDisambiguate) {
    return modParam > 1 ? '\x1b[13;$modParam~' : '\x1b[13~';
  }
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
    return kittyReportAll ? '\x1b[$f1To4Final' : '\x1bO$f1To4Final';
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
    if (kittyDisambiguate) {
      final cp = _kittyBaseCodePoint(key);
      if (cp != null) {
        int? shiftedCp;
        if (kittyReportAlternate && shift) {
          final ch = event.character;
          if (ch != null && _isPrintableTerminalCharacter(ch)) {
            final runes = ch.runes.toList(growable: false);
            if (runes.length == 1 && runes.first != cp) {
              shiftedCp = runes.first;
            }
          }
          shiftedCp ??= _shiftedAsciiCodePoint(key);
          if (shiftedCp == cp) shiftedCp = null;
        }
        final keyField = shiftedCp != null ? '$cp:$shiftedCp' : '$cp';
        return '\x1b[$keyField;${kittyModBase}u';
      }
    }
    final ctrlChar = _controlSeqForLogicalKey(key, shift: shift);
    if (ctrlChar != null) {
      return alt ? '\x1b$ctrlChar' : ctrlChar;
    }
    return null;
  }

  if (kittyDisambiguate && alt) {
    final cp = _kittyBaseCodePoint(key);
    if (cp != null) {
      int? shiftedCp;
      if (kittyReportAlternate && shift) {
        shiftedCp = _shiftedAsciiCodePoint(key);
        if (shiftedCp == cp) shiftedCp = null;
      }
      final keyField = shiftedCp != null ? '$cp:$shiftedCp' : '$cp';
      return '\x1b[$keyField;${kittyModBase}u';
    }
  }

  // Printable character (with optional Alt prefix for 7-bit ASCII)
  final ch = event.character;
  if (ch != null && ch.isNotEmpty && _isPrintableTerminalCharacter(ch)) {
    if (kittyReportAll) {
      final runes = ch.runes.toList(growable: false);
      if (runes.length == 1) {
        final actualCp = runes.first;
        final baseCp = _kittyBaseCodePoint(key);
        final cp = (shift && baseCp != null)
            ? baseCp
            : _lowercaseCodePoint(actualCp);
        final inferredCaps =
            capsLock == null &&
            !hwCapsLock &&
            !shift &&
            !ctrl &&
            !alt &&
            actualCp != cp;
        final effectiveKittyMod = kittyModBase + (inferredCaps ? 64 : 0);
        final shiftedCp = (kittyReportAlternate && shift && actualCp != cp)
            ? actualCp
            : null;
        final keyField = shiftedCp != null ? '$cp:$shiftedCp' : '$cp';
        if (kittyReportText && !alt) {
          return '\x1b[$keyField;$effectiveKittyMod;${actualCp}u';
        }
        return effectiveKittyMod > 1
            ? '\x1b[$keyField;${effectiveKittyMod}u'
            : '\x1b[${keyField}u';
      }
    }
    if (!alt) {
      return ch;
    }
    if (_isAsciiPrintableString(ch)) {
      return '\x1b$ch';
    }
  }

  if (key == LogicalKeyboardKey.space) {
    if (kittyReportAll) {
      if (kittyReportText && !alt && !ctrl) {
        return '\x1b[32;$kittyModBase;32u';
      }
      return kittyModBase > 1 ? '\x1b[32;${kittyModBase}u' : '\x1b[32u';
    }
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

bool _isPrintableTerminalCharacter(String ch) {
  for (final rune in ch.runes) {
    if (rune < 0x20 || rune == 0x7f) return false;
    // Reject C1 controls and Apple NSEvent function-key PUA (`U+F700..U+F8FF`).
    if (rune >= 0x80 && rune <= 0x9f) return false;
    if (rune >= 0xf700 && rune <= 0xf8ff) return false;
  }
  return true;
}

bool _isAsciiPrintableString(String ch) {
  for (var i = 0; i < ch.length; i++) {
    final u = ch.codeUnitAt(i);
    if (u < 0x20 || u > 0x7e) return false;
  }
  return true;
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

String? _controlSeqForLogicalKey(
  LogicalKeyboardKey key, {
  required bool shift,
}) {
  if (key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.digit2 ||
      key == LogicalKeyboardKey.at) {
    return '\x00';
  }
  if (key == LogicalKeyboardKey.backquote) {
    return shift ? '\x1e' : '\x00';
  }
  if (key == LogicalKeyboardKey.tilde ||
      key == LogicalKeyboardKey.digit6 ||
      key == LogicalKeyboardKey.caret) {
    return '\x1e';
  }
  if (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.underscore) {
    return '\x1f';
  }
  if (key == LogicalKeyboardKey.question) {
    return '\x7f';
  }
  if (key == LogicalKeyboardKey.slash) {
    return shift ? '\x7f' : '\x1f';
  }
  if (key == LogicalKeyboardKey.bracketLeft ||
      key == LogicalKeyboardKey.braceLeft) {
    return '\x1b';
  }
  if (key == LogicalKeyboardKey.backslash || key == LogicalKeyboardKey.bar) {
    return '\x1c';
  }
  if (key == LogicalKeyboardKey.bracketRight ||
      key == LogicalKeyboardKey.braceRight) {
    return '\x1d';
  }

  final cp = _asciiKeyCodePoint(key);
  if (cp != null) {
    return controlByteForChar(String.fromCharCode(cp));
  }
  return null;
}

int? _shiftedAsciiCodePoint(LogicalKeyboardKey key) {
  final cp = _asciiKeyCodePoint(key);
  if (cp != null && cp >= 0x61 && cp <= 0x7a) {
    return cp - 0x20;
  }
  return switch (key) {
    LogicalKeyboardKey.semicolon => 0x3a,
    LogicalKeyboardKey.equal => 0x2b,
    LogicalKeyboardKey.comma => 0x3c,
    LogicalKeyboardKey.minus => 0x5f,
    LogicalKeyboardKey.period => 0x3e,
    LogicalKeyboardKey.slash => 0x3f,
    LogicalKeyboardKey.backquote => 0x7e,
    LogicalKeyboardKey.bracketLeft => 0x7b,
    LogicalKeyboardKey.backslash => 0x7c,
    LogicalKeyboardKey.bracketRight => 0x7d,
    LogicalKeyboardKey.quote => 0x22,
    LogicalKeyboardKey.digit1 => 0x21,
    LogicalKeyboardKey.digit2 => 0x40,
    LogicalKeyboardKey.digit3 => 0x23,
    LogicalKeyboardKey.digit4 => 0x24,
    LogicalKeyboardKey.digit5 => 0x25,
    LogicalKeyboardKey.digit6 => 0x5e,
    LogicalKeyboardKey.digit7 => 0x26,
    LogicalKeyboardKey.digit8 => 0x2a,
    LogicalKeyboardKey.digit9 => 0x28,
    LogicalKeyboardKey.digit0 => 0x29,
    _ => null,
  };
}

int _lowercaseCodePoint(int cp) {
  if (cp >= 0x41 && cp <= 0x5a) return cp + 0x20;
  if (cp >= 0x80) {
    final lower = String.fromCharCode(cp).toLowerCase().runes;
    if (lower.length == 1) return lower.first;
  }
  return cp;
}

int? _kittyBaseCodePoint(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.space) return 0x20;
  final id = key.keyId;
  if (id < 0x20 || id == 0x7f || id > 0x10ffff) return null;
  if (id >= 0x80 && id <= 0x9f) return null;
  if (id >= 0xd800 && id <= 0xdfff) return null;
  if (id >= 0xf700 && id <= 0xf8ff) return null;
  return _lowercaseCodePoint(id);
}

int? _asciiKeyCodePoint(LogicalKeyboardKey key) {
  final id = key.keyId;
  if (id >= 0x20 && id <= 0x7e) {
    return (id >= 0x41 && id <= 0x5a) ? id + 0x20 : id;
  }
  return null;
}

bool _resolveHardwareCapsLock({
  required bool? capsLock,
  required bool kittyDisambiguate,
}) {
  if (capsLock != null) return capsLock;
  if (!kittyDisambiguate) return false;
  try {
    return HardwareKeyboard.instance.lockModesEnabled.contains(
      KeyboardLockMode.capsLock,
    );
  } on Object {
    return false;
  }
}
