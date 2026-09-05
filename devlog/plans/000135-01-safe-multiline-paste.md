# Plan: Safe Multi-Line Paste and Bracketed Paste Synchronization

## Thinking

When multi-line text (such as scripts, logs, or multi-command blocks) is pasted into Triage:
1. **Mobile Soft Keyboard (IME) Paste Leakage**:
   On mobile clients (Android / Pixel 10 Pro Fold and iOS), users paste via the soft keyboard (Gboard clipboard suggestion chip or clipboard manager). The IME commits the entire multi-line text block via Flutter's `TextInputClient.updateEditingValue`. This flows through `xterm.dart`'s `_onInsert` to `terminal.textInput(data)` and fires `_onTerminalOutput(data)` in `terminal_pane_stub.dart`.
   Previously, `_onTerminalOutput` forwarded `data` directly to `sendInput` without checking if it was multi-line and without applying bracketed paste formatting (`\x1b[200~` and `\x1b[201~`). As a result, the shell received unbracketed newlines (`\n`), interpreting each newline as a Return keypress and executing commands one line at a time.
2. **TerminalPane Bracketed Paste Mode Synchronization**:
   `SessionVm` tracks whether the active shell has DEC Mode 2004 enabled via `bracketedPasteEnabled` (updated from daemon snapshots and live mode events). However, `TerminalPane` did not take `bracketedPasteEnabled` as a parameter and relied solely on `_terminal.bracketedPasteMode`, which could lag or desync. Passing `bracketedPasteEnabled` directly into `TerminalPane` on both Web and Native ensures the pane immediately knows whether the shell supports bracketed paste.
3. **Web Reflection and Initialization**:
   On Flutter Web (`terminal_pane_web.dart`), `_isBracketedPasteEnabled()` attempted reflection via `js_util.getProperty` on Dart `xt.Terminal` objects, which failed under minification. Furthermore, `_term` in xterm.js defaults to `bracketedPasteMode = false` on initial creation and did not inherit the session's active mode upon binding.
4. **Safety Confirmation for Non-Bracketed Pastes**:
   When bracketed paste mode is inactive (e.g. in basic shells or programs that do not support DEC 2004), pasting multi-line text with newlines normalized to `\r` causes the shell to execute each line immediately. Standard terminal emulators (Ghostty, iTerm2) present a confirmation dialog warning the user and offering options to Cancel, Paste as Single Line (flattening newlines to spaces), or Paste (Execute Commands).

## Plan

1. **Add Multi-Line Paste Helper Utilities**:
   In `flutter/triage_client/lib/terminal/terminal_paste.dart`:
   - `isMultiLine(String text)`: checks for `\n` or `\r`.
   - `flattenToSingleLine(String text)`: replaces newline sequences (`\r\n`, `\r`, `\n`) with a single space.
   - `lineCount(String text)`: counts lines in the text string.
   - `formatPasteInput(String text, bool bracketedPasteEnabled)`: formats with bracketed paste escape sequences or normalizes newlines.

2. **Add Multi-Line Paste Safety Confirmation Dialog**:
   Create `flutter/triage_client/lib/widgets/multiline_paste_dialog.dart`:
   - `showMultiLinePasteDialog(BuildContext context, String text)`:
     - Displays preview with line count and byte size.
     - Offers "Cancel", "Paste as Single Line", and "Paste (Execute Commands)".

3. **Intercept Multi-Line Pastes in Native and Web Panes**:
   - In `terminal_pane_stub.dart`:
     - Add `bracketedPasteEnabled` parameter to `TerminalPane`.
     - Implement `_isBracketedPasteEnabled()` checking `widget.bracketedPasteEnabled || _terminal.bracketedPasteMode || _sessionBracketedPasteModes[widget.terminalId]`.
     - Implement `_handlePaste(String text)`: if bracketed or single-line, send formatted paste immediately; if unbracketed multi-line, show confirmation dialog.
     - In `_onTerminalOutput(String data)`: if `data.length > 1 && isMultiLine(data)`, route to `_handlePaste(data)` so Gboard/IME pastes are properly bracketed or confirmed rather than executed line by line.
     - In `_pasteFromClipboard()`: route clipboard text to `_handlePaste(text)`.
   - In `terminal_pane_web.dart`:
     - Add `bracketedPasteEnabled` parameter to `TerminalPane`.
     - Update `_syncInitialBracketedPasteMode()` and `_isBracketedPasteEnabled()`.
     - In `pasteListener` and `onData`: route multi-line text to `_handlePaste(text)`.
   - In `main.dart`:
     - Pass `bracketedPasteEnabled: session.bracketedPasteEnabled` to `TerminalPane`.

4. **Add Unit and Widget Tests**:
   - In `test/terminal/terminal_paste_test.dart`:
     - Test `formatPasteInput`, `isMultiLine`, `flattenToSingleLine`, `lineCount`.
     - Widget tests for `showMultiLinePasteDialog` ("Cancel", "Paste as Single Line", "Paste (Execute Commands)").
     - Test `SessionVm` bracketed paste synchronization.

5. **Build and Install to Pixel 10 Pro Fold**:
   - Run flutter tests to verify all tests pass.
   - Build Android APK via `flutter build apk`.
   - Install APK to the connected Pixel 10 Pro Fold using `adb -s adb-58291FDCG001G8-b6KQdx._adb-tls-connect._tcp install -r ...`.
   - Verify installation on the device.
