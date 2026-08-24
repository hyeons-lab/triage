/// Terminal paste utilities and bracketed paste formatting.

final _pasteEscapeInjectionPattern = RegExp(r'\x1b\[201~|\x9b201~');

/// Formats text for insertion into a terminal session as a paste operation.
///
/// When [bracketedPasteEnabled] is true (DEC Mode 2004), the pasted text is wrapped
/// in `\x1b[200~` and `\x1b[201~`, and any embedded `\x1b[201~` or 8-bit C1 `\x9b201~`
/// inside [text] is stripped to prevent premature termination of bracketed paste mode
/// (paste injection defense).
///
/// When [bracketedPasteEnabled] is false, the text is returned verbatim.
String formatPasteInput(String text, bool bracketedPasteEnabled) {
  if (!bracketedPasteEnabled || text.isEmpty) {
    return text;
  }
  final sanitized = text.contains('\x1b[201~') || text.contains('\x9b201~')
      ? text.replaceAll(_pasteEscapeInjectionPattern, '')
      : text;
  return '\x1b[200~$sanitized\x1b[201~';
}
