// ignore_for_file: avoid_web_libraries_in_flutter, uri_does_not_exist, deprecated_member_use

import 'dart:html' as html;
import 'dart:js_interop';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

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
