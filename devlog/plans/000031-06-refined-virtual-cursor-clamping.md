## Thinking

We need to resolve a persistent cursor alignment issue in the triage-client terminal window for active sessions. Currently, WezTerm's virtual cursor inside the daemon gets desynchronized from the actual prompt during log replay. In the client, xterm.js forces the cursor to be visible, displaying it misplaced on trailing blank rows (such as 4 rows below where it should be in `session-11`) or standing directly on top of TUI status text (such as in `session-13` where the cursor lands on the 'f' in '? for shortcuts').

Our previous attempt limited clamping to exited sessions (`widget.isExited == true`) and failed to pass `isExited` dynamically from the main state to the `TerminalPane` widget, leaving `widget.isExited` always `false` in the web client.

To fix both issues:
1. We will update the `SessionVm` model in `lib/main.dart` to support a mutable `isExited` flag.
2. We will map the incoming session's exited state from snapshot and update it dynamically upon receiving the WebSocket `Exited` event.
3. We will pass `isExited: session.isExited` to both the web and stub `TerminalPane` widgets.
4. We will run the clamping logic unconditionally (for both active and exited sessions) in `_writeInitialContent`.
5. To prevent clamping from disrupting active full-screen editors (like `vim` or `nano`) when their cursor is naturally below prompt characters, we will implement a refined "look-ahead" checker. The clamping will ONLY be applied if all intermediate lines between `lastActiveRow + 1` and `C` (inclusive) are completely empty, divider lines, or status bars.

## Plan

1. **Modify `SessionVm`**:
   - Add mutable `bool isExited` field to `SessionVm` in `lib/main.dart`, defaulting to `false`.
   - Update constructions in `lib/main.dart` for attached sessions (both on list and on new attachments) to pass `snapshot['exited'] as bool? ?? false`.
   - Update `session.isExited = true` when processing the `Exited` event.

2. **Update `TerminalPane` Constructors**:
   - Add `isExited` to the stub constructor in `lib/widgets/terminal_pane_stub.dart`.
   - Update `TerminalPane` instantiation in `lib/main.dart` to pass `isExited: session.isExited`.

3. **Implement Refined Clamping in `terminal_pane_web.dart`**:
   - Add `_isStatusOrDividerRow` helper.
   - Refactor `_isPromptRow` to leverage `_isStatusOrDividerRow`.
   - Refactor `_writeInitialContent` to execute prompt/non-empty search and coordinates clamping unconditionally.
   - Inject the look-ahead check: verify that all lines between `lastActiveRow + 1` and `C` are status or divider rows. Only clamp if this check is satisfied.

4. **Verify changes**:
   - Run `flutter test` in `flutter/triage_client` to confirm all 18 tests continue to pass.
   - Verify visually via the web browser that the cursor position is correct on both shell and TUI sessions.
