# Flutter Web Terminal Spike

## Thinking

Phase 6 should not start with pairing, TLS, or full remote-client workflow because the main stack risk is still the browser terminal rendering bridge. The smallest useful slice is a Flutter Web app that can mount xterm.js inside a Flutter widget, write deterministic terminal bytes into it, capture user input from xterm.js, and react to Flutter-side size changes.

Flutter tooling is not installed in this environment, so this plan keeps the branch reviewable and ready for validation without depending on generated files from `flutter create`.

## Plan

1. Add a minimal `flutter/argus_client` scaffold with `pubspec.yaml`, web entrypoint assets, and a small app surface.
2. Implement a web-only `TerminalPane` widget backed by `HtmlElementView` and a JavaScript xterm.js bridge.
3. Add deterministic terminal demo output plus input echo so the bridge can be verified before daemon WebSocket hosting exists.
4. Document the validation gap caused by missing local Flutter tooling and leave the branch ready for `flutter pub get`, `flutter analyze`, and `flutter test`.
