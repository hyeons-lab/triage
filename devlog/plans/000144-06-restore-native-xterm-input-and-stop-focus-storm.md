# Plan: Restore Native xterm.js Keyboard Pipeline and Eliminate Focus Storm

## Thinking

Users experienced dropped keystrokes in the web client: entering characters occasionally but failing on most keystrokes. Investigation revealed the exact dual root cause:

1. **Perpetual Focus Storm and Timer Churn**:
   - In `terminal_pane_web.dart`, every keydown event in `_windowKeyDownListener` invoked `_focusNode.requestFocus()` because DOM focus on the xterm helper `<textarea>` left Flutter's `_focusNode.hasFocus` as false.
   - Requesting Flutter focus fired `Focus.onFocusChange(true)`, which called `_activateTerminal(force: true)` and scheduled a ladder of retry timers at 50ms, 150ms, and 300ms.
   - In `_scheduleFocusRetries`, the short-circuit condition checked `if (_isActiveElementInTerminal() && _focusNode.hasFocus)`. Because Flutter focus and native DOM focus are mutually distinct when typing in an `HtmlElementView`, this condition was never satisfied while focused on the textarea.
   - Consequently, the timers continuously fired on every keystroke, calling `textarea.focus()` and `_term.focus()` while typing was in progress.
   - In Chromium and Brave, calling `.focus()` on a DOM element during active typing cancels in-flight keyboard dispatch and resets IME/input method states, causing 90% of keystrokes to be dropped.

2. **Disabled Native xterm.js Input Pipeline on Desktop Web**:
   - In commit `0d74e54`, `onDataCallback` was restricted on desktop web to mouse tracking sequences (`\x1b[<` and `\x1b[M`), shutting off xterm.js's native `onData` callback.
   - Desktop web attempted to manually translate every key in `_keyboardEventToInput()`. This broke full-screen TUI apps like Codex that require application cursor keys mode (`DECCKM`, `\x1bOA` vs normal `\x1b[A`), keypad modes, and native terminal key translations that xterm.js manages internally.

The clean architectural resolution:
1. **Restore Native xterm.js Input Ownership**:
   - Allow `onDataCallback` to forward all data from xterm.js to `_sessionInputRouter.sendInput(sessionId, data)` on desktop and mobile alike.
   - Attach `attachCustomKeyEventHandler` on `_term` to intercept Tab (preventing browser focus escape and routing `\t` or `\x1b[Z`) and copy/paste shortcuts, while returning `true` for all other keys so xterm.js handles them natively.
2. **Gate Window Keydown on Active Terminal**:
   - When `_isActiveElementInTerminal()` is true, `_windowKeyDownListener` immediately returns early without calling `preventDefault()`, `stopPropagation()`, `_sendInput()`, or `_focusNode.requestFocus()`. The browser delivers the event directly to xterm.js's focused helper textarea.
   - When `_isActiveElementInTerminal()` is false, `_windowKeyDownListener` translates the initial ambient keystroke, sends it, and activates the terminal. All subsequent keystrokes flow natively into xterm.js.
3. **Eliminate the Focus Storm**:
   - Remove `_focusNode.requestFocus()` from `_windowKeyDownListener` and `_activateTerminal()`.
   - In `_scheduleFocusRetries()`, short-circuit and cancel timers as soon as `_isActiveElementInTerminal()` is true.
   - Ensure `_bindTextareaEvents()` is only called when `_isMobile == true`.

## Plan

1. **Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart`**:
   - In `_windowKeyDownListener`:
     - Keep Copy/Paste bypass.
     - Add `if (_isActiveElementInTerminal()) return;` before ambient key translation.
     - Remove `_focusNode.requestFocus()` call on keydown.
   - In `_scheduleFocusRetries()`:
     - Change short-circuit check from `_isActiveElementInTerminal() && _focusNode.hasFocus` to `_isActiveElementInTerminal()`.
   - In `_activateTerminal()`:
     - Remove `_focusNode.requestFocus()`.
     - Guard `_bindTextareaEvents()` with `_isMobile`.
   - In `_bindTerminalSubscriptions()`:
     - Remove `if (!_isMobile)` mouse-only filter from `onDataCallback` so all keyboard and terminal data from xterm.js flows to `_sessionInputRouter.sendInput(sessionId, data)`.
     - Re-attach `attachCustomKeyEventHandler` to capture Tab key navigation and keep focus in terminal.
2. **Validate**:
   - Run `flutter analyze` in `flutter/triage_client`.
   - Run `flutter test` in `flutter/triage_client`.
   - Run `cargo fmt --all -- --check`.
   - Run `cargo clippy --all-targets --all-features -- -D warnings`.
   - Rebuild release web client and daemon: `cargo build --release -p triaged`.
   - Re-sign binary: `codesign -s - -f ~/.cargo/bin/triaged`.
   - Reload daemon via zero-downtime process handover: `~/.cargo/bin/triaged reload`.
   - Verify zero-downtime handover in `~/.local/state/triage/triaged.log`.
3. **Document & Push**:
   - Update `devlog/000144-fix-web-terminal-focus-lifecycle.md` (What Changed, Decisions, Commits with `HEAD`).
   - Commit with Conventional Commits: `fix(triage_client): restore native xterm input pipeline and eliminate focus storm`.
   - Push to `origin HEAD:refs/heads/fix/web-terminal-focus-lifecycle`.
   - Update PR #167 description.
