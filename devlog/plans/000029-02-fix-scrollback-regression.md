# Plan - Fix Scrollback History Regression and Terminal Replay

## Thinking
During active terminal sessions, the web client silently appends incoming PTY output chunks to the backup logs `session.rows`. However, when `_applySnapshotToSession` is called on WebSocket `Snapshot` events (which occur during daemon resizes), the scrollback history is completely wiped out and replaced by a viewport-only slice because `includeHistory` defaults to `false`.
Furthermore, `_writeInitialContent()` inside `terminal_pane_web.dart` was optimized in commit `c2cd55f` to write only the active viewport slice. While this correctly positions the cursor on the prompt row relative to the viewport, it leaves `xterm.js` with a completely empty scrollback buffer, rendering the scrollback history inaccessible to the user.
To resolve this:
1. Pass `includeHistory: true` inside `_onWebSocketEvent`'s `Snapshot` event handler to prevent resizes from wiping out the scrollback history backup.
2. In `_writeInitialContent()`, write the historical rows (from index `0` to `cursor.startRow - 1`) first to fill the `xterm.js` scrollback buffer, followed by the active viewport rows (from `cursor.startRow` to `cursor.endRow - 1`), before applying the cursor movement ANSI escape sequence.

## Plan
1. Update `_onWebSocketEvent` in `flutter/triage_client/lib/main.dart` to pass `includeHistory: true` when applying snapshot updates from `Snapshot` events.
2. Update `_writeInitialContent` in `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to replay all historical lines up to `cursor.startRow` before replaying the active viewport slice.
3. Validate the changes with `flutter test` and integration tests.
