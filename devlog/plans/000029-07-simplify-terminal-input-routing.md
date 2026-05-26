# Plan - Simplify Terminal Input Routing and Always Route Keydowns

## Thinking
When the user focuses the terminal pane by clicking inside it, xterm.js's native `<textarea>` helper receives focus.
In this state:
1. `isTypingInInput` evaluated to `true` (since the active element was a `'textarea'`).
2. `shouldHandleTerminalKey` evaluated to `false`.
3. Consequently, the window `keydown` listener returned early and did not manually route the keyboard event.
4. However, in this container environment (such as under certain Flutter Web canvaskit and Shadow DOM bounds), the native keydown event delivered to xterm's `<textarea>` was blocked, intercepted, or otherwise not captured by xterm's internal parser.
5. As a result, both the native `onData` route and the manual window-level route bypassed the keyboard event, leading to completely blocked input when clicking inside the terminal.

Since there are absolutely no other standard text inputs or textareas in the entire application when `TerminalPane` is active (the only other `TextField` resides in `_PairingView`, which is only rendered when `_needsPairing == true` and `TerminalPane` is fully unmounted/unrendered), we can safely simplify keydown capturing: the window listener should always manually translate and route keyboard events directly to the active session when the terminal pane is active, completely eliminating any focus-fighting or native input bypass blocks.

## Plan
1. Simplify `_windowKeyDownListener` inside `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to route keydown events manually and unconditionally whenever the terminal pane is active (`!widget.isExited`), completely eliminating the complex and fragile active element and Shadow DOM tag name checks.
2. Verify that keyboard inputs work immediately and flawlessly inside the active terminal.
3. Validate that standard unit and integration tests continue to pass cleanly.
