# Plan: Fix Hardware Shift+Tab Key Handling on Desktop and Web

## Thinking

Users on computers and laptops (desktop and web) could not enter Shift+Tab to trigger CLI mode toggles (such as Auto-accept or Plan mode toggles in CLIs like Claude Code), whereas on mobile devices it functioned properly via the on-screen accessory bar key (`⇧tab` sending `\x1b[Z`).

Investigation revealed two root causes across the client platforms:

1. **Native Desktop (`terminal_pane_stub.dart`)**:
   - The key event listener `_handleTerminalKeyEvent` only checked for clipboard copy and paste chords (`keyC` and `_isPasteChord`).
   - For `LogicalKeyboardKey.tab`, it returned `KeyEventResult.ignored`.
   - When Tab or Shift+Tab returned `ignored`, Flutter's default focus traversal policy (`NextFocusIntent` / `PreviousFocusIntent`) intercepted the event at the `WidgetsApp` / `FocusManager` level. Instead of delivering `\x1b[Z` or `\t` to the active PTY, focus was navigated away from the terminal to adjacent focusable widgets (e.g. workspace buttons or sidebar rails).
   - In widget test environments (`runningUnderFlutterTest()`), the fallback widget tree lacked a `Focus` node with `_handleTerminalKeyEvent`, preventing automated testing of terminal key events.

2. **Web Browser Client (`terminal_pane_web.dart`)**:
   - There were multiple overlapping listeners intercepting Tab: `_windowKeyDownListener` on `window`, `attachCustomKeyEventHandler` on xterm.js, and `Focus.onKeyEvent` on the Flutter Focus widget.
   - `_windowKeyDownListener` called `event.stopPropagation()`. In JavaScript DOM event dispatching, `stopPropagation()` halts tree traversal down the DOM hierarchy, but does not stop sibling event listeners attached to the same target (`window`). Flutter Web registers its keyboard engine listener directly on `window`.
   - As a result, when Shift+Tab was pressed, `_windowKeyDownListener` called `_sendInput('\x1b[Z')`, and then Flutter Web's ambient listener received the keydown event and dispatched it to `Focus.onKeyEvent`, which called `_sendInput('\x1b[Z')` a second time.
   - Dispatching duplicate `\x1b[Z\x1b[Z` sequences in rapid succession (< 1ms apart) to interactive CLIs caused mode toggles to immediately flip on and back off, making Shift+Tab appear completely unresponsive.

To resolve these issues:
- In `terminal_pane_stub.dart`:
  - Update `_handleTerminalKeyEvent` to intercept `LogicalKeyboardKey.tab`.
  - For `KeyDownEvent` and `KeyRepeatEvent`, determine if Shift is held (`HardwareKeyboard.instance.isShiftPressed`). Dispatch `\x1b[Z` on Shift+Tab and `\t` on plain Tab via `widget.controller.sendInput(...)`.
  - Return `KeyEventResult.handled` for all `LogicalKeyboardKey.tab` events (including `KeyUpEvent`) so Flutter's focus traversal never steals focus from the terminal.
  - In `runningUnderFlutterTest()`, wrap the fallback widget hierarchy with `Focus(focusNode: _focusNode, autofocus: true, onKeyEvent: _handleTerminalKeyEvent)` so widget tests can reliably assert keyboard handling and focus retention.
- In `terminal_pane_web.dart`:
  - Add `stopImmediatePropagation()` in `_windowKeyDownListener` and `attachCustomKeyEventHandler`.
  - Introduce `_shouldDispatchTab()` with a short threshold (40ms) to deduplicate key events between `_windowKeyDownListener`, `attachCustomKeyEventHandler`, and `Focus.onKeyEvent`. This ensures that a single physical Tab or Shift+Tab keydown dispatches `\x1b[Z` or `\t` exactly once.
- In `terminal_hardware_key_test.dart`:
  - Add comprehensive widget tests verifying Shift+Tab, plain Tab, key repeat, and focus preservation across macOS, Linux, and Windows target platforms.

## Plan

1. Update `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
   - Intercept `LogicalKeyboardKey.tab` in `_handleTerminalKeyEvent` for `KeyDownEvent` and `KeyRepeatEvent`.
   - Dispatch `\x1b[Z` when Shift is held and `\t` otherwise.
   - Return `KeyEventResult.handled` on all Tab events.
   - Wrap test fallback tree with `Focus`.
2. Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Add `_shouldDispatchTab()` deduplication helper.
   - Call `stopImmediatePropagation()` and guard dispatch with `_shouldDispatchTab()` in `_windowKeyDownListener`.
   - Guard dispatch with `_shouldDispatchTab()` in `attachCustomKeyEventHandler` and `Focus.onKeyEvent`.
3. Add `flutter/triage_client/test/terminal_hardware_key_test.dart`:
   - Verify Shift+Tab dispatches `\x1b[Z` and Tab dispatches `\t`.
   - Verify key repeat dispatches multiple sequences without losing focus.
   - Verify focus remains on the terminal pane.
4. Validation:
   - Run `flutter test test/terminal_hardware_key_test.dart`.
   - Run `flutter test` across the entire client test suite.
   - Run `flutter analyze`.
   - Run `cargo fmt --all -- --check`, `cargo clippy`, and `cargo test --workspace`.
5. Maintain devlog `devlog/000149-fix-hardware-shift-tab.md`.

### Addendum: Renumbering and Rebase
Rebase onto `origin/main` following the merge of PR #171 (which claimed sequence number `000149`). Renumber devlog and plan to sequence `000150` to preserve monotonic ordering.
