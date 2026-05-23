## Thinking

We want to enable full interactive control and terminal window resizing in the Flutter Web client spike.
Currently:
1. Attach mode is set to `'Observer'`, which does not grant the client the input lease. We need to attach in `'InteractiveController'` mode.
2. In `main.dart`, we do not capture or propagate client-side resize events back to the daemon. We need to wire `session.terminalController.addResizeOutListener` to call `_client.resizeSession` to propagate grid size changes.

We will modify:
1. `lib/main.dart`:
   - Change attach mode from `'Observer'` to `'InteractiveController'`.
   - Add the resizeOut listener to `_setupSessionInputListener` to resize sessions dynamically.

## Plan

- Write the new plan to `devlog/plans/000026-03-interactive-resize.md` and update `devlog/000026-experiment-flutter-spike.md`.
- Edit `flutter/argus_client/lib/main.dart`:
  - Update `_loadDaemonSessions()` to pass `'InteractiveController'` instead of `'Observer'` in `attachSession`.
  - Update `_createSession()` to pass `'InteractiveController'` instead of `'Observer'` in `attachSession`.
  - Update `_setupSessionInputListener(SessionVm session)` to bind `session.terminalController.addResizeOutListener` to forward `cols` and `rows` to `_client.resizeSession(sessionId, cols, rows)`.
- Verify compilation and run all tests with `flutter test` and `flutter analyze`.
