# Argus Flutter Client

This is the Phase 6 Spike A scaffold for proving xterm.js inside Flutter Web.

The first target is intentionally web-only:

- `lib/main.dart` builds a minimal terminal spike surface.
- `lib/src/terminal/terminal_pane.dart` owns the Flutter `HtmlElementView` boundary.
- `web/terminal_bridge.js` owns xterm.js setup, resize fitting, writes, and input callbacks.

Validation once Flutter is installed:

```bash
cd flutter/argus_client
flutter pub get
flutter analyze
flutter test
flutter run -d chrome
```
