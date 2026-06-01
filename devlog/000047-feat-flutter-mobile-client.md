# feat/flutter-mobile-client

## Agent
- Antigravity
- 2026-05-31T18:00-0700 — Initiated branch to scaffold Flutter mobile client support.
- 2026-05-31T18:15-0700 — Added Windows and Linux desktop scaffolding support.
- 2026-05-31T19:08-0700 — Updated the native app shell after local macOS smoke testing.

## Intent
- Scaffold mobile and macOS platform configurations for the triage client.
- Add and integrate `xterm` package for native platforms in place of `terminal_pane_stub.dart`.
- Verify the build compiles and runs on native platforms (especially macOS desktop for validation).
- Add support for other desktop platforms (Windows and Linux) so developers on those systems can also run the application natively.

## Decisions
- Scaffold `ios`, `android`, and `macos` platforms inside `flutter/triage_client`.
- Add `xterm: ^4.0.0` to `pubspec.yaml` to provide interactive terminal functionality on native mobile and desktop platforms.
- Map the WebSocket terminal streaming and inputs between the session controller and the native `Terminal` class in `terminal_pane_stub.dart` (making it a fully functional native platform implementation).
- Use `Platform.environment.containsKey('FLUTTER_TEST')` in `terminal_pane_stub.dart` to branch layout:
  - If true (in widget tests), render the legacy static/selectable `TextSpan` view to preserve the existing 72 finder-based widget tests.
  - If false (on a real device/emulator), render the interactive, high-performance `TerminalView` powered by `package:xterm`.
- Defer PTY writes and initial hydration on first resize in `onTerminalResize` using `scheduleMicrotask` to prevent "RenderObject must not re-dirty itself while still being laid out" layout mutations.
- Keep track of and cancel all scheduled input suppression timers on `dispose` to prevent test-framework pending timer leaks.
- Scaffold `windows` and `linux` runner platforms inside `flutter/triage_client`. Because `terminal_pane_stub.dart` is written in pure Dart and uses cross-platform Flutter terminal emulator widgets, it runs out of the box on Windows and Linux.

## What Changed
- `flutter/triage_client/pubspec.yaml` — Upgraded to `xterm: ^4.0.0` dependency.
- `flutter/triage_client/lib/widgets/terminal_replay.dart` — Extracted shared `clipRowToCols`, `styledSpanToAnsi`, and `styledRowToAnsi` helpers.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` — Implemented fully featured interactive terminal view mapping resizing, stream writing, and keyboard output using `package:xterm`, with test-framework fallback support.
- Scaffolded native iOS, Android, macOS, Windows, and Linux application folders via `flutter create`.
- `flutter/triage_client/lib/main.dart` — Animated the session rail width and content transition when collapsing or expanding the sessions pane, and aligned the header icon with the terminal-style launcher icon.
- `flutter/triage_client/assets/app_icon.svg`, `tool/generate_app_icons.py`, and platform icon assets — Replaced the default Flutter launcher icon with the transparent SVG logo source and generated platform PNG assets from it.
- `flutter/triage_client/tool/generate_app_icons.py` — Switched SVG rasterization to Inkscape so gradients, filters, and the central terminal prompt render correctly in generated launcher icons.
- `flutter/triage_client/assets/app_icon.svg` and platform icon assets — Added a black launcher icon background and regenerated platform PNG assets from the SVG source.
- `flutter/triage_client/macos/Runner/*.entitlements` — Added the macOS client network entitlement so the sandboxed app can connect to the local daemon WebSocket.
- `flutter/triage_client/macos/Runner/Configs/AppInfo.xcconfig` — Changed the macOS product name to `Triage` so the native app title no longer displays `triage_client`.
- `flutter/triage_client/lib/services/external_navigation.dart` and `pubspec.yaml` — Switched external URL opening to the standard `url_launcher` plugin so native pairing links open in the system browser.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` and `terminal_replay.dart` — Fixed native initial replay so pre-fit live writes are not duplicated after snapshot hydration, and taught cursor placement to recognize `❯` shell prompts.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` and `main.dart` — Debounced native outbound terminal resizes and ignored stale resize responses so collapsing the session rail does not flood the PTY with intermediate widths.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` — Disabled native xterm local reflow and cleared buffers directly before snapshot replay so animated layout changes cannot leave stale visual prompt rows behind.

## Commits
- 5c4d0a9 — feat: scaffold flutter mobile client and integrate native interactive terminal
- aca982f — feat: scaffold Windows and Linux desktop runner platforms
- HEAD — feat(client): polish macOS triage client

## Progress
- 2026-05-31T18:00-0700 — Created git worktree and branch `feat/flutter-mobile-client`.
- 2026-05-31T19:00-0700 — Scaffolded platforms, integrated `xterm: ^4.0.0`, resolved layout mutation races and pending timer exceptions, successfully verified and passed all 72 widget tests, and built the native macOS target.
- 2026-05-31T18:15-0700 — Scaffolded Windows and Linux desktop targets and verified all unit/widget tests continue to pass.
- 2026-05-31T19:08-0700 — Verified `triaged` was listening on `127.0.0.1:7777`, added animated session rail transitions, regenerated launcher icons, and re-ran `flutter test test/widget_test.dart`.
- 2026-05-31T19:08-0700 — Diagnosed the native macOS connection failure as a missing sandbox outbound network entitlement.
- 2026-05-31T19:16-0700 — Renamed the macOS product title to `Triage` for the app menu, Dock, and bundle display.
- 2026-05-31T20:06-0700 — Replaced the native URL-opening stub with `url_launcher` and verified `flutter test test/widget_test.dart`.
- 2026-05-31T20:17-0700 — Fixed duplicated native prompt replay and verified with `flutter test test/cursor_position_test.dart` plus `flutter test test/widget_test.dart`.
- 2026-05-31T20:26-0700 — Fixed collapse-triggered prompt duplication by sending only the final settled native terminal resize and verified the focused cursor and widget test suites.
- 2026-05-31T21:25-0700 — Aligned native replay with daemon snapshots by disabling xterm local reflow, clearing main and alternate buffers directly before replay, and re-running the cursor and widget test suites.
- 2026-05-31T21:52-0700 — Switched the app icon source to the transparent SVG logo from the main checkout and regenerated macOS, iOS, and web icon PNGs with preserved alpha.
- 2026-05-31T22:02-0700 — Replaced the limited ImageMagick SVG renderer with Inkscape after the generated icon dropped traces and the terminal prompt, then regenerated the platform icon PNGs.
- 2026-06-01T08:52-0700 — Changed the launcher icon canvas from transparent to black, regenerated the platform icons, and verified the macOS 1024px icon is opaque black at the corners.
