String displayTerminalInput(String input) {
  if (input == '\r') {
    return r'\r';
  }
  if (input == '\u007f') {
    return 'backspace';
  }
  return input.runes
      .map(
        (int rune) => rune < 32
            ? '0x${rune.toRadixString(16)}'
            : String.fromCharCode(rune),
      )
      .join();
}
