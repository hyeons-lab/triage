// Web stubs for `platform_env_io.dart`. `dart:io` (and thus
// `Platform.environment`) is unavailable on the web client, so there is no
// local `$HOME` to abbreviate, and marquee animations are always enabled (the
// `flutter test` fake-async hang only affects the native test harness).

String? localHomeDir() => null;

bool marqueeAnimationsEnabled() => true;
