# Devlog 000193: fix/alt-screen-wheel-arrows

**Agent:** Gemini @ triage branch `fix/alt-screen-wheel-arrows`

## Intent

Port PR #216 (`fix/alt-screen-wheel-arrows`) onto the top of the `#212`-`#227` PR stack (`fix/tui-side-rail`) so alt-screen apps without mouse tracking stop receiving Up/Down arrow keys from mouse wheel, trackpad pan, or mobile swipe gestures.

## Progress

- [x] Create worktree `worktrees/fix-alt-screen-wheel-arrows` branched from `origin/fix/tui-side-rail`
- [x] Write plan (`devlog/plans/000193-01-alt-screen-wheel-arrows.md`)
- [x] Port alt-screen fallback removal to `terminal_pane.dart` and add regression test
- [x] Verify with `flutter analyze` and `flutter test` (`terminal_hardware_key_test.dart`: 39/39 passed)

## What Changed

- `2026-11-19T10:35-0800 flutter/triage_client/lib/widgets/terminal_pane.dart`: Updated `_shouldForwardWheelToTerminal` to check `_terminal.mouseMode < kMouseModeNormal` before `_terminal.isUsingAltBuffer` and removed the `encodeAltScreenFallbackWheel` fallback from `_sendWheelStep`.
- `2026-11-19T10:35-0800 flutter/triage_client/test/terminal_hardware_key_test.dart`: Added widget test confirming alt-screen swipe and wheel events without mouse tracking emit no input.

## Decisions

- `2026-11-19T10:35-0800 Decision`: Stack PR #216 onto `fix/tui-side-rail` (`#227`) rather than inserting below `#219`, keeping the existing green `#212`-`#227` stack commits untouched.

## Commits

- `HEAD` — `fix(client): stop translating alt-screen wheel/swipe into arrow keys`
