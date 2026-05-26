# Plan - Fix Terminal Input Routing on Focus Mismatch

## Thinking
When the remote client terminal container or platform view outer boundary receives focus, `activeElementInTerminal` evaluates to `true`, but the browser's active element is the outer `div` (`_container` or `<flt-platform-view>`) rather than xterm.js's native internal `<textarea>`.
In this state:
1. `isTypingInInput` evaluates to `false` because the active element's tag name is `'div'`.
2. `shouldHandleTerminalKey` evaluates to `true`.
3. The window keyboard event listener ignores manual routing because `activeElementInTerminal` is `true`, bypasses the `else if (!activeElementInTerminal)` block, and calls `event.preventDefault()` or `event.stopPropagation()` is not hit.
4. Because the actual focused element is a `'div'` and not xterm's internal `<textarea>`, the browser does not deliver the keyboard event to xterm.js natively.
5. Consequently, xterm's native `onData` handler never triggers, causing keyboard inputs to be completely dropped and lost.

To resolve this issue, we will make keydown capturing permissive and robust: if the user is not actively typing in an external text input/textarea elsewhere, the window listener should always manually translate and route keyboard events directly to the active controller.

## Plan
1. Modify the window `keydown` listener inside `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to change `else if (!activeElementInTerminal)` to a permissive `else` block. This guarantees manual routing whenever `shouldHandleTerminalKey` is `true`.
2. Verify that keyboard inputs work immediately in all sessions when focused or clicked.
3. Validate that standard unit and integration tests continue to pass cleanly.
