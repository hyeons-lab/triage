# Plan - Fix Initial Refresh Layout Corruption

## Thinking
During initial bootstrapping of the remote web client, the terminal parent element is subject to rapid reflows. If `_onFit()` runs during these early bootstrap reflows, it calculates a narrow grid size (e.g., 53 columns) and immediately dispatches a `sendResizeOut` PTY resize command to the daemon. The daemon's ConPTY backend hard-wraps the active prompt buffer at 53 columns.
When the viewport later expands to its final stable width and the layout stability timer fires, the initial content is written, but the ConPTY prompt is already permanently hard-wrapped and staircased.
To fix this, we will:
1. Gate the `sendResizeOut` debounce timer in `_onFit()` on `_initialContentWritten` being true.
2. Dispatch an immediate stable PTY resize command (`sendResizeOut`) inside `_onFit()` as soon as `_initialContentWritten` is set to `true` (both in the stability timer callback and the direct fallback block).
3. Gate the `_term.onResize` callback on `_initialContentWritten` inside `_bindTerminalSubscriptions()`.

## Plan
1. Update `_bindTerminalSubscriptions()` in `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to gate `onResizeCallback` execution on `_initialContentWritten`.
2. Update the debounce resize timer inside `_onFit()` to only schedule `sendResizeOut` if `_initialContentWritten` is true.
3. Update `_onFit()` to dispatch the first stable PTY resize command immediately when `_initialContentWritten` is set to true.
4. Run `flutter test` and `npm run test:xterm` to verify.
