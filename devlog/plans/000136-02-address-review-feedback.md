# Plan: Address Code Review Feedback for Safe Multi-Line Paste

## Thinking

A multi-lens code review on PR #157 identified key correctness, lifecycle, portability, and performance improvements across both Flutter Web and Native implementations:

1. **Dialog Re-entrancy & Modal Stacking**:
   `_handlePaste` is asynchronous. Rapid paste events (e.g. repeated `Cmd+V` / `Ctrl+V` chords or bursty mobile IME commitments) trigger concurrent calls to `showMultiLinePasteDialog`, stacking multiple modal warning dialogs on top of the Navigator stack. When the user confirms or cancels the top dialog, duplicate dialogs remain visible underneath and can transmit duplicate paste inputs. A boolean guard (`_isPasteDialogShowing`) must be added to `_TerminalPaneState` across both platforms to drop or ignore overlapping paste requests while a dialog is active.

2. **Session Termination While Dialog is Active**:
   `showMultiLinePasteDialog` is an asynchronous modal prompt. While the user reads the warning, the underlying shell or PTY may exit (`widget.isExited == true` or session disconnection). Both native and web implementations currently only verify `if (chosenText != null && mounted)`. Neither verifies `!widget.isExited`. Calling `sendInput` on a terminated session sends commands to a closed PTY. We must verify `!widget.isExited` both at the entry of `_handlePaste` and immediately after the dialog await resolves.

3. **Soft Keyboard Single Enter Keystroke Interception**:
   In `terminal_pane_stub.dart`, line 596 checks `data.length > 1 && isMultiLine(data)`. On certain mobile virtual keyboards (or Bluetooth keyboards), pressing the Enter key transmits CRLF (`\r\n`). Because `"\r\n".length == 2` and `isMultiLine("\r\n") == true`, this intercepts standard Enter keypresses and opens the confirmation dialog. We must explicitly exempt single CRLF sequences (`data != '\r\n'`).

4. **Mobile Web IME Multi-Line Interception**:
   In `terminal_pane_web.dart`, `onDataCallback` forwards committed data directly to `_sessionInputRouter.sendInput`. On mobile web, pasting from soft keyboard clipboard chips or committing multi-line IME text bypasses DOM paste events and flows directly through `onDataCallback`. We must add multi-line interception in `onDataCallback` to route through `_handlePaste` so mobile web users receive the same safety protection as native mobile users.

5. **Reactive Mode Synchronization in `didUpdateWidget`**:
   When a session dynamically enables or disables DEC Mode 2004 (e.g. entering or exiting Vim), `SessionWorkspace` rebuilds with an updated `bracketedPasteEnabled`. However, `didUpdateWidget` ignores this change. On Web, `_isBracketedPasteEnabled()` checks `_term.modes.bracketedPasteMode` and `_sessionBracketedPasteModes`. If bracketed paste mode was once enabled, disabling it in the parent widget never clears `_term.modes.bracketedPasteMode`, locking bracketed paste permanently on for that session. We must synchronize `bracketedPasteEnabled` to `_sessionBracketedPasteModes` and `_term.modes` / `_terminal` on both platforms during `didUpdateWidget`.

6. **Zero-Allocation Character Scan & Trailing Line Ending Normalization**:
   `lineCount` in `terminal_paste.dart` uses `_newlinePattern.allMatches(text).length + 1`, allocating `RegExpMatch` instances for every line in the clipboard. On large paste buffers, this causes heavy GC churn on the UI thread. In addition, when text terminates with a command terminator newline (e.g. `echo hello\n`), it counts 2 lines instead of 1. Replacing this with an O(N) single-pass ASCII scan over `text.codeUnitAt(i)` eliminates allocations and allows cleanly disregarding a trailing command newline.

7. **Preview Snippet Bounded Slicing**:
   In `multiline_paste_dialog.dart`, calling `text.split(RegExp(...))` eagerly instantiates all lines in the buffer into a `List<String>`. Scanning lazily for the first 6 line breaks avoids allocating thousands of throwaway strings, and capping individual preview lines at 200 characters prevents Flutter layout freezes on minified single lines.

8. **Web DOM Focus Restoration**:
   After `showMultiLinePasteDialog` resolves on Web, invoking `_activateTerminal()` restores DOM focus to `_term` so the user can immediately continue typing.

9. **Static Map Hygiene**:
   Remove redundant `sessionId` registration in `SessionVm.setBracketedPasteEnabled` since `TerminalPane` is always keyed by `title` and `destroySession` only removes `title`.

10. **Test Coverage**:
    Add tests for preview snippet truncation (`lines > 6`), size formatting (`KB`), and line ending edge cases.

## Plan

1. **Update `terminal_paste.dart`**:
   - Add library declaration at top (`library;`) to satisfy doc comment linter.
   - Export shared `newlinePattern = RegExp(r'\r\n|\r|\n');`.
   - Re-implement `lineCount` using an O(N) zero-allocation loop over `text.codeUnitAt(i)`, ignoring a trailing command terminator newline.
2. **Update `multiline_paste_dialog.dart`**:
   - Extract up to 6 preview lines lazily without splitting the entire buffer.
   - Cap preview line width at 200 characters.
   - Support KB and MB formatting thresholds.
3. **Update `terminal_pane_stub.dart`**:
   - Add `_isPasteDialogShowing` guard.
   - In `_onTerminalOutput`, exempt `data == '\r\n'`.
   - In `_handlePaste`, check `widget.isExited` at entry and post-await, wrap in try/catch and finally guard.
   - In `didUpdateWidget`, synchronize `bracketedPasteEnabled` to `_sessionBracketedPasteModes` and `_terminal`.
   - Place `_sessionBracketedPasteModes` on `_TerminalPaneState` with accessors on `TerminalPane`.
4. **Update `terminal_pane_web.dart`**:
   - Add `_isPasteDialogShowing` guard.
   - In `onDataCallback`, intercept multi-line input (`data.length > 1 && isMultiLine(data) && data != '\r\n'`).
   - In `_handlePaste`, check `widget.isExited` at entry and post-await, wrap in try/catch and finally guard, and refocus terminal with `_activateTerminal()`.
   - In `didUpdateWidget`, synchronize `bracketedPasteEnabled` to `_sessionBracketedPasteModes` and `_term.modes.bracketedPasteMode`.
5. **Update `main.dart`**:
   - Simplify `SessionVm.setBracketedPasteEnabled` to only key `TerminalPane.setBracketedPasteMode` by `title`.
6. **Extend `terminal_paste_test.dart`**:
   - Add widget test for truncated preview snippet (`lines > 6`) verifying `... (N more lines)`.
   - Add widget test for size label `>= 1024` bytes (`KB`).
   - Add unit tests for `lineCount` edge cases (trailing newline, lone CRLF, consecutive newlines).
7. **Validate and Test**:
   - Run `flutter analyze --no-fatal-infos --no-fatal-warnings`.
   - Run `flutter test`.
   - Run `cargo fmt --all -- --check` and `cargo clippy`.
8. **Devlog and Commit**:
   - Update `devlog/000135-fix-safe-multiline-paste.md`.
   - Commit changes with Conventional Commit `fix(client): address PR #157 review feedback for safe multiline paste`.
   - Push to `origin/fix/safe-multiline-paste`.
   - Monitor CI checks.
