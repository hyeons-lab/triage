# Client connection settings — choose the daemon host (device-to-device)

## Thinking

Today the native Flutter client hardcodes `ws://127.0.0.1:7777/ws`
(`defaultWebSocketUriForBase`, main.dart:46) and the daemon binds loopback
(`remote.bind = 127.0.0.1:7777`). So the client can only reach a daemon on the
same machine. Goal: let the client connect to a daemon on another device
(client on one device, daemon on another) over LAN/Tailscale.

### Decisions (settled with user)

- **Connect UX** → first-run connection screen + a gear-icon settings entry,
  also surfaced on connect failure. Saved address auto-connects on later launches.
- **Address input** → one smart field accepting `host`, `host:port`, or a full
  `ws://`/`wss://` URL; normalized to `ws://host:7777/ws` (bare host) etc.
- **Daemon** → flip the default `remote.bind` to `0.0.0.0:7777`. `require_pairing`
  already defaults to `true` (config.rs:222), so access stays pairing-gated;
  add a startup warning that the daemon is now network-reachable.

### Key findings

- `_client` is `late` (reassignable), built inside `_connectWebSocket()` from
  `widget.client ?? TriageWebSocketClient(_defaultWebSocketUri())`
  (main.dart:780). Reconnect already rebuilds the client → address change is a
  re-trigger of `_connectWebSocket()` with a different URI.
- `shared_preferences` is already a dependency (added for the side rail).
- Tests inject `client:` (non-null `widget.client`) → they must keep
  auto-connecting and never see the connection screen.
- Config test asserts `remote.bind == "127.0.0.1:7777"` (config.rs:487) — update.

## Plan

### Client

1. `parseDaemonAddress(String) -> Uri?` (top-level, `@visibleForTesting`):
   trim; if it parses with scheme ws/wss/http/https → normalize (http→ws,
   https→wss), default port 7777, ensure path `/ws`; else treat as `host` or
   `host:port` → `ws://host:7777/ws`. Return null on empty/invalid host.
2. Persistence: `loadDaemonAddress()` / `saveDaemonAddress(String)` via
   shared_preferences key `daemon_address_v1` (store the raw user input).
3. `main()` awaits `loadDaemonAddress()` and passes it to
   `TriageClientApp(initialDaemonAddress:)` → `TriageHome`.
4. `_TriageHomeState`: add `Uri? _daemonUri` (from initial address) and
   `String? _daemonAddressRaw`. In initState decide:
   - `widget.client != null` (tests) → auto-connect as today.
   - saved `_daemonUri != null` → auto-connect to it.
   - else → show the connection screen (no auto-connect).
   `_connectWebSocket()` builds the client from `_daemonUri ?? _defaultWebSocketUri()`.
5. `ConnectionSettingsForm` widget: smart field (prefilled with the current
   address or `127.0.0.1`), inline validation, Connect/Save. Presented as the
   home body when unconfigured/disconnected, and in a dialog from a gear icon in
   the rail header. On submit → save → set `_daemonUri` → disconnect any current
   client → `_connectWebSocket()`.
6. Gear icon in `SessionRail` header → opens the settings dialog.
7. Connect-failure state shows a "Configure connection" affordance.

### Daemon

8. `RemoteConfig::default().bind = "0.0.0.0:7777"`. Startup `tracing::warn!`
   when bound to an unspecified address noting pairing gates access. Update the
   config default test.

### Tests

9. Client: `parseDaemonAddress` cases (host, host:port, ws/wss/http/https,
   invalid); connection screen shown when no saved address + no injected client;
   saving an address connects. Existing injected-client tests must still pass.
10. Daemon: config default bind test → `0.0.0.0:7777`.

### Verify + ship

11. `flutter analyze` + `flutter test`; `cargo fmt/clippy/test` for triage-core.
    Devlog, commit, push, PR.

## Out of scope

- TLS (`wss://` accepted by the field but the daemon serves `ws`; Phase 6).
- mDNS/Tailscale discovery; manual address entry only.
