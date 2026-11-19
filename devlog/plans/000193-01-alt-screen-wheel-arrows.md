# Plan 000193-01: Stack PR #216 (`fix/alt-screen-wheel-arrows`) on `fix/tui-side-rail`

## Thinking

PR #216 (`fix/alt-screen-wheel-arrows`) originally targeted `main` and modified `terminal_pane_stub.dart` and `terminal_pane_web.dart`, which were unified into `terminal_pane.dart` by PR #212 (`feat/terminal-cell-sync`). To keep all outstanding PRs in one linear stack without modifying the green `#212`-`#227` chain, port the alt-screen wheel/swipe suppression to `terminal_pane.dart` on top of `fix/tui-side-rail` (`#227`) and pin the behavior with a widget test.

## Plan

1. Branch `fix/alt-screen-wheel-arrows` from `origin/fix/tui-side-rail`.
2. Stop forwarding wheel/pan-zoom/touch-swipe events into `encodeAltScreenFallbackWheel` when `mouseMode < kMouseModeNormal` in `flutter/triage_client/lib/widgets/terminal_pane.dart`.
3. Add a regression test in `flutter/triage_client/test/terminal_hardware_key_test.dart` verifying alt-screen wheel and swipe without mouse tracking emit no arrow keys.
4. Run `flutter analyze` and `flutter test`, record devlog `000193`, and commit.
