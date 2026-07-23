/// The control code a character produces when combined with Ctrl, or null if it
/// has none. Letters and the `@ [ \ ] ^ _` range map via `& 0x1f` — so Ctrl+C
/// and Ctrl+c both yield `0x03` (SIGINT) and Ctrl+[ yields ESC — matching a
/// terminal's standard control encoding. Digits, spaces, and other punctuation
/// have no control form and return null (the character is sent as typed).
///
/// Shared by both terminal panes (native and web) so the sticky-Ctrl fold behind
/// the accessory bar encodes identically on every client.
String? controlByteForChar(String char) {
  if (char.length != 1) return null;
  final code = char.codeUnitAt(0);
  // Uppercase the letter range so Ctrl+c and Ctrl+C both yield 0x03.
  final upper = (code >= 0x61 && code <= 0x7a) ? code - 0x20 : code;
  if (upper >= 0x40 && upper <= 0x5f) {
    return String.fromCharCode(upper & 0x1f);
  }
  return null;
}
