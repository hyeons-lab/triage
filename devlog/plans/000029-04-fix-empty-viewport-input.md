# Plan - Fix Empty Snapshot Replay Cursor Clamping

## Thinking
When the remote client switches to a newly restored session (such as `session-15` or `session-16`), the daemon sends an initial snapshot where `visible_rows` contains only empty/whitespace rows, but the actual PTY's `initialCursorRow` is set to a non-zero index (e.g. 6) and `initialCursorCol` is set to 0. 

In `computeReplayCursorPlacement` inside `flutter/triage_client/lib/widgets/terminal_replay.dart`, we scan the snapshot rows for a prompt or any non-empty text to determine `lastActiveRow`. Because all rows in the snapshot are completely empty or whitespace-only, the scans find no active rows, leaving `lastActiveRow` at its default of `0`.

Since `cursorRow` (e.g. 6) is greater than `lastActiveRow` (0), the clamping check `cursorRow > lastActiveRow` evaluates to `true`. This causes `shouldClamp` to be `true`, which clamps the cursor position back to `0, 0` (`1;1` in xterm.js). When subsequent live output arrives from the PTY, it starts writing from the PTY's expected cursor position (row 6), but xterm's cursor has been misplaced at row 0, leading to broken terminal flows and layouts.

To resolve this coordinate mismatch, we must identify if the snapshot is entirely empty (all rows are empty/whitespace-only). If the snapshot is completely blank, we must avoid clamping the valid PTY cursor row and column as long as `cursorRow` is within the snapshot's row count bounds.

Additionally, to prevent any edge cases where a session's static suppression flag remains `true` after switching tabs, we will ensure that `_sessionSuppressData` is removed or set to `false` during the `TerminalPane` state initialization, unmounting, and disposal.

## Plan
1. Modify `computeReplayCursorPlacement` inside `flutter/triage_client/lib/widgets/terminal_replay.dart` to identify when all `fallbackRows` are completely empty.
2. Skip cursor row clamping to `lastActiveRow` when all rows are empty, as long as `cursorRow >= 0 && cursorRow < fallbackRows.length`.
3. Add a unit test in `flutter/triage_client/test/cursor_position_test.dart` to cover the blank/empty snapshot scenario, verifying that the cursor row and column remain unclamped and correct.
4. Run `flutter test` and `npm run test:xterm` to verify the fix and ensure no regressions.
