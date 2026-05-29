## Thinking

The daemon accepts input and can start both `cmd.exe` and `bash` through the WebSocket API. The TUI uses `cmd.exe` as the Windows default shell, but Flutter creates new remote sessions by trying `bash` first. On this Windows host, `bash` exists, so the fallback to `cmd.exe` never runs and the user does not get the native prompt expected from the local client.

## Plan

1. Change Flutter's new-session creation order to try the native Windows prompt before `bash`.
2. Extend the widget fake to record requested commands and assert the first created session uses `cmd.exe`.
3. Run the focused Flutter test, rebuild the web assets, reinstall `triaged`, and restart it so the running daemon serves the fixed client.
4. Move shell selection into the plus button menu so users choose `cmd.exe` or `bash` as part of creating a daemon session.
5. Refresh the daemon snapshot after session creation so startup output captured before the terminal attach is replayed into the web terminal.
