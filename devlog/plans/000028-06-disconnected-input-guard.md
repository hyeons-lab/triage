## Thinking
- 2026-05-24T09:47-0700 A connected daemon session can later lose its WebSocket transport while retaining `attached` UI state. The existing input listener treated any disconnected client as offline mock mode, so typed keys mutated fallback rows and backspace edited local text instead of shell state.
- 2026-05-24T09:47-0700 Remote daemon sessions need a separate disconnected path: mark them visibly disconnected and suppress local echo until the client reconnects, while preserving offline mock editing for mock sessions.

## Plan
- 2026-05-24T09:47-0700 Add remote-session disconnected state handling for socket close, socket error, and failed input sends.
- 2026-05-24T09:47-0700 Prevent attached/disconnected daemon sessions from falling through to local mock text editing.
- 2026-05-24T09:47-0700 Add widget coverage for input after disconnect so typed text and backspace cannot mutate daemon terminal fallback rows.
- 2026-05-24T09:47-0700 Track daemon-backed sessions with explicit remote identity rather than mutable status text, add stalled WebSocket request timeouts, and route web key events when xterm loses DOM focus but Flutter still owns terminal focus.
- 2026-05-24T09:47-0700 Add automatic reconnect scheduling while the Flutter UI is mounted, including retry after failed connect attempts and explicit `connection_closed` notifications from the WebSocket client.
