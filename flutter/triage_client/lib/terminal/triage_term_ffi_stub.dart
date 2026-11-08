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
  return _TriageFallbackTerminal(
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

class _TriageFallbackTerminal extends xt.Terminal {
  _TriageFallbackTerminal({
    super.maxLines = 1000,
    super.onBell,
    super.onTitleChange,
    super.onIconChange,
    super.onOutput,
    super.onResize,
    super.platform = xt.TerminalTargetPlatform.unknown,
    super.reflowEnabled = true,
    super.reflowWithHiddenCursor = true,
    super.wordSeparators,
  });

  bool _batchingUpdates = false;
  bool _pendingNotify = false;

  @override
  void setSynchronizedUpdateMode(bool enabled) {
    _batchingUpdates = enabled;
    if (!enabled && _pendingNotify) {
      _pendingNotify = false;
      super.notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (_batchingUpdates) {
      _pendingNotify = true;
      return;
    }
    super.notifyListeners();
  }
}
