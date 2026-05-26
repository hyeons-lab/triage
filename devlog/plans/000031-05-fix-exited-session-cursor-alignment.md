## Thinking

We are fixing a subtle cursor misalignment that persists in exactly 1 out of 3 session windows (specifically `session-11`, which has exited).
Upon diagnostic query, we discovered that `session-11` has a total height of 30 visible rows, but Wezterm's active styled viewport starts at absolute index 6 (meaning lines 6 to 29 are the last 24 lines, all of which are empty).
The actual user prompt `"dberrios@rogflowz13:/mnt/c/Users/iamst$"` is at absolute index 3.
Because Wezterm's virtual cursor is reported at absolute index 6, the web pairing client:
1. Merges the 30 lines.
2. Computes the relative cursor row `C` to be 6.
3. Because the fitted height is 24 and `C = 6`, the windowed writing logic starts at `startRow = 6` (clamped to the bottom 24 rows).
4. The client's terminal displays a completely blank screen, with the cursor placed at row 1 (viewport row 0). The actual prompt at absolute index 3 is completely hidden from view.

To solve this:
1. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`, when a session has exited, we search for the last non-empty row in the fallback rows list (`lastActiveRow`).
2. If `initialCursorRow` is placed on an empty line *below* `lastActiveRow`, we dynamically reposition `C` (the cursor row) to `lastActiveRow`, and reposition `col` (the cursor column) to the length of the text on that row.
3. This shifts the active viewport window (`startRow`) to include the last non-empty row (the prompt), rendering the prompt correctly at the very top of the terminal screen, with the cursor positioned exactly at the end of the prompt.
4. We also add an `isExited` flag to `TerminalPane` to disable cursor blinking and hide the active caret block entirely for exited sessions to provide a clean static terminal view.
5. We initialize the session's `status` and `statusColor` correctly in `lib/main.dart` based on the snapshot's `exited` field, ensuring that already-exited sessions show up as grey and dead immediately upon connecting.

## Plan

1. **Modify TerminalPane Widget Interface**:
   - Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart` and `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` to add `final bool isExited;` defaulting to `false` in the `TerminalPane` constructors.
2. **Update Main App Entrypoint**:
   - In `flutter/triage_client/lib/main.dart`, pass `isExited: session.status == 'exited'` to `TerminalPane`.
   - In the session initial loading blocks in `lib/main.dart` (lines 544 and 766), read `snapshot?['exited'] as bool? ?? false` and initialize the session `status` as `'exited'` (color `0xff7f8b8d`) instead of `'attached'` if it is already dead.
3. **Implement Exited Cursor Position & Hiding Logic**:
   - In `_writeInitialContent` of `terminal_pane_web.dart`, if `widget.isExited` is true, locate the last non-empty row index. If the cursor is positioned below this row, clamp the cursor row and position it at the end of the active prompt row text.
   - If `widget.isExited` is true, configure xterm.js with `cursorBlink: false` and set the cursor theme color to `transparent` to hide the active blinking block.
   - Update `didUpdateWidget` in `terminal_pane_web.dart` to dynamically update xterm.js options if `widget.isExited` changes.
4. **Validate**:
   - Run `flutter test` in `flutter/triage_client` to verify all tests continue to pass.
   - Build/check compiling correctly.
