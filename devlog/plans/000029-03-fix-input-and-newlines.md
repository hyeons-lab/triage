# Plan - Fix Input Block on Session Switch and Carriage Return Overwrite

## Thinking
When switching sessions in the remote client, the browser focus shifts away from the terminal container, causing `_focusNode.hasFocus`, `activeElementInTerminal`, and `eventPathInTerminal` to evaluate to `false`. As a result, the window keydown listener ignores all global keystrokes. Alphanumeric and navigation inputs are completely silenced.
Additionally, during the terminal's initial content replay, a carriage return (`'\r'`) is written directly before flushing the pending live output buffer. Writing `\r` shifts the caret to column 0 of the prompt row, causing subsequent live updates or user keystrokes to overwrite the prompt instead of appending to it.

To solve these issues:
1. Replace the strict `shouldHandleTerminalKey` check with a permissive focus check: capture all keyboard events on the window *unless* the user is actively typing inside a standard input, textarea, or content-editable element, and the active session is not exited.
2. Remove the redundant `\r` write before flushing the pending live write buffer in `_onFit()`, allowing live output to cleanly append directly at the cursor's replayed position.

## Plan
1. Update `_windowKeyDownListener` inside `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to use permissive input capture logic (`!isTypingInInput && !widget.isExited`).
2. Remove the `js_util.callMethod(_term, 'write', ['\r']);` call inside `_onFit()` in `flutter/triage_client/lib/widgets/terminal_pane_web.dart` before writing the pending live write buffer.
3. Verify that keyboard inputs work immediately upon session selection without requiring the user to click the terminal.
4. Verify layout and newline alignment correctness during session switching and live text input.
