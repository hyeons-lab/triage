# 000088 — Mobile touch input: soft keyboard + key accessory bar

**Agent:** Claude (claude-opus-4-8) @ triage branch feat/mobile-touch-input

## Intent

Make the native Flutter app usable from a phone (iOS + Android). First slice of
Phase 7: get the existing shared-codebase app to accept input on a touch device
so it can be driven over Tailscale. Rendering (`xterm.dart`) already works; the
input path did not.

## Research & Discoveries

- 2026-07-11T22:38-0700 `terminal_pane_stub.dart:766` passed
  `hardwareKeyboardOnly: true` unconditionally. Added for a macOS-desktop IME
  desync, but it disables xterm's IME `TextInput` connection — the path that
  raises the **soft keyboard** on iOS/Android. Net effect: on a phone the
  terminal renders but cannot receive typed input. This is the single blocker to
  on-device usability.
- No `Platform.isIOS`/`isAndroid` UX branches existed anywhere in `lib/`;
  `defaultTargetPlatform` was used only for the copy chord. All pointer handling
  (shift-click, primary-button drag-select) is desktop-oriented.

## Decisions

- 2026-07-11T22:38-0700 Make `hardwareKeyboardOnly` platform-conditional
  (`!_isMobile`) rather than dropping it — desktop keeps the macOS IME fix.
- 2026-07-11T22:38-0700 Put the accessory bar in the native pane, not
  `SessionWorkspace`, so it never renders on the web client.
- 2026-07-11T22:38-0700 Apply sticky Ctrl by intercepting `_onTerminalOutput`
  (`codeUnit & 0x1f`) rather than synthesizing hardware key events, since
  soft-key input already flows through that seam.

## Plan

See `devlog/plans/000088-01-mobile-touch-input.md`.

## What Changed

- 2026-07-11T22:50-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
  - **Soft keyboard:** `hardwareKeyboardOnly` is now `!_isMobile` — desktop keeps
    the hardware-keyboard path (and the macOS IME-desync fix), iOS/Android use
    the IME path that raises the soft keyboard. `_isMobile` is a getter over
    `defaultTargetPlatform` (iOS/Android).
  - **Accessory bar:** `build()` now returns `Column[Expanded(terminal),
    if (_isMobile) _buildAccessoryBar()]`; the bar is a horizontally-scrollable
    row of keys a soft keyboard lacks (Esc, Ctrl, Tab, ▲▼◀▶, ^C, `/ | - ~`).
    Keys use a raw `GestureDetector` (no focus node) and re-focus the terminal
    after each tap so the keyboard is never dismissed. Mobile padding tightened
    to 8 (was 22).
  - **Sticky Ctrl:** the `ctrl` key arms `_ctrlArmed`; `_onTerminalOutput` folds
    an armed Ctrl into the next single character via the new top-level
    `controlByteForChar` (`codeUnit & 0x1f`), then disarms. Reset on session
    swap in `didUpdateWidget` so it can't leak across sessions.
- 2026-07-11T22:50-0700 `flutter/triage_client/test/terminal_control_byte_test.dart`
  — unit tests for `controlByteForChar` (letter case-folding, the `@[\]^_`
  range, null for no-control chars, single-char guard).

## Issues

- 2026-07-11T22:38-0700 The native pane's `build()` short-circuits to a plain
  fallback view under `FLUTTER_TEST`, so the accessory bar / TerminalView path is
  unreachable in widget tests. Tested the sticky-Ctrl mapping by extracting it to
  the top-level `controlByteForChar` and unit-testing that directly, rather than
  fighting the fallback gate.

## Validation

- 2026-07-11T22:50-0700 `flutter analyze lib/widgets/terminal_pane_stub.dart` —
  no issues in the changed file. `flutter analyze --no-fatal-infos
  --no-fatal-warnings` (CI's command) passes (pre-existing backlog only, none in
  this file). `flutter test` — 100 passed. Matches the CI "Flutter (analyze +
  test)" job; CI does not build iOS/Android.
- 2026-07-11T22:50-0700 `/review-fix-loop max` — 2 rounds, stopped clean. Fixed:
  sticky Ctrl reset on session swap; arrow-glyph `fontFamilyFallback`. Skipped
  (by-design): Ctrl staying armed across multi-char IME input.

## Next Steps

- On-device build + validation (iOS + Android) over Tailscale — needs the user's
  device/signing; the xterm.dart scroll-region spike lands here.
- PR 2 (touch polish): long-press selection, paste, rotate/resize, safe-area.

## Commits

- HEAD — feat(triage_client): mobile soft keyboard + key accessory bar
