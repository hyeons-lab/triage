# Plan - Fix Input Lease and Suppression Issues

## Thinking
When the user switches sessions, keyboard input in the selected remote session is sometimes blocked. There are two distinct root causes:
1. **Interactive Input Lease Loss**: In the daemon, only one client can hold the `InteractiveController` lease for a session at a time. If the client disconnects, reconnects, or another client/test grabs the lease, the user's remote client loses the input lease. When the user switches back to that session, the client only fetches the snapshot using `snapshotSession`, which does not re-acquire the input lease. As a result, subsequent inputs from the client are silently rejected by the daemon.
2. **Stuck Suppression Flag**: The `_sessionSuppressData` static map tracks input suppression per session. Because of async widget rebuild cycles, unmounting, and tab switching, checking `mounted` in safety timers can cause race conditions where the suppression flag is left stuck on `true` permanently.

To solve these issues:
1. Modify `_refreshSessionSnapshot` in `flutter/triage_client/lib/main.dart` to use `attachSession` instead of `snapshotSession` to refresh the session snapshot. This guarantees that whenever a session is selected or refreshed, the client automatically re-acquire the `InteractiveController` lease, ensuring inputs are never blocked.
2. Replace the static `_sessionSuppressData` map in `flutter/triage_client/lib/widgets/terminal_pane_web.dart` with a clean instance variable `bool _suppressInput = false;` bound to the `_TerminalPaneState` lifecycle, completely eliminating any static cross-state race conditions.

## Plan
1. Modify `_refreshSessionSnapshot` in `flutter/triage_client/lib/main.dart` to call `_client.attachSession` instead of `_client.snapshotSession`.
2. Modify `_TerminalPaneState` in `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to replace `_sessionSuppressData` static map with an instance variable `bool _suppressInput = false`.
3. Run `flutter test` and `npm run test:xterm` to verify that all unit, widget, and Playwright integration tests pass.
4. Update devlog `devlog/000029-fix-terminal-layout.md` and push changes to `fix/terminal-layout`.
