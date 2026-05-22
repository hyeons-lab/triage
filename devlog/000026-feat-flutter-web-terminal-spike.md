# feat/flutter-web-terminal-spike

## Agent

- Codex, 2026-05-21T23:32-0700

## Intent

- Prove the first Flutter Web terminal rendering path for Argus before building the broader remote client.
- Keep the spike focused on the browser terminal widget boundary: mounting xterm.js, writing terminal bytes, receiving keyboard input, and reacting to resize.

## Decisions

- Start with a web-only Flutter scaffold because this spike gates the remote web path.
- Use xterm.js through a small JavaScript bridge so Dart owns the Flutter widget boundary while xterm.js owns terminal DOM behavior.
- Feed deterministic terminal output locally first; daemon WebSocket attachment stays out of this branch unless the widget boundary is proven.

## What Changed

- Added a minimal `flutter/argus_client` web-only scaffold.
- Added `TerminalPane`, a Flutter `HtmlElementView` wrapper around an xterm.js JavaScript bridge.
- Added deterministic terminal output and local input echo so the xterm mount, write path, input callback, focus, and resize fit behavior can be exercised before daemon WebSocket hosting exists.
- Added web bootstrap files that load xterm.js and `@xterm/addon-fit`.
- Added a small pure Dart test for terminal input display labels.
- Delayed xterm bridge attachment until the `HtmlElementView` host div exists in the browser DOM.
- Hardened the xterm bridge DOM sizing and global lookup so the pane shows a visible startup fallback instead of failing as a silent blank.
- Added a Flutter-rendered terminal transcript fallback and made the initial demo output plain, multiline, and diagnostic.
- Added bridge status reporting so the Flutter layer only covers the xterm pane while the JavaScript bridge has not reported an opened terminal.
- Queued writes until xterm is attached so startup transcript bytes are not dropped between Flutter widget attachment and JavaScript bridge readiness.
- Added a minimal Flutter WebSocket client boundary that can send the Argus transport `hello` request and display received server messages in the terminal pane.
- Added a blocking `tungstenite` WebSocket listener for the existing Argus session protocol and wired it into `argus-daemon` behind `ARGUS_WS_LISTEN`.
- Defaulted the Flutter WebSocket URL to the current page host on port 8081 so WSL browser sessions use the WSL address instead of Windows localhost.
- Extended the Flutter WebSocket client from `hello` to start `/bin/sh -lc cat`, attach as an interactive controller, subscribe to session events, render output event bytes in xterm, and send typed input back to the daemon PTY.
- Added a TUI prefix session-switching model for terminals, especially macOS terminals, that intercept Option-arrow shortcuts before Argus can receive them.
- Added Flutter/Dart ignores for the scaffold.
- Reset connection and client fields to null and print a descriptive error on the terminal pane when the WebSocket connection is closed or errors, or when the session event subscription is closed.

## Progress

