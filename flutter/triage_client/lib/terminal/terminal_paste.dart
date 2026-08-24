/// Terminal paste utilities and bracketed paste formatting.

/// Formats text for insertion into a terminal session as a paste operation.
///
/// When [bracketedPasteEnabled] is true (DEC Mode 2004), the pasted text is wrapped
/// in `\x1b[200~` and `\x1b[201~`, and any embedded `\x1b[201~` inside [text] is stripped
/// to prevent premature termination of bracketed paste mode (paste injection defense).
///
/// When [bracketedPasteEnabled] is false, the text is returned verbatim.
String formatPasteInput(String text, bool bracketedPasteEnabled) {
  if (!bracketedPasteEnabled || text.isEmpty) {
    return text;
  }
  final sanitized = text.replaceAll('\x1b[201~', '');
  return '\x1b[200~$sanitized\x1b[201~';
}
