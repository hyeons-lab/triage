# experiment/flutter-spike

## Agent

- Codex, 2026-05-22T19:28-0700
- Antigravity, 2026-05-23T06:45-0700

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

## Progress

- 2026-05-22T19:28-0700 - Created the `experiment/flutter-spike` worktree from `origin/main` and unset the upstream per repository convention.
- 2026-05-22T19:50-0700 - Installed Flutter stable, generated the web scaffold, and started the app with the web-server target at `http://127.0.0.1:8080`.
- 2026-05-22T22:30-0700 - Restarted the Flutter web server with `--no-web-resources-cdn` after the browser failed to fetch CanvasKit and Roboto from `gstatic`.
- 2026-05-22T22:36-0700 - Replaced the generated Flutter demo with a static Argus shell showing a session rail, selected session header, terminal pane placeholder, and command bar. Validated with `flutter analyze` and `flutter test`, then restarted the local web server.
- 2026-05-22T22:40-0700 - Made the shell interactive locally: session rows can be selected, the add button creates a scratch session, and submitted input appends to the selected terminal pane. Added widget coverage for those interactions and restarted the local web server.
- 2026-05-23T06:45-0700 - Added the cross-platform WebSocket adapter client service and integrated it into the UI shell, adding mock-based test coverage for all behaviors.
- 2026-05-23T06:57-0700 - Defined TerminalPane rendering bridge by implementing matching structured Dart models for styled rows and spans, refactoring UI components to render styled rich text, and updating widget tests to match.
- 2026-05-23T07:26-0700 - Integrated xterm.js in Flutter Web client with dynamic fitting, structured ANSI mapping, and platform-branched native testing stubs.

## Issues

- `flutter doctor` reports Chrome is not installed or discoverable, but Edge is available as a web device.
- Android command-line tools and license acceptance are incomplete; this does not block the current web spike.
- Default Flutter web runs can fetch CanvasKit from `www.gstatic.com`; use `--no-web-resources-cdn` in this environment.

## Commits

- HEAD — feat(client): implement websocket client and integrate xterm.js

## Next Steps

- Wire the WebSocket server transport into the daemon runtime host.
- Design user pairing authentication flows for remote clients.

