# Plan 000185-01: Restore Android Soft Keyboard Swipe Typing

## Thinking

1. Flutter's Android engine (`TextInputPlugin.inputTypeFromTextInputType`) sets both `InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS` and `InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD` whenever `enableSuggestions` is `false`. Combined with `TextInputType.text`, Android keyboards (Gboard, Samsung Keyboard, SwiftKey) identify the input as a visible password field and disable swipe/gesture typing.
2. Previously under `xterm.dart` / `xterm2`, `TerminalView` defaulted `keyboardType` to `TextInputType.emailAddress`, whose variation flag (`0x20`) combined with `VISIBLE_PASSWORD` (`0x90`) produced `0xb0` rather than `0x90`, avoiding password classification. Switching to `TextInputType.text` with `enableSuggestions: false` in the custom IME client triggered strict password mode.
3. Setting `enableSuggestions: true` with `TextInputType.text` and `autocorrect: false` instructs Android to expose normal `TYPE_CLASS_TEXT` without `VISIBLE_PASSWORD` or `NO_SUGGESTIONS`, enabling swipe typing and suggestions without forcing email keyboard keys or auto-correcting tapped shell commands.
4. Additionally, continuous swipe typing often batches a newly committed word (e.g. `"hello "`) before the active composing range of the next word (`"world"`). Tracking `_imeCommittedPrefix` lets `updateEditingValue` emit newly committed text before `composing.start` without calling `setEditingState` mid-composing, and cleanly reconciles any remaining suffix on final commit or `performAction`.

## Plan

1. Update `TerminalPane`'s `TextInputConfiguration` in `flutter/triage_client/lib/widgets/terminal_pane.dart` (`_syncImeConnection`) to set `enableSuggestions: true` (keeping `inputType: TextInputType.text`, `autocorrect: false`, `smartDashesType: SmartDashesType.disabled`, `smartQuotesType: SmartQuotesType.disabled`).
2. Add `_imeCommittedPrefix` tracking and extract shared IME diff/reset helpers (`_resetLocalImeState`, `_flushImeCommittedBeforeComposing`, `_emitImeDelta`) in `flutter/triage_client/lib/widgets/terminal_pane.dart` to handle single-word swipes, continuous multi-word composing batches, autocorrect replacements, and backspace across sentinel boundaries cleanly.
3. Add widget/unit regression tests in `flutter/triage_client/test/terminal_pane_ime_test.dart` verifying the attached `TextInputConfiguration`, single and consecutive swipe composing sequences (with `MobileAutoSpaceTracker`), batched committed-prefix + active-composing updates, `performAction` flush, and sentinel backspace deletion.
4. Run `flutter analyze` and `flutter test` on the client package.
5. Build the release Android APK, serve it from the scratch HTTP server, update the devlog `What Changed` and `Commits` sections, and commit cleanly on `fix/mobile-keyboard-swipe`.
