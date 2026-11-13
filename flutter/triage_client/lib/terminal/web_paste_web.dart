// ignore_for_file: avoid_web_libraries_in_flutter, uri_does_not_exist, deprecated_member_use

import 'dart:html' as html;

bool _isExternalEditableActive() {
  final active = html.document.activeElement;
  if (active == null) return false;
  if (active.classes.contains('flt-text-editing') ||
      active.closest('flt-text-editing-host') != null) {
    return false;
  }
  final tag = active.tagName.toUpperCase();
  if (tag == 'INPUT' || tag == 'TEXTAREA') {
    return true;
  }
  return active is html.HtmlElement && (active.isContentEditable ?? false);
}

/// Registers a capture-phase `window` DOM `paste` listener on Flutter Web.
///
/// Using the native `ClipboardEvent` avoids `navigator.clipboard.readText()`,
/// which fails in insecure (`http://`) contexts (such as Tailscale/LAN IPs)
/// and whenever `clipboard-read` permission is denied. Capture phase runs
/// before Flutter's hidden `flt-text-editing` `<textarea>` can turn the paste
/// into duplicate IME text deltas when the terminal pane owns focus.
void Function() registerWebPasteListener(bool Function(String text) onPaste) {
  void handlePaste(html.Event rawEvent) {
    if (rawEvent.defaultPrevented || _isExternalEditableActive()) {
      return;
    }
    if (rawEvent is! html.ClipboardEvent) {
      return;
    }
    final clipboardData = rawEvent.clipboardData;
    var text = clipboardData?.getData('text/plain');
    if (text == null || text.isEmpty) {
      text = clipboardData?.getData('text');
    }
    if (text == null || text.isEmpty) {
      return;
    }
    if (onPaste(text)) {
      rawEvent.preventDefault();
      rawEvent.stopPropagation();
    }
  }

  // Wrap in `html.EventListener` closure so removeEventListener matches the
  // exact function reference registered here.
  final html.EventListener listener = handlePaste;
  html.window.addEventListener('paste', listener, true);
  return () {
    html.window.removeEventListener('paste', listener, true);
  };
}
