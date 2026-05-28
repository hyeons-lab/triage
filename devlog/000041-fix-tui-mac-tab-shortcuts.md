# Branch Devlog: fix/fix-tui-mac-tab-shortcuts

- **Agent:** Antigravity
- **Intent:** Add robust and conflict-free alternative keyboard shortcuts for TUI tab/session switching on macOS.

## Intent

Resolve the keyboard shortcut tab switching issue on macOS where the default `Alt + Arrow` shortcuts are intercepted, mapped to word navigation, or treated as diacritic prefixes by standard macOS terminals. We will add `Ctrl + Alt + Arrow` and `F3`/`F4` combinations as safe, conflict-free alternatives.

## What Changed

- Mapped `Ctrl + Alt + Right` and `Ctrl + Alt + Down` to the `AppCommand::Next` command.
- Mapped `Ctrl + Alt + Left` and `Ctrl + Alt + Up` to the `AppCommand::Previous` command.
- Mapped `F3` to the `AppCommand::Next` command and `F4` to the `AppCommand::Previous` command.
- Integrated native macOS `pbcopy` execution inside `write_osc52_clipboard` under a conditional compilation block `#[cfg(target_os = "macos")]`, enabling out-of-the-box clipboard copying on standard macOS terminals (which do not support or enable OSC 52 by default).
- Forced the Flutter web client to negotiate the JSON WebSocket subprotocol while keeping FlatBuffers parser coverage in place.
- Added request-type details to Flutter WebSocket timeouts and surfaced malformed inbound messages as protocol diagnostics instead of swallowing them.
- Changed embedded web asset responses to use no-store cache headers so an installed daemon cannot keep serving stale Flutter bundles during local iteration.
- Changed daemon session startup in the Flutter client to show daemon session placeholders immediately and load each session independently.
- Ignored local Playwright install and test output directories under the Flutter client.
- Re-enabled Flutter web FlatBuffers negotiation and made binary browser frames, FlatBuffers events, and generated uint64 getters compatible with dart2js.
- Updated the TUI footer hint to advertise the new `Ctrl + Alt + Arrow` and `F3`/`F4` tab-switch fallbacks.

## Decisions

- Retain existing `Alt + Arrow` shortcuts for Windows/Linux users who prefer them.
- Introduce `Ctrl + Alt + Arrow` keys which override standard macOS option-diacritic intercept behavior and are parsed reliably by crossterm.
- Introduce `F3` and `F4` keys as a completely universal backup shortcut that does not conflict with any text editing selection shortcuts or terminal emulators.
- Execute the built-in system utility `pbcopy` as a child process when Triage runs locally on macOS, providing a zero-configuration, 100% reliable system clipboard integration.
- Prefer JSON for Flutter web by default until the browser FlatBuffers path has enough end-to-end coverage to avoid opaque connection failures.
- Avoid long-lived cache headers for the embedded local web UI because local daemon installs are currently used as a development/test surface.
- Do not block the Flutter client shell on the slowest restored daemon session; one slow historical session should not make all sessions appear blank.
- Keep JSON as a fallback subprotocol, but prefer `triage-flatbuffers` now that browser binary frame parsing and event-shape compatibility are covered.
- Read generated FlatBuffers `uint64` fields from two 32-bit halves because `ByteData.getUint64` throws under dart2js; the session counters are represented as JavaScript-safe integers in the Flutter client.

## Commits

- HEAD — fix(triage): advertise tab shortcut fallbacks
- 2345fdd — fix(client): enable Flutter web FlatBuffers
- b1a2190 — fix(client): avoid blocking daemon session startup
- 8001fae — fix(triage): address PR review comments
- 7308c24 — fix(triage): use pbcopy for native macOS clipboard copy support in TUI
- 1aa224d — fix(triage): add Ctrl+Alt+Arrow and F3/F4 tab switching shortcuts for macOS

## Progress

- 2026-05-27T15:15-0700: Addressed PR review comments by switching macOS clipboard spawning to `/usr/bin/pbcopy` and simplifying `Alt + Arrow` modifier guards; `KeyModifiers::contains(KeyModifiers::ALT)` already covers `Ctrl + Alt` combinations. Verified with `cargo fmt --all -- --check` and `cargo test -p triage reserved_control_keys_become_app_commands`.
- 2026-05-27T17:26-0700: Debugged Flutter web daemon connection failures. Verified direct JSON WebSocket requests, Rust FlatBuffers stress traffic, daemon-served bundle contents, and Playwright browser traffic. Installed Playwright dependencies locally, ran the existing web tests, forced Flutter web to offer only `triage-json`, added named timeout/protocol diagnostics, disabled embedded web asset caching, and made daemon session startup nonblocking with a widget regression test. Rebuilt Flutter web, rebuilt and installed `triaged`, restarted the daemon, and verified `http://127.0.0.1:7777/` with headless Playwright. Validated with `flutter test`, `npm run test:xterm`, `cargo fmt --all -- --check`, `cargo build -p triaged --release --locked`, and `cargo test -p triaged http --target-dir target\triaged-http-tests-final`.
- 2026-05-27T20:53-0700: Re-enabled Flutter web FlatBuffers and verified the previous timeout was caused by dart2js rejecting generated `ByteData.getUint64` reads from FlatBuffers response/event payloads. Added browser binary frame handling, JSON-compatible decoded event envelopes, and web-safe generated uint64 getters. Rebuilt Flutter web with local web resources, reinstalled and restarted `triaged`, and verified headless Chromium exchanged binary WebSocket frames with an active terminal and no FlatBuffers parse/time-out logs. Validated with `flutter test test/triage_websocket_client_test.dart`, `flutter test`, `flutter build web --no-web-resources-cdn`, `cargo fmt --all -- --check`, `cargo check --workspace`, `cargo install --path crates/triaged --locked --force`, and `npm run test:xterm`.
- 2026-05-27T21:30-0700: Addressed PR review feedback that the TUI footer only advertised `Alt-arrows switch`. Updated the footer shortcut hint to include `Alt/Ctrl-Alt arrows` and `F3/F4` switching alternatives.
