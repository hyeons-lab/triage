# Plan - Real-Browser Playwright Integration Testing

## Thinking
To address the lack of high-fidelity test coverage for the window keyboard routing logic under Flutter Web CanvasKit and Shadow DOM environment, and to bypass the fragile pairing PIN view during automated test runs, we will:
1. Expose the active `Terminal` instance as `window.activeTerm` in the web terminal pane.
2. Introduce a `mock=true` URL query parameter check via cross-platform `Uri.base` inside `initState` of `lib/main.dart` to bypass websocket connection and enter local mock/offline mode automatically during testing.
3. Write a production Node.js static web server (`server.js`) to cleanly serve release builds of the remote client on port 8080.
4. Add a real-browser end-to-end Playwright integration test case in `xterm_replay.spec.js` that loads the unified application, clicks the terminal canvas to acquire focus, types characters, and asserts their successful routing to the active term.

## Plan
1. Expose `window.activeTerm` inside `_initTerminal` in `flutter/triage_client/lib/widgets/terminal_pane_web.dart`.
2. Check `Uri.base.queryParameters['mock'] == 'true'` inside `initState` in `flutter/triage_client/lib/main.dart` to bypass connection attempts.
3. Add a Node.js-based static file server `flutter/triage_client/server.js` to serve compiled release builds from `build/web/` on port 8080.
4. Add the `real web client captures and routes keyboard input inside the Flutter Web application` test case in `flutter/triage_client/test_web/xterm_replay.spec.js`.
5. Compile in release mode with `flutter build web --release`, start the Node static server, and run `npm run test:xterm` to verify that all tests pass.
6. Commit and push all changes to the repository.
