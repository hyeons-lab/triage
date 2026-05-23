# experiment/flutter-spike

## Agent

- Codex, 2026-05-22T19:28-0700
- Antigravity, 2026-05-23T06:45-0700
- Antigravity, 2026-05-23T07:48-0700
- Antigravity, 2026-05-23T07:51-0700
- Antigravity, 2026-05-23T07:56-0700
- Antigravity, 2026-05-23T08:30-0700

## Intent

- Explore the first Flutter client spike for Argus.
- Keep the spike focused on proving client structure and integration boundaries before committing to a production remote-client implementation.

## Decisions

- Use an `experiment/` branch prefix because this branch is exploratory.
- Install Flutter SDK outside the repository and keep the repo change limited to the client scaffold.
- Start with a generated Flutter web scaffold before adding Argus-specific terminal or WebSocket behavior.
- Run the web spike with local Flutter web resources because this environment cannot reliably fetch CanvasKit and fonts from `gstatic`.
- Use the cross-platform `web_socket_channel` package to ensure WebSocket compatibility across Web, Desktop, and Mobile.
- Implement an automatic local mock fallback in the UI when the local daemon is unreachable so the application remains reviewable and interactive offline.
- Implement a lightweight async WebSocket server using tokio and tokio-tungstenite, isolating the async runtime to the ws module. This scales without the limitations of a thread-per-connection model.
- Use a split read/write loop with tokio's unbounded channel to ensure cancellation safety during concurrent read/write and tick select operations.
- Set the event-polling interval to 10ms to achieve low-latency terminal rendering, minimizing perceived typing delay.
- Transition the WebSocket runtime to a single-threaded current_thread executor to improve resource efficiency.
- Implement a graceful drain/flush sequence for connection cleanup by dropping the channel sender and awaiting the write task instead of calling abort.
- Resolve Windows logging and configuration folder initialization failures by adding a USERPROFILE environment variable fallback for HOME-based directory paths.

## What Changed

- Added the initial Flutter web app scaffold at `flutter/argus_client/`.
- Added Flutter SDK `bin` to the user PATH for future shells.
- Restarted the Flutter web server with `--no-web-resources-cdn`.
- Replaced the generated counter demo with an Argus session shell and updated the widget test.
- Added local interactions for session selection, scratch-session creation, and command submission.
- Added `web_socket_channel` dependency to the Dart project.
- Implemented `ArgusWebSocketClient` to handle WebSocket handshake, session listing, session attachment, event subscription, and command execution.
- Integrated the WebSocket client into the main application UI, supporting active session listings, input forwarding, connection state tracking, and output event streams.
- Re-architected widget tests to mock out the WebSocket channel and verify message payloads/state flows.
- Created Dart models (`TerminalColor`, `TerminalStyle`, `StyledSpan`, `StyledRow`) in `lib/models/terminal_models.dart` to match the structured Rust daemon session models.
- Refactored `SessionVm` and `_loadDaemonSessions` to store and deserialize `List<StyledRow>` collections.
- Refactored `TerminalPane` to map each `StyledRow` to a `SelectableText.rich` widget with styled `TextSpan` children (applying foreground, background, bold, italic, and underline styling).
- Added module-level compiler and Clippy ignore directives on Windows in `crates/argus-daemon/src/session.rs` and `crates/argus-mcp/src/main.rs` to allow clean workspace compilation, type checking, linting, and testing on Windows hosts.
- Saved `xterm.js`, `xterm.css`, and `xterm-addon-fit.js` locally in `web/` to follow the offline `--no-web-resources-cdn` policy.
- Designed platform-branched `TerminalPane` using conditional exports (`terminal_pane_stub.dart` and `terminal_pane_web.dart`) to keep widget tests running on native headless VMs.
- Implemented `TerminalPaneWeb` using `dart:js_util` to instantiate `Terminal` (5.5.0) and `FitAddon` (0.10.0), mapping structured styled rows to ANSI sequences and handling viewport resizes via `LayoutBuilder`.
- Updated `analysis_options.yaml` to exclude web-only imports in `terminal_pane_web.dart` from the cross-platform static analyzer.
- Added tokio, tokio-tungstenite, and futures-util dependencies to the Cargo workspace.
- Implemented a blanket SessionApi trait implementation for Arc<T> in argus-core.
- Implemented the WebSocket server in crates/argus-daemon/src/ws.rs with split loops and a 10ms polling interval.
- Exposed the ws module in crates/argus-daemon/src/lib.rs.
- Updated crates/argus-daemon/src/main.rs to load the user's config and spawn the WebSocket server concurrently on startup.
- Refactored crates/argus-daemon/src/ws.rs to use tokio::runtime::Builder::new_current_thread.
- Replaced write_task.abort() with channel drop and task join to flush outgoing events during shutdown.
- Set missed tick behavior for the 10ms interval to Skip.
- Added fallback check for USERPROFILE environment variable in default path and config resolution within crates/argus-core/src/logging.rs and crates/argus-core/src/config.rs.

