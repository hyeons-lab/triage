# 000068 — feat/client-connection-settings

**Agent:** Claude (claude-opus-4-8) @ triage branch feat/client-connection-settings

## Intent

Let the Flutter client connect to a daemon on another device (client on one
device, daemon on another) over LAN/Tailscale. Today the native client hardcodes
`ws://127.0.0.1:7777/ws` and the daemon binds loopback. Add a connection screen
(first-run + gear-icon settings) with a smart host/IP/URL field, persist the
chosen address, and flip the daemon default bind so it is reachable.

## Decisions

2026-06-16T00:00-0700 Connect UX: first-run connection screen + gear settings,
also shown on connect failure; saved address auto-connects on later launches.

2026-06-16T00:00-0700 One smart address field (host / host:port / full ws·wss
URL), normalized to `ws://host:7777/ws`.

2026-06-16T00:00-0700 Flip daemon default `remote.bind` to `0.0.0.0:7777`.
`require_pairing` already defaults true so access stays pairing-gated; add a
startup warning. (User accepted the LAN-exposure tradeoff for easy testing.)

## Progress

- [x] Client: address parse + persistence
- [x] Client: connection screen + gear settings + wiring
- [x] Daemon: default bind 0.0.0.0 + startup warning
- [x] Tests (95 flutter, 18 core); analyze + clippy + fmt clean
- [ ] Build + ship (push/PR/deploy pending user go-ahead)

## What Changed

2026-06-16T00:30-0700 crates/triage-core/src/config.rs — `RemoteConfig` default
`bind` → `0.0.0.0:7777`; updated the config default test assertion.

2026-06-16T00:30-0700 crates/triaged/src/main.rs — startup `tracing::warn!` when
bound to an unspecified address (different message when `require_pairing` is off).

2026-06-16T00:30-0700 crates/triaged/README.md — documented the new default bind
+ pairing-gated access; flipped the "connect from another device" section.

2026-06-16T00:30-0700 flutter/triage_client/lib/main.dart —
`parseDaemonAddress(String)->Uri?` (host / host:port / bracketed IPv6 / full
ws·wss·http·https URL, normalized to `ws://host:7777/ws`);
`loadDaemonAddress`/`saveDaemonAddress` via shared_preferences key
`daemon_address_v1`; `main()` restores the saved address into
`TriageClientApp.initialDaemonAddress`. `_TriageHomeState` resolves it in
initState: injected client (tests) or saved address → auto-connect; web →
page-derived URL; else show the connection screen (`_needsConnectionConfig`).
`_connectWebSocket` builds the client from `_daemonUri ?? _defaultWebSocketUri()`.
`_applyDaemonAddress` persists + reconnects; `_openConnectionSettings` shows the
dialog. New `ConnectionSettingsForm` (smart field + live normalized preview +
validation) and `ConnectionSettingsDialog`. Gear icon added to both rail headers
(expanded title made flex to avoid a 32px overflow) and the status row is
tappable → settings (connect-failure recovery path).

2026-06-16T00:30-0700 flutter/triage_client/test/widget_test.dart — tests:
`parseDaemonAddress` cases; first-run shows the connection screen; form
validates + submits the raw address.

## Research & Discoveries

- `_client` is `late` (reassignable); `_connectWebSocket()` already rebuilds it
  from `widget.client ?? TriageWebSocketClient(_defaultWebSocketUri())`
  (main.dart:780) — address change = re-trigger with a different URI.
- `shared_preferences` already a dependency (side-rail work).
- `require_pairing` defaults true (config.rs:222); config test asserts
  `remote.bind == "127.0.0.1:7777"` (config.rs:487) — must update.
- Injected-client tests (`widget.client != null`) must keep auto-connecting and
  never see the connection screen.

## Commits

HEAD — feat: client connection settings + daemon binds 0.0.0.0 by default