- 2026-05-21T23:32-0700 — Created `feat/flutter-web-terminal-spike` worktree from `origin/main`, unset upstream, and started Phase 6 Spike A.
- 2026-05-21T23:37-0700 — Added the minimal Flutter Web terminal spike scaffold. Static validation passed with `git diff --check`, `node --check flutter/argus_client/web/terminal_bridge.js`, and `cargo fmt --all -- --check`.
- 2026-05-21T23:42-0700 — Installed Flutter 3.44.0 at `/home/dberrios/development/flutter`, exposed `flutter` and `dart` through `/home/dberrios/.local/bin`, and validated the scaffold with `flutter pub get`, `flutter analyze`, `flutter test`, and `flutter build web`.
- 2026-05-21T23:53-0700 — Fixed the browser attach timing race reported by Flutter Web: the terminal pane now waits until the generated host element is present before calling `argusTerminalBridge.create`. Revalidated with `flutter analyze` and `flutter test`, then restarted the web server on port 8080.
- 2026-05-21T23:57-0700 — Hardened the terminal host and xterm bridge after the terminal pane rendered blank in the browser. The bridge now forces host sizing, accepts both direct and namespaced xterm globals, leaves a visible startup fallback, and retries fit after attach. Revalidated with `node --check flutter/argus_client/web/terminal_bridge.js`, `flutter analyze`, and `flutter test`, then restarted the web server on port 8080.
- 2026-05-22T00:06-0700 — Added a native Flutter transcript fallback after the browser showed only the prompt text. The initial output now names the spike, Flutter shell state, xterm bridge attempt, and input echo state in plain text. Revalidated with `flutter analyze` and `flutter test`, then hot-restarted the web server.
- 2026-05-22T00:15-0700 — Instrumented the xterm bridge with status callbacks and removed the opaque fallback overlay once xterm reports `opened`. Revalidated with `flutter analyze`, `flutter test`, `node --check flutter/argus_client/web/terminal_bridge.js`, and `flutter build web`, then hot-restarted the server.
- 2026-05-22T00:16-0700 — Fixed dropped startup writes when the Flutter widget exists but xterm is not attached yet. Revalidated with `flutter analyze`, `flutter test`, and `flutter build web`, then hot-restarted the server.
- 2026-05-22T00:24-0700 — Added `ArgusWsClient`, a sidebar URL/connect control, and a protocol test for the WebSocket `hello` request. Revalidated with `flutter pub get`, `flutter analyze`, `flutter test`, `node --check flutter/argus_client/web/terminal_bridge.js`, and `flutter build web`, then hot-restarted the server.
- 2026-05-22T00:32-0700 — Hosted the WebSocket protocol from `argus-daemon` when `ARGUS_WS_LISTEN` is set and smoke-tested `hello` against `ws://127.0.0.1:8081`. The Flutter default WebSocket URL now derives from `Uri.base.host` and points to port 8081. Revalidated with `cargo test -p argus-transport-ws`, `cargo test -p argus-daemon`, `cargo fmt --all -- --check`, `cargo clippy -p argus-daemon -p argus-transport-ws --all-targets -- -D warnings`, `flutter analyze`, `flutter test`, and `flutter build web`.
- 2026-05-22T00:36-0700 — Added the first end-to-end remote session lifecycle in Flutter: connect now starts a daemon-backed `cat` PTY, attaches as the controller, subscribes to events, renders output bytes, and routes typed input over `write_input`. Revalidated with `flutter analyze`, `flutter test`, `cargo test -p argus-transport-ws`, and `flutter build web`, then hot-restarted the server.
- 2026-05-22T09:06-0700 — Added `Ctrl-G` prefix mode to the TUI. After the prefix, `j` or `n` selects the next session and `k` or `p` selects the previous session, while the existing Option-arrow bindings remain. Added status-line guidance and unit coverage for the prefix keys.
- 2026-05-22T09:18-0700 — Fixed terminal input lock on closed stream: reset `_client`, `_sessionId`, and `_subscriptionId` to null and print error details to the terminal pane when disconnect callbacks (`onDone`, `onError`) or closed messages (`subscription_closed`, `error`) trigger. Validated Rust workspace tests.
- 2026-05-22T09:54-0700 — Suppressed expected Unix socket client disconnect warnings when a broken pipe is wrapped by `serde_json::Error` during response encoding. Added regression coverage for the observed `writing response -> encoding JSON line -> Broken pipe` shape and revalidated the closed-socket IPC tests.

## Research & Discoveries

- 2026-05-21T23:32-0700 — Flutter and Dart are not installed in this environment, so scaffold and static review are possible here but Flutter build/test validation needs a machine with Flutter tooling.
- 2026-05-21T23:37-0700 — `flutter analyze` could not run because `flutter` is not on `PATH`.
- 2026-05-21T23:42-0700 — The user requested Flutter installation, so the SDK was installed locally under `/home/dberrios/development/flutter`. Shell startup files were not modified; `/home/dberrios/.local/bin/flutter` and `/home/dberrios/.local/bin/dart` are symlinks into the SDK.
- 2026-05-21T23:42-0700 — `flutter doctor` reports Flutter itself is healthy, but Chrome, Android command-line tools, and Linux GTK development libraries are not installed. Web production builds work; interactive Chrome runs need `CHROME_EXECUTABLE` or a Linux Chrome install.

## Commits

- 899d67f — feat: add flutter web terminal spike
- 0372788 — fix: reset client state and output error when websocket or stream closes
- HEAD — fix: suppress JSON broken pipe IPC warning

## Next Steps

- Wire the terminal pane to the daemon WebSocket transport after the widget boundary is validated.
- Run the web spike in Chrome and verify keyboard focus, resize fitting, and xterm rendering interactively.
- Install or point Flutter at Chrome before using `flutter run -d chrome` in WSL.
- Replace the demo `cat` process with a real shell attach flow and render snapshots/styled rows on attach.
- Keep closed IPC writes quiet when browser or TUI clients disconnect mid-response; only unexpected socket handler errors should warn.