## Progress

- 2026-05-22T19:28-0700 - Created the `experiment/flutter-spike` worktree from `origin/main` and unset the upstream per repository convention.
- 2026-05-22T19:50-0700 - Installed Flutter stable, generated the web scaffold, and started the app with the web-server target at `http://127.0.0.1:8080`.
- 2026-05-22T22:30-0700 - Restarted the Flutter web server with `--no-web-resources-cdn` after the browser failed to fetch CanvasKit and Roboto from `gstatic`.
- 2026-05-22T22:36-0700 - Replaced the generated Flutter demo with a static Argus shell showing a session rail, selected session header, terminal pane placeholder, and command bar. Validated with `flutter analyze` and `flutter test`, then restarted the local web server.
- 2026-05-22T22:40-0700 - Made the shell interactive locally: session rows can be selected, the add button creates a scratch session, and submitted input appends to the selected terminal pane. Added widget coverage for those interactions and restarted the local web server.
- 2026-05-23T06:45-0700 - Added the cross-platform WebSocket adapter client service and integrated it into the UI shell, adding mock-based test coverage for all behaviors.
- 2026-05-23T06:57-0700 - Defined TerminalPane rendering bridge by implementing matching structured Dart models for styled rows and spans, refactoring UI components to render styled rich text, and updating widget tests to match.
- 2026-05-23T07:26-0700 - Integrated xterm.js in Flutter Web client with dynamic fitting, structured ANSI mapping, and platform-branched native testing stubs.
- 2026-05-23T07:36-0700 - Resolved xterm.js layout fitting latency and wired interactive keyboard keypress input loops from the emulator back to the transport host.
- 2026-05-23T07:48-0700 - Wrote the async WebSocket server implementation, resolved formatting and compiler warnings, and verified with cargo check/clippy/test.
- 2026-05-23T07:51-0700 - Refactored the WebSocket server to use a single-threaded runtime, skip missed tick intervals, and await writer tasks on disconnect. Verified with full checks.
- 2026-05-23T07:56-0700 - Fixed Windows configuration paths with USERPROFILE fallback, verified daemon port binding, and ran clean client tests.
- 2026-05-23T08:30-0700 - Standardized Windows USERPROFILE fallback for sessions and TUI log directories, and committed the changes.

## Issues

- `flutter doctor` reports Chrome is not installed or discoverable, but Edge is available as a web device.
- Android command-line tools and license acceptance are incomplete; this does not block the current web spike.
- Default Flutter web runs can fetch CanvasKit from `www.gstatic.com`; use `--no-web-resources-cdn` in this environment.

## Commits

- 990697e — feat(client): implement websocket client and integrate xterm.js
- f42f3c5 — fix(client): address xterm.js layout fitting latency and wire keyboard input loop
- 4d1f6a5 — feat(daemon): implement async websocket server for remote clients
- f2c99b9 — refactor(daemon): optimize websocket server runtime and connection shutdown
- b36aea3 — fix(daemon): fallback to USERPROFILE env var on Windows for config/logging paths
- HEAD — fix(daemon): use USERPROFILE fallback path for sessions and tui log dirs

## Next Steps

- Design user pairing authentication flows for remote clients.
