## Thinking

We are addressing a terminal issue in the Flutter Web client:
1. When opening a new terminal, intermediate layout phases can temporarily report non-zero but small dimensions (e.g. clientWidth and clientHeight values that resolve to a small grid like 1x1 or 3x3).
2. The current `_onFit()` trigger checks for `width > 0 && height > 0` and prematurely sets `_initialContentWritten = true` to write fallback rows and set the cursor.
3. This creates a misplaced cursor at intermediate layout bounds. Once the terminal sizes up to its final dimensions, the cursor is left displaced (e.g. by 20 rows below the actual prompt).
4. When the user types or presses backspace, they do not see any feedback because the cursor is far below the active prompt.
5. In frustration, the user presses backspace rapidly. Each key press is sent to the backend via `_client.writeInput(...)`.
6. Currently, `writeInput` is implemented as a blocking request-response call `await _send('write_input', ...)` with a 10-second timeout.
7. Rapidly queuing request-response calls causes congestion on the WebSocket queue. If any request takes >10 seconds to return a response from the server, the client throws a timeout exception, which triggers `_markRemoteSessionDisconnected` and disconnects the session.

To resolve these issues, we will:
1. Safe-guard premature initial write execution by only calling `_writeInitialContent()` in `_onFit()` if the fitted grid is at least `fittedRows >= 5` and `fittedCols >= 10`.
2. Convert `writeInput` on `TriageWebSocketClient` to be fire-and-forget (non-blocking). It will send the JSON payload directly over the WebSocket sink without expecting a response or registering completers/timers.
3. Keep the `Future<void>` return type to prevent breaking existing interface signatures and mock tests.

### Subsequent Findings (Trailing Blank Line Scrolling)
1. Even on a fitted terminal with sane dimensions, Wezterm's initial session snapshot of a brand-new shell contains 24 rows, most of which are completely empty/blank spacer lines at the bottom of the screen.
2. Writing all 24 rows separated by `\r\n` to xterm.js on a smaller terminal panel (e.g., a viewport with `fittedRows = 20`) causes the bottom 20 blank lines to scroll the viewport by 4 lines.
3. This scrolls the active welcome/prompt text at the top of the terminal out of the viewport, leaving the screen looking blank/empty.
4. The cursor row calculation then clamps the cursor position to viewport row 1, misaligning it below the actual prompt.
5. To fix this, we will find `lastActiveRow`, which is the maximum of the last non-empty line index and the cursor row index. We will then restrict the initial content writing and coordinate offsets to only `activeRowsCount = lastActiveRow + 1` lines, completely excluding trailing empty lines from being written with `\r\n` and preventing unnecessary scrolling.

## Plan

1. **Modify WebSocket Client**: Update `writeInput` in `flutter/triage_client/lib/services/triage_websocket_client.dart` to directly encode and add the message to `_channel!.sink`, bypassing `_send`.
2. **Modify Web Terminal View**: Update `_onFit` in `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to check `fittedRows >= 5 && fittedCols >= 10` before writing initial content.
3. **Exclude Trailing Blank Lines**: Update `_writeInitialContent` in `terminal_pane_web.dart` to only write up to the last active row, excluding trailing blank lines from the printed grid and coordinate calculations.
4. **Validate**:
   - Run `flutter test` across the client codebase to make sure tests pass.
   - Run the local rust test suite `cargo test --workspace` inside the worktree to ensure no regressions.
5. **Devlog Update**: Add entries to `devlog/000031-feat-zero-downtime-handover.md` detailing the changes.

