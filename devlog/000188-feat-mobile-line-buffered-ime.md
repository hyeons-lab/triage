# Devlog 000188: feat/mobile-line-buffered-ime

**Agent:** Gemini @ triage branch `feat/mobile-line-buffered-ime`

## Intent

Keep the active unsubmitted terminal line buffered inside the Flutter `TextInputConnection` on mobile (`_kImeSentinel + _imeLineBuffer`) instead of resetting to `_kImeSentinel` after every committed word, preserving swipe/autocorrect/prediction context across words until commit boundaries (Enter, accessory special keys, hardware keys, paste, focus loss, or session swap).

## Progress

- [x] Create stacked worktree `feat/mobile-line-buffered-ime` on `feat/mcp-templates-and-remote`
- [x] Write branch devlog and plan (`devlog/plans/000188-01-line-buffered-mobile-ime.md`)
- [x] Update `TerminalPane` IME state to retain the unsubmitted line buffer across non-composing word commits
- [x] Flush/reset buffer cleanly at Enter, newline text, accessory keys, focus loss, and session swap
- [x] Update and add tests in `flutter/triage_client/test/terminal_pane_ime_test.dart`
- [x] Run `dart format`, `flutter analyze`, and `flutter test`

## What Changed

- `2026-11-15T15:28-0800 flutter/triage_client/lib/widgets/terminal_pane.dart`: Renamed `_imeCommittedPrefix` to `_imeLineBuffer`, kept single-line non-composing edits in the `TextInputConnection` without calling `setEditingState` so mobile keyboards keep prior words in context for swipe spacing, autocorrect, and word-boundary backspace, flushed composing text on focus loss before closing the IME connection, and replenished `_kImeSentinel` at commit boundaries (Enter, inline newline, accessory keys, hardware keys, paste, sentinel underflow, and session swap).
- `2026-11-15T15:28-0800 flutter/triage_client/test/terminal_pane_ime_test.dart`: Replaced old per-word-reset expectation with line-buffered swipe, post-commit autocorrect, inline newline, multi-word + sentinel backspace, accessory key flush, and focus-loss flush tests.

## Decisions

- `2026-11-15T15:28-0800 Decision`: Retain `MobileAutoSpaceTracker` alongside line buffering so virtual keyboards that use buffered context produce native spaces (`"jello "`) without double-spacing while keyboards that omit context spacing still separate adjacent swiped words safely.

## Commits

- `HEAD`: `feat(client): buffer mobile IME line until enter or control key`
