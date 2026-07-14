import 'dart:io' show Platform;

// Native/desktop/mobile implementations of the small bits of process-env access
// the side rail needs. The web build swaps in `platform_env_web.dart` via a
// conditional import, since `dart:io` (and `Platform.environment`) is
// unavailable there.

/// The user's local home directory (`$HOME`), or null when unknown. Reading
/// [Platform.environment] can throw on some platforms, so it is guarded.
String? localHomeDir() {
  try {
    return Platform.environment['HOME'];
  } catch (_) {
    return null;
  }
}

/// False under `flutter test`, where a perpetual marquee animation would
/// fast-forward fake-async time and hang `pumpAndSettle`; the rail then falls
/// back to static (ellipsized) text. Guarded because reading
/// [Platform.environment] can throw on some platforms.
bool marqueeAnimationsEnabled() {
  try {
    return !Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return true;
  }
}

/// True under `flutter test` (native harness). The widget tests assert the
/// desktop layout and its immediate drag-to-reorder; the mobile overlay and
/// long-press reorder would break them, so those paths are gated off in tests.
/// Guarded because reading [Platform.environment] can throw on some platforms.
bool runningUnderFlutterTest() {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}
