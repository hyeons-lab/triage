# Plan: Unify Desktop Web Terminal Keyboard Input and Eliminate Split-Brain Gating

## Thinking

Prior attempts to support keyboard input in the Flutter web client suffered from a fundamental architectural conflict: splitting keyboard handling between a window-level capture listener (`_windowKeyDownListener`) and xterm.js's hidden helper `<textarea>` DOM event listener (`term.onData`), then attempting to dynamically switch between them using `_isActiveElementInTerminal()`.

In Flutter Web, platform views (`HtmlElementView`) are embedded inside Shadow DOM elements under or alongside `<flt-glass-pane>`. As a result:
1. When the terminal is active, `_isActiveElementInTerminal()` evaluated to true, causing `_windowKeyDownListener` to return early and leave key events to xterm.js's textarea.
2. But physical keystrokes in Flutter Web do not reliably flow into xterm.js's hidden helper textarea because Flutter's event listeners, glass pane, and focus managers intercept them.
3. This left the user unable to type or backspace reliably: only occasional keystrokes that arrived while focus was momentarily outside the terminal were caught by the window listener (which sent one character and immediately refocused the textarea, suppressing all subsequent keystrokes).
4. Conversely, running both listeners concurrently previously caused duplicate keystrokes, leading to fragile 35ms timestamp deduplication (`_InputDedupeRecord`) that dropped fast typing and repeated Backspaces.

The robust, clean solution is to establish a single authoritative source of truth for desktop web keyboard input:
- The window capture keydown listener (`_windowKeyDownListener`) authoritatively translates and dispatches all keyboard events for the active terminal pane, calling `event.preventDefault()` and `event.stopPropagation()`.
- xterm.js onData is restricted on desktop web to terminal mouse tracking sequences (`\x1b[<` and `\x1b[M`), while continuing to support virtual soft keyboard inputs on mobile web.
- All timestamp deduplication records and timers (`_InputDedupeRecord`, `_sessionInputDedupe`) are completely removed, allowing rapid typing, double characters, and key-repeat Backspaces to flow with zero drops.
- Redundant listeners (`attachCustomKeyEventHandler` on `_term` and `_containerKeyDownSubscription`) are eliminated.
- Full keyboard fidelity is preserved: navigation keys, Ctrl modifiers, Alt word navigation, Shift sequences, function keys F1 to F12, Insert, Delete, and macOS Cmd shortcuts.

## Plan

1. **Remove `_InputDedupeRecord` and `_sessionInputDedupe`**:
   - Delete `_InputDedupeRecord` class and `_sessionInputDedupe` static map.
   - Clean up cleanup references in `_discardCachedSession` and `_sendMobileInput`.

2. **Make `_windowKeyDownListener` Authoritative on Desktop**:
   - Remove `_isActiveElementInTerminal()` gating so active terminal panes process every keystroke.
   - Preserve native IME composition (`event.isComposing == true || event.key == 'Process'`).
   - Preserve Copy (Cmd+C / Ctrl+C with active selection) and Paste (Cmd+V / Ctrl+V passed to browser paste event).
   - Translate all other keys via `_keyboardEventToInput(event)`, call `event.preventDefault()` and `event.stopPropagation()`, and dispatch via `_sendInput(input)`.

3. **Expand `_keyboardEventToInput` for Complete Terminal Navigation**:
   - Add macOS Cmd+K terminal clear (`\x0c`).
   - Add Ctrl+Home (`\x1b[1;5H`) and Ctrl+End (`\x1b[1;5F`).
   - Add Alt+Enter (`\x1b\r`) and Alt+Delete (`\x1b[3;3~`).
   - Add Shift+Home (`\x1b[1;2H`), Shift+End (`\x1b[1;2F`), Shift+PageUp (`\x1b[5;2~`), Shift+PageDown (`\x1b[6;2~`).
   - Add Insert (`\x1b[2~`) and function keys F1 through F12.
   - Bypass Ctrl+Shift+R and Ctrl+Shift+I to allow browser hard-reload and devtools.

4. **Guard `onDataCallback` on Desktop**:
   - On desktop web (`!_isMobile`), ignore keyboard events from xterm.js onData and only forward terminal mouse tracking escape sequences (`\x1b[<` and `\x1b[M`).
   - On mobile web (`_isMobile`), preserve onData for virtual soft keyboard and sticky Ctrl.

5. **Eliminate Redundant Key Handlers and Churn**:
   - Remove `attachCustomKeyEventHandler` from `_term`.
   - Remove `_containerKeyDownSubscription` from container event binding and unbinding.
   - Remove `_focusTerminal()` from `_sendInput` to eliminate unnecessary DOM focus calls on every keystroke.

6. **Validate & Deploy**:
   - Run `flutter analyze` and `flutter test` across all 454 tests.
   - Run `cargo fmt` and `cargo clippy --all-targets --all-features -- -D warnings`.
   - Compile release binary with embedded Flutter web client, re-sign for macOS ARM64, and reload `triaged` via zero-downtime process handover protocol.
