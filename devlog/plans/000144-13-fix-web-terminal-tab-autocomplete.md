# Plan: Fix Web Terminal Tab Autocomplete

## Thinking

In the web client terminal shell, Tab does not autocomplete in interactive shells (e.g. zsh, bash, fish). Investigation across the keyboard input pipeline revealed multiple seams where Tab events are either swallowed or dropped:

1. In `_windowKeyDownListener` (`terminal_pane_web.dart`), special key handling for Enter was previously made unconditional before `_isActiveElementInTerminal()`, but Tab was not. When Tab is pressed, browser default tab navigation (advancing focus to address bar or browser chrome) or Flutter Web engine key routing preempts xterm.js before the keystroke reaches the PTY.
2. In `Focus.onKeyEvent` (`terminal_pane_web.dart`), when `event.logicalKey == LogicalKeyboardKey.tab`, the handler returned `KeyEventResult.handled` to suppress Flutter widget traversal, but never forwarded `\t` (or `\x1b[Z` for Shift+Tab) to `_sendInput`. Any Tab event captured by Flutter's focus tree was silently discarded.
3. In `attachCustomKeyEventHandler` on `_term` (`terminal_pane_web.dart`), the check matched only `key == 'Tab'`, omitting `code == 'Tab'` and `keyCode == 9`.
4. In `_keyboardEventToInput` (`terminal_pane_web.dart`), fallback mappings for `code == 'Tab'` and `keyCode == 9` were absent.
5. In `TerminalSessionInputRouter` (`terminal_pane.dart`) and `TerminalPane.rebindSessionController` (`terminal_pane_web.dart`), swapping a session rebound persistent write listeners and view listeners, but omitted updating the input router route to point to the new controller.

To ensure Tab reliably autocompletes across desktop and mobile browsers:
- In `_windowKeyDownListener`, intercept Tab unconditionally when targeting the terminal: call `preventDefault()` and `stopPropagation()`, notify interaction, dispatch `_sendInput(event.shiftKey ? '\x1b[Z' : '\t')`, activate terminal, and return early.
- In `Focus.onKeyEvent`, when `event.logicalKey == LogicalKeyboardKey.tab` and `event is KeyDownEvent`, dispatch `_sendInput(HardwareKeyboard.instance.isShiftPressed ? '\x1b[Z' : '\t')`, notify interaction, and activate terminal before returning `KeyEventResult.handled`.
- In `attachCustomKeyEventHandler`, match `key == 'Tab' || code == 'Tab' || keyCode == 9`.
- In `_keyboardEventToInput`, match `event.code == 'Tab' || event.keyCode == 9`.
- In `TerminalSessionInputRouter`, provide `rebind(sessionId, controller)` and invoke it in `TerminalPane.rebindSessionController`.
- In `GestureDetector.onTapDown`, ensure `_focusNode.canRequestFocus` requests focus.

## Plan

1. Update `flutter/triage_client/lib/widgets/terminal_pane.dart`:
   - Add `rebind(String sessionId, TerminalController controller)` to `TerminalSessionInputRouter`.
2. Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Add unconditional Tab interception in `_windowKeyDownListener`.
   - Dispatch `\t` / `\x1b[Z` in `Focus.onKeyEvent`.
   - Expand Tab detection in `attachCustomKeyEventHandler` and `_keyboardEventToInput`.
   - Rebind `_sessionInputRouter` in `TerminalPane.rebindSessionController`.
   - Request focus on `_focusNode` in `GestureDetector.onTapDown`.
3. Update `flutter/triage_client/test/terminal_session_input_router_test.dart`:
   - Add test verifying `TerminalSessionInputRouter.rebind`.
4. Validate:
   - `flutter test`
   - `flutter analyze`
   - `cargo test --workspace`
5. Update devlog `devlog/000144-fix-web-terminal-focus-lifecycle.md`.
