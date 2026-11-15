# Plan 000188-01: Line-Buffered Mobile IME in TerminalPane

## Thinking

Previously, `TerminalPane` stored only `_imeCommittedPrefix` for words committed mid-composing, and as soon as `value.composing` ended in `updateEditingValue`, it called `_resetImeSentinel()` (`setEditingState('  ')`), wiping the platform `EditText` back to two spaces after every single word.

While resetting every word keeps the buffer short, it breaks mobile virtual keyboard context:
- Gboard/Samsung/iOS keyboards cannot see the previous words on the current command line for multi-word swipe spacing, contextual prediction, or tap-to-autocorrect replacement.
- Backspacing into a previously committed word after lifting a finger can only backspace blindly from `'  '`.

Because `_emitImeTextDiff(expected, actual)` already computes the longest common prefix (respecting UTF-16 surrogate pairs) and emits minimal `\x7f` backspaces plus the inserted suffix, we can keep the current unsubmitted line (`_imeLineBuffer`) in `_currentImeValue` across word commits without calling `setEditingState('  ')` until a real commit boundary occurs:
1. Soft/hard Enter (`performAction` or `\n`/`\r` in `updateEditingValue`).
2. Accessory special keys (`_sendAccessory`, `_toggleCtrl`).
3. Hardware key events (`onKeyEvent`).
4. Paste (`_handlePaste`).
5. Focus loss (`_onFocusChanged` unfocus, flushing before closing IME connection) or session swap (`didUpdateWidget` `sessionSwapped`, resetting without cross-session leakage).
6. Deleting into or corrupting the leading `_kImeSentinel` prefix (replenishing `'  '` so continuous backspacing at an empty buffer keeps working).

`MobileAutoSpaceTracker` stays active on mobile output so if a keyboard commits adjacent words without a space it still separates them cleanly, while Gboard-inserted spaces (`'jello '` ahead of `'world'`) pass through untouched without double spaces.

## Plan

1. Rename `_imeCommittedPrefix` to `_imeLineBuffer` in `flutter/triage_client/lib/widgets/terminal_pane.dart` for clarity across the whole unsubmitted line lifecycle.
2. Update `updateEditingValue` so non-composing edits that start with `_kImeSentinel` and contain no line breaks retain `_currentImeValue` on the platform `InputConnection` and update `_imeLineBuffer = text.substring(_kImeSentinel.length)` instead of resetting to `'  '`, while still emitting minimal diffs (`_emitImeTextDiff`) and resetting `_mobileAutoSpace` when empty or broken by a boundary.
3. Replenish `_resetImeSentinel()` only when `text` contains `\n`/`\r`, fails the `_kImeSentinel` prefix check (e.g., backspace from empty `'  '` -> `' '`), or places selection inside the sentinel when empty.
4. Flush `_flushImeComposing()` on focus loss before `_syncImeConnection()` closes the connection (when mounted and not exited).
5. Update `flutter/triage_client/test/terminal_pane_ime_test.dart` to test line-buffered multi-word swipe composition without sentinel resets, post-commit autocorrect replacement, backspace across word boundaries and past the sentinel, Enter flush, accessory-key boundary reset, and focus-loss flush.
6. Run `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, and `flutter test`, then update the devlog and commit.
