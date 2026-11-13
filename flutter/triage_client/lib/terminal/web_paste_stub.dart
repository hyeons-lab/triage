/// Registers a browser DOM `paste` listener on web platforms.
///
/// No-op stub on non-web platforms, where [Clipboard.getData] works natively.
void Function() registerWebPasteListener(bool Function(String text) onPaste) {
  return () {};
}
