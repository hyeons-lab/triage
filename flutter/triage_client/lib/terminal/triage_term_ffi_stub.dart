import 'package:xterm2/xterm.dart' as xt;

/// Returns whether the native Rust `triage-term` FFI library is available.
bool get isTriageRustTerminalAvailable => false;

/// Creates a terminal instance, falling back to `package:xterm2` on web.
xt.Terminal createTriageTerminal({
  int maxLines = 1000,
  void Function()? onBell,
  void Function(String title)? onTitleChange,
  void Function(String icon)? onIconChange,
  void Function(String data)? onOutput,
  void Function(int width, int height, int pixelWidth, int pixelHeight)?
  onResize,
  xt.TerminalTargetPlatform platform = xt.TerminalTargetPlatform.unknown,
  bool reflowEnabled = true,
  bool reflowWithHiddenCursor = true,
  Set<int>? wordSeparators,
}) {
  return xt.Terminal(
    maxLines: maxLines,
    onBell: onBell,
    onTitleChange: onTitleChange,
    onIconChange: onIconChange,
    onOutput: onOutput,
    onResize: onResize,
    platform: platform,
    reflowEnabled: reflowEnabled,
    reflowWithHiddenCursor: reflowWithHiddenCursor,
    wordSeparators: wordSeparators,
  );
}
