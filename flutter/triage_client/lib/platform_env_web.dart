// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:js_interop';

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
