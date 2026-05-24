# feat/remote-pairing-auth

## Agent
- Antigravity (Gemini 3.5 Flash) @ triage branch feat/remote-pairing-auth

## Intent
- Secure the remote WebSocket connection with a pairing handshake, bearer tokens, and secure transport architecture.

## What Changed
- 2026-05-23T16:52-0700 Created git worktree and branch feat/remote-pairing-auth.
- 2026-05-23T16:52-0700 Initialized devlog 000028 and plan 000028-01.
- 2026-05-23T17:11-0700 Added `rand`, `hex`, and `sha2` workspace dependencies to generate secure random tokens and perform SHA-256 validation.
- 2026-05-23T17:11-0700 Updated WebSocket JSON transport request/response types with client pairing handshake and bearer token hello extensions.
- 2026-05-23T17:11-0700 Added stateful connection-level security authentication and unit tests in `triage-transport-ws`.
- 2026-05-23T17:11-0700 Implemented transient pairing PIN code validation and secure SHA-256 token database storage in `triaged::session::SessionManager`.
- 2026-05-23T17:11-0700 Added the `triage pair` local command printing ANSI-colored PIN blocks via `pairing_code.json` and local filesystem trust.
- 2026-05-23T17:11-0700 Designed a gorgeous pairing overlay screen in the Flutter client using safe JS-interop for localStorage persistence.
- 2026-05-23T17:19-0700 Fixed a missing closing brace syntax error inside the wait_for_event unit test helper in crates/triaged/src/session.rs.
- 2026-05-23T17:19-0700 Ran cargo fmt, cargo check, and cargo test across all workspace packages, confirming 100% test suite completion.
- 2026-05-23T17:19-0700 Booted daemon to verify automatic pairing PIN generation and tested the CLI triage pair output.
- 2026-05-23T17:24-0700 Added a tracing log message displaying the remote web client page URL on WebSocket server bind in ws.rs.
- 2026-05-23T17:34-0700 Fixed LateInitializationError by removing final from the late _client variable in main.dart to allow clean socket re-initialization on pairing.
- 2026-05-23T17:37-0700 Added a try-catch fallback to cmd.exe in _createSession if the bash shell executable fails to spawn on a Windows daemon host.
- 2026-05-23T17:41-0700 Isolated each session loading iteration inside a try-catch block to prevent broken sessions from blocking healthy ones, and allowed closing tab UIs unconditionally.
- 2026-05-23T17:47-0700 Implemented a collapsible sessions sidebar in the Flutter client UI that supports full and compact minimized rail layouts, matching TUI's collapsible layout capabilities.
- 2026-05-23T17:50-0700 Registered attachCustomKeyEventHandler on xterm.js to capture the Tab key and call event.preventDefault(), resolving the browser focus escape issue and enabling shell tab autocompletion.
- 2026-05-23T17:52-0700 Hardened Tab key capture by implementing dual-layer DOM capture on container and using dynamic type casting to prevent JS-Dart bridge casting failures.
- 2026-05-23T18:00-0700 Wrapped the Web Terminal widget in a Flutter Focus widget to intercept tab events before the focus tree shifts focus, resolving web-focus loss.
- 2026-05-23T18:00-0700 Relocated the WebSocketAuthenticator implementation in triaged to before the tests module, and cleaned up empty println strings in triage command to fix Clippy warnings.
- 2026-05-23T18:03-0700 Improved Tab autocompletion by calling preventDefault/stopPropagation at the DOM level and explicitly writing tab bytes to the terminal controller, bypassing browser-level navigation.
- 2026-05-23T18:05-0700 Added capture-phase global keyboard listener on window to intercept Tab keys before Flutter Web can capture them, stopping event propagation and forwarding Tab bytes directly.
- 2026-05-23T18:07-0700 Mapped Shift+Tab events inside the global capture-phase listener to the standard ESC [ Z backtab terminal sequence, allowing reverse-navigation and other autocomplete shortcuts.
- 2026-05-23T18:09-0700 Registered a custom, premium pastel palette for the 16 standard ANSI colors in the xterm.js theme, softening glowing green/blue other-writable directory layouts.
- 2026-05-23T18:11-0700 Optimized input/resize responsiveness by converting high-frequency listeners to synchronous fire-and-forget, eliminating event-loop microtask rescheduling latency.
- 2026-05-23T18:13-0700 Set convertEol to false in xterm.js settings, ensuring raw TUI terminal layouts and newline repositioning are parsed accurately without corrupting input prompt rendering.
- 2026-05-23T18:30-0700 Added smart Ctrl+C support in the global keydown listener; copy is triggered if text selection is active, whereas regular SIGINT is sent to the process when no text is selected.
- 2026-05-23T18:37-0700 Addressed all PR #34 comments, implemented cross-platform token storage, handled pairing cancellation, cleaned up pairing files on consumption, masked secrets in trace logs, cached require_pairing setting, aligned XDG directories, and aligned CLI pair messages.
- 2026-05-23T19:04-0700 Followed up on review findings by routing `triage pair` through the daemon log-dir helper, switching Flutter token storage to a JS-interop conditional import, and adding daemon log-dir tests for XDG and HOME fallback behavior.
- 2026-05-23T21:35-0700 Critically reviewed all PR #34 resolutions, verified compile safety, and hardened Hello request unauthenticated state logic to explicitly reset authentication status if client parameters are missing.
- 2026-05-23T21:44-0700 Resolved a race condition where PTY startup output (shell prompt) was dropped by updating session state prior to event subscription.
- 2026-05-23T21:49-0700 Fixed Flutter client session loading blank terminal screen issue by introducing outputSeq sequence filtering and pending event buffering.
- 2026-05-24T06:37-0700 Implemented bidirectional focus bridging between Flutter's FocusNode and xterm.js shadow DOM textarea, and enabled convertEol to resolve input swallows and newline stair-casing offset issues.
- 2026-05-24T06:45-0700 Cached and preserved xterm.js instances and native HTML containers on the web client to prevent loss of scrollback history and focus issues during session switching.
- 2026-05-24T06:50-0700 Implemented window capture-phase 'wheel' event listener and configured 10,000 lines of scrollback to restore mouse wheel scrollback history and bypass glass-pane swallowing.
- 2026-05-24T06:55-0700 Implemented window capture-phase 'keydown' event mapping for ArrowUp/Down/Left/Right, PageUp/Down, Home, and End keys, bypassing Flutter Web's keyboard swallows to perfectly restore shell history navigation and physical scrollback keybindings.
- 2026-05-24T07:00-0700 Implemented TriageWebSocketClient.styledRows API method and updated main.dart to dynamically fetch and prepend full scrollback history from the daemon on session attach, fully resolving pre-attach history loss.
- 2026-05-24T07:05-0700 Updated global window event capture listeners for keydown and wheel in terminal_pane_web.dart to use DOM composedPath() traversal. This bypasses browser Shadow DOM element retargeting in Flutter Web, perfectly restoring scroll and keybindings.
- 2026-05-24T07:12-0700 Fixed a bug in main.dart where daemon-wide scrollback history failed to load due to directly accessing the 'rows' key rather than navigating the nested 'response' map.
- 2026-05-24T07:12-0700 Upgraded the mouse wheel capture-phase listener to perform bounding client rect checks, allowing precise scroll interception even when Flutter's pointer-swallowing glass pane sits directly on top of the platform view.
- 2026-05-24T07:18-0700 Wrapped all exception objects inside debugPrint log statements with explicit toString() calls in main.dart and terminal_pane_web.dart, completely bypassing a DWDS injected client deserialization subtype mismatch crash when printing structured exceptions under Flutter Web debug server.
- 2026-05-24T07:33-0700 Refactored the connect() method in triage_websocket_client.dart to remove the runZonedGuarded block, avoiding zone-boundary asynchronous error propagation and resolving uncaught Dart promises.
- 2026-05-24T07:34-0700 Redesigned the mouse wheel capture listener in terminal_pane_web.dart as a single, global static window listener that dynamically queries active session dimensions. This prevents registration race conditions, coordinate mismatches, and handler leaks during tab switches.
- 2026-05-24T07:35-0700 Integrated cross-browser scroll metrics fallback and a robust viewport coordinate fallback (checking if the pointer is within the active terminal workspace area, bypassing the sidebar and header) to guarantee mouse wheel scroll capture on all browsers and devices.
- 2026-05-24T07:46-0700 Added a diagnostic overlay tracking fallbackRows count, and hardened xterm.js scrollback buffer configuration and fitting timing.
- 2026-05-24T07:50-0700 Removed temporary debug prints and diagnostic overlays, restoring production layout structure.
- 2026-05-24T07:51-0700 Critically reviewed changes and removed all remaining temporary console logging in terminal_pane_web.dart.
- 2026-05-24T08:33-0700 Fixed Flutter pairing client identity by generating and persisting a per-install client id alongside the bearer token, preventing one paired device from invalidating another device's token.

## Decisions
- 2026-05-23T16:52-0700 Establish a token-based pairing handshake protocol over the WebSocket endpoint to secure daemon state access.
- 2026-05-23T17:05-0700 Keep the transport lightweight and cross-platform by deferring native TLS wrapping inside the Rust daemon, letting users encapsulate connections securely over VPN layers like Tailscale.
- 2026-05-23T17:05-0700 Leverage local OS filesystem directory permissions as the local trust boundary, utilizing JSON files to securely share pairing state with the local CLI across Unix and Windows without IPC socket dependencies.
- 2026-05-23T19:04-0700 Expose the daemon session log-dir resolver from `triaged::session` rather than maintaining a duplicated pairing-file path in the CLI.
- 2026-05-24T06:45-0700 Retain terminal instances globally in a static registry, selectively binding controllers during mount/unmount rather than disposing xterm.js on widget updates, to preserve the interactive shell history buffer.
- 2026-05-24T06:50-0700 Intercept mouse wheel events globally in the window capture phase and translate them to programmatic scroll calls, bypassing Flutter Web's pointer-swallowing glass-pane overlay.
- 2026-05-24T06:55-0700 Map shell history navigation and scrollback keys in the global capture phase, stopping Flutter from eating keystrokes and allowing native PTY terminal line editing to work correctly.
- 2026-05-24T07:00-0700 Query the daemon's styled_rows API for all lines outside the current visible viewport snapshot when attaching, reconstructing the entire scrollback history for immediate client-side scrollback navigation.
- 2026-05-24T07:05-0700 Utilize standard DOM composedPath() traversal in window capture-phase event handlers to inspect target elements across platform view Shadow Root encapsulation boundaries in Flutter Web.
- 2026-05-24T07:12-0700 Utilize bounding client rect viewport boundary comparison for the capture-phase wheel listener to ensure reliable event targeting under Flutter Web's absolute overlay elements.
- 2026-05-24T07:33-0700 Refactor connect lifecycle to utilize standard try-catch and non-zoned stream handlers, ensuring unhandled async exceptions align with normal Dart futures.
- 2026-05-24T07:34-0700 Consolidate mouse wheel scrolling into a single, global static window listener that dynamically routes events to the active terminal's container bounds to prevent lifecycle leaks and race conditions on tab/session switching.
- 2026-05-24T07:35-0700 Implement cross-browser scroll metrics fallbacks and workspace bounds coordinate fallback checking (x > 250, y > 50) to guarantee reliable scroll interception regardless of browser driver configurations.
- 2026-05-24T08:33-0700 Preserve the daemon's single token hash per `ClientId` model and make remote Flutter installs unique at the client layer, which avoids widening the daemon authentication state for this review fix.

## Commits
- f7ec173 — feat: implement remote client pairing and secure token authorization
- f9bc480 — feat: log remote web client URL when daemon WebSocket starts
- 6f6e7c0 — fix: remove final from late client to allow socket re-initialization
- e59c65b — fix: fall back to cmd.exe in _createSession if bash spawn fails
- 6f007e5 — fix: isolate session loading loop and close tabs unconditionally
- de11fb0 — feat: implement collapsible sessions rail for sidebar minimization
- d5c3d2a — fix: intercept and prevent Tab key focus escapes in xterm.js
- c6777b4 — fix: implement robust dual-layer DOM and dynamic JS Tab key focus capture
- 39da11d — fix: address PR review comments and resolve clippy errors
- 2207b53 — feat: switch pairing PIN to 8-char Crockford Base32
- HEAD — fix: address remote client review follow-ups

## Next Steps
- None.
