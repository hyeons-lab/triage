// ignore_for_file: avoid_web_libraries_in_flutter, uri_does_not_exist, deprecated_member_use

import 'dart:async' show StreamSubscription;
import 'dart:html' as html;
import 'dart:js_interop';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, VoidCallback;

// Web stubs for `platform_env_io.dart`. `dart:io` (and thus
// `Platform.environment`) is unavailable on the web client, so there is no
// local `$HOME` to abbreviate, and marquee animations are always enabled (the
// terminal is the only thing running, so battery-saving pauses are moot).

String? localHomeDir() => null;

bool marqueeAnimationsEnabled() => true;

bool runningUnderFlutterTest() => false;

@JS('_allowUnload')
external set _allowUnload(bool value);

/// Allows intentional unload/exit without triggering the browser's beforeunload prompt.
void allowWebExit() {
  try {
    _allowUnload = true;
  } catch (_) {}
}

/// Resets the web exit flag if navigation was cancelled or did not unload.
void resetWebExit() {
  try {
    _allowUnload = false;
  } catch (_) {}
}

/// Detects mobile browsers and touch devices under Flutter Web.
bool isWebMobileBrowser() {
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android) {
    return true;
  }
  try {
    final nav = html.window.navigator;
    final isMacLikeTouch =
        defaultTargetPlatform == TargetPlatform.macOS &&
        (nav.maxTouchPoints ?? 0) > 1;
    if (isMacLikeTouch) return true;
    final ua = nav.userAgent.toLowerCase();
    if (ua.contains('mobile') ||
        ua.contains('android') ||
        ua.contains('iphone') ||
        ua.contains('ipad') ||
        ua.contains('ipod')) {
      return true;
    }
    if ((nav.maxTouchPoints ?? 0) > 1 &&
        html.window.matchMedia('(pointer: coarse)').matches) {
      return true;
    }
  } catch (_) {}
  return false;
}

/// True when the browser exposes the asynchronous `navigator.clipboard` API
/// (secure HTTPS / localhost contexts). Plain-HTTP LAN or Tailscale origins
/// omit `navigator.clipboard` and must fall back to synchronous DOM `copy` /
/// `paste` events without awaiting across an async gap.
bool canReadWebClipboardAsync() {
  try {
    return html.window.navigator.clipboard != null;
  } catch (_) {
    return false;
  }
}

bool _execCommandCopySync(String text) {
  html.TextAreaElement? textarea;
  html.Element? active = html.document.activeElement;
  while (active != null && active.shadowRoot?.activeElement != null) {
    active = active.shadowRoot!.activeElement;
  }
  try {
    final body = html.document.body;
    if (body == null) return false;
    textarea = html.TextAreaElement()
      ..value = text
      ..readOnly = true;
    textarea.style
      ..position = 'fixed'
      ..top = '-9999px'
      ..left = '-9999px'
      ..opacity = '0'
      ..fontSize = '16px';
    body.append(textarea);
    textarea.focus();
    textarea.select();
    textarea.setSelectionRange(0, text.length);
    return html.document.execCommand('copy');
  } catch (_) {
    return false;
  } finally {
    textarea?.remove();
    if (active is html.HtmlElement) {
      try {
        active.focus();
      } catch (_) {}
    }
  }
}

/// Copies [text] to the clipboard on web, falling back to an offscreen
/// `<textarea>` + `document.execCommand('copy')` when `navigator.clipboard` is
/// unavailable (for example over plain-HTTP LAN or Tailscale origins).
Future<bool> copyTextWithWebFallback(String text) async {
  if (!canReadWebClipboardAsync()) {
    return _execCommandCopySync(text);
  }
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } catch (_) {
    return _execCommandCopySync(text);
  }
}

/// Subscribes to browser `paste` DOM events on `window` so plain-HTTP web
/// origins can receive `Cmd+V` / `Ctrl+V` pastes even when `navigator.clipboard`
/// is disabled. Calls `event.preventDefault()` only when [onPaste] accepts the
/// event (`true`).
VoidCallback? registerWebPasteListener(bool Function(String text) onPaste) {
  StreamSubscription<html.Event>? sub;
  try {
    sub = html.window.on['paste'].listen((html.Event event) {
      try {
        if (event.defaultPrevented) return;
        final clipEvent = event as html.ClipboardEvent;
        final text = clipEvent.clipboardData?.getData('text/plain');
        if (text != null && text.isNotEmpty && onPaste(text)) {
          event.preventDefault();
        }
      } catch (_) {}
    });
  } catch (_) {
    return null;
  }
  return () {
    sub?.cancel();
  };
}
