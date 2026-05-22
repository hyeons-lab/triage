# Fix Input lock on closed stream

## Thinking

When the daemon-backed WebSocket connection is closed, encounters an error, or the subscription is closed, the client state in `_TerminalSpikePageState` (`_client`, `_sessionId`, `_subscriptionId`) is not reset to `null`.
Because these fields remain non-null, `_sendInput` continues to attempt to send keyboard input to the dead WebSocket client instead of falling back to local echo or displaying local input. As a result, the user feels like they cannot type anything at all.
We need to:
- Clear the connection state (`_client`, `_sessionId`, `_subscriptionId`) upon `onDone`, `onError`, `subscription_closed`, and `error` messages.
- Print clear diagnostic error messages directly to the terminal pane when these disconnect events occur.
- Re-run Flutter tests to ensure everything remains green.

## Plan

1. Modify `lib/main.dart` in `flutter/argus_client`:
   - In `_connectWebSocket`, update the `onError` and `onDone` callbacks to reset `_client`, `_sessionId`, and `_subscriptionId` to `null` and write a descriptive error message to the terminal pane (`_terminal.write`).
   - In `_handleWebSocketMessage`, update `subscription_closed` and `error` cases to reset `_client`, `_sessionId`, and `_subscriptionId` to `null`, and write corresponding error messages to the terminal pane.
2. Verify changes by formatting and running the unit tests using `flutter test`.
