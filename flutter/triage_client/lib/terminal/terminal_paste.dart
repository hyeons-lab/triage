final _pasteEscapeInjectionPattern = RegExp(r'\x1b\[201~|\x9b201~');
final _newlinePattern = RegExp(r'\r\n|\r|\n');

/// Reports whether [text] contains newlines (`\n` or `\r`).
bool isMultiLine(String text) {
  return text.contains('\n') || text.contains('\r');
}

/// Flattens [text] to a single line by replacing all newline sequences (`\r\n`, `\r`, `\n`)
/// with a single space.
String flattenToSingleLine(String text) {
  return text.replaceAll(_newlinePattern, ' ');
}

/// Counts the number of lines in [text].
int lineCount(String text) {
  if (text.isEmpty) return 0;
  final matches = _newlinePattern.allMatches(text);
  return matches.length + 1;
}

/// Formats text for insertion into a terminal session as a paste operation.
///
/// When [bracketedPasteEnabled] is true (DEC Mode 2004), the pasted text is wrapped
/// in `\x1b[200~` and `\x1b[201~`, and any embedded `\x1b[201~` or 8-bit C1 `\x9b201~`
/// inside [text] is stripped to prevent premature termination of bracketed paste mode
/// (paste injection defense).
///
/// When [bracketedPasteEnabled] is false, newlines (`\r\n` and `\n`) are normalized to
/// carriage return `\r` (0x0D) so the terminal PTY line discipline translates them
/// correctly without staircasing.
String formatPasteInput(String text, bool bracketedPasteEnabled) {
  if (text.isEmpty) {
    return text;
  }
  if (!bracketedPasteEnabled) {
    return text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
  }
  final sanitized = text.contains('\x1b[201~') || text.contains('\x9b201~')
      ? text.replaceAll(_pasteEscapeInjectionPattern, '')
      : text;
  return '\x1b[200~$sanitized\x1b[201~';
}
