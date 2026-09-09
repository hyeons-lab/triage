# Plan: Fix Web Terminal Enter and Control Key Interception

## Thinking

In the Flutter web client, sessions running interactive CLI tools such as Codex (`session-218` / `stuck-codex`) receive normal alphanumeric characters (`sdfasdfasdf`), but pressing Enter (`\r` / `[13]`) fails to submit prompts. Direct PTY socket inspection confirmed that `session-218` is alive and instantly advances when `\r` is transmitted via `WriteInput`. The root cause is a dual gap in web keyboard event propagation:

1. In `_windowKeyDownListener` (`terminal_pane_web.dart`), when `_isActiveElementInTerminal()` is true, the handler returns early without calling `event.preventDefault()` or `event.stopPropagation()`. When the user presses Enter, Flutter's web engine and browser form handlers can intercept the event, swallowing or preempting it before xterm.js can handle it.
2. In `attachCustomKeyEventHandler` on `_term`, Enter was previously unhandled, returning `true` to let xterm.js process it natively. However, in Flutter Web's multi-layered DOM and Shadow DOM hierarchy, xterm.js's native `_keyDown` method does not reliably deliver carriage returns to `onData` across all browser focus states.
3. In `_keyboardEventToInput()`, `Enter` was checked only against `event.key == 'Enter'`, omitting numpad enter (`event.code == 'NumpadEnter'`) and raw keycodes (`keyCode == 13`).

To make Enter and control keys bulletproof across desktop and mobile browsers:
- In `_windowKeyDownListener`, intercept `Enter` (including numpad enter and keyCode 13) before the `_isActiveElementInTerminal()` early exit, preventing default and stopping propagation immediately so Flutter Web's engine never swallows the key.
- In `attachCustomKeyEventHandler`, explicitly capture `Enter` and `Escape`, preventing default and stopping propagation, and dispatching `\r` (or `\x1b\r` if Alt is held) and `\x1b` (or `\x1b\x1b` if Alt is held) directly to `_sessionInputRouter.sendInput()`.
- Update `_keyboardEventToInput()` to match numpad enter and raw keyCode 13.
- Verify through test suites, compile release web bundle, and perform zero-downtime daemon handover.

## Plan

1. Edit `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Add explicit `Enter` handling in `_windowKeyDownListener` before `_isActiveElementInTerminal()`.
   - Add explicit `Enter` and `Escape` handling in `attachCustomKeyEventHandler`.
   - Add numpad enter and keyCode 13 fallback in `_keyboardEventToInput()`.
2. Run test suites:
   - `flutter test`
   - `flutter analyze`
   - `cargo test --workspace`
3. Build release web bundle and daemon:
   - `cargo build --release -p triaged`
   - Ad-hoc codesign on ARM64 macOS: `codesign -s - -f ~/.cargo/bin/triaged`
   - Zero-downtime handover reload: `~/.cargo/bin/triaged reload`
4. Update devlog `devlog/000144-fix-web-terminal-focus-lifecycle.md`.
5. Commit and push changes.
