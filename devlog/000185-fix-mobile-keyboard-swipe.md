# 000185: fix/mobile-keyboard-swipe

**Agent:** Antigravity (Claude Sonnet 4.5 / Gemini) @ triage branch fix/mobile-keyboard-swipe

## Intent

Restore soft keyboard swipe/gesture typing on mobile (particularly Android Gboard and similar IMEs) in `TerminalPane` after the `RenderTerminalGrid` migration, and ensure multi-word swipe composing streams committed words incrementally without losing or duplicating text.

## What Changed

- `2026-11-15T08:27-0800 devlog/plans/000185-01-restore-android-keyboard-swipe.md`: Authored plan covering `TextInputConfiguration` `enableSuggestions` restoration and incremental composing prefix flushing.
- `2026-11-15T08:28-0800 flutter/triage_client/lib/widgets/terminal_pane.dart`: Enabled `enableSuggestions: true` on `TextInput.attach`, tracked `_imeCommittedPrefix` for multi-word swipe composing batches, and extracted `_resetLocalImeState` / `_emitImeTextDiff`.
- `2026-11-15T08:29-0800 flutter/triage_client/test/terminal_pane_ime_test.dart`: Added Android widget tests verifying `TextInputConfiguration`, single and batched swipe composing sequences with `MobileAutoSpaceTracker`, newline composing flush, and sentinel backspace diffs.

## Decisions

- `2026-11-15T08:27-0800` Decision: Enable `enableSuggestions: true` (keeping `inputType: TextInputType.text`, `autocorrect: false`, `smartDashesType: SmartDashesType.disabled`, `smartQuotesType: SmartQuotesType.disabled`) in `TerminalPane`'s `TextInputConfiguration` so Flutter Android emits `InputType.TYPE_CLASS_TEXT` instead of `TYPE_TEXT_FLAG_NO_SUGGESTIONS | TYPE_TEXT_VARIATION_VISIBLE_PASSWORD`, which disabled gesture typing across Android keyboards.
- `2026-11-15T08:27-0800` Decision: Track `_imeCommittedPrefix` in `_TerminalPaneState` so batched multi-word swipes (committed words preceding an active `composing` range) emit incrementally without resetting the platform IME buffer mid-composing.

## Commits

- HEAD: fix(client): restore mobile keyboard swipe typing and incremental IME composing
