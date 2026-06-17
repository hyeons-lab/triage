# 000072-01 — Tailnet identity pairing approval

## Thinking

Today `/pair` approval is gated by `is_local_pairing_peer` (`crates/triaged/src/ws.rs:75`):
the peer must be loopback, or (concrete-bind only) exactly the listener IP. With the
new `0.0.0.0` default bind, only loopback can approve — so remote pairing means
SSHing into the daemon host to open `/pair` locally. We want terminal-free approval
from any of *our own* tailnet devices.

The threat the gate defends: `/pair` shows the PIN. Whoever can reach `/pair` can
self-approve a pairing challenge and self-issue a bearer token. So "can reach
`/pair`" must equal "is authorized to grant access." Tailnet-reachable is not by
itself "authorized" — on a shared tailnet, any member could self-pair. The fix is
to gate approval on an **allowlisted, authenticated tailnet identity**, not on
source IP (which is spoofable).

Identity comes from `tailscale whois --json <ip:port>` (CLI shellout chosen over the
LocalAPI socket: the CLI handles socket discovery + macOS-GUI sameuserproof auth on
every platform; `/pair` is one-time-per-device so subprocess cost is irrelevant).
We parse `UserProfile.LoginName` and check it against a config allowlist.

Design constraints:
- **Opt-in, additive.** Empty/absent allowlist = byte-for-byte today's behavior
  (loopback only). Tailscale absent / whois fails / not on allowlist → reject,
  exactly as today.
- **Don't block the accept loop.** `allow_pairing_approval` is currently computed
  sync at accept time (`ws.rs:43`) before `tokio::spawn`. A whois lookup does I/O
  (subprocess). Move the gate computation *inside* the spawned task so a slow whois
  never stalls accepting new connections. Add a short timeout on the subprocess.
- **Identity from whois, not IP range.** No `100.64.0.0/10` heuristic.

## Plan

1. **Config** (`crates/triage-core/src/config.rs`)
   - Add `RemoteConfig.pair_approval_tailnet_users: Vec<String>` (`#[serde(default)]`,
     default empty).
   - Validate: each entry non-empty (reuse `ensure_non_empty_items`).
   - Update the `RemoteConfig::default()` doc comment to mention the new gate.
   - Add a test asserting the default is empty and that a populated list parses.

2. **whois helper** (`crates/triaged/src/ws.rs` or a small new `tailscale.rs`)
   - `async fn tailscale_whois_login(addr: SocketAddr, timeout: Duration) -> Option<String>`
   - Runs `tailscale whois --json <ip>:<port>` via `tokio::process::Command` with a
     timeout; on success parse JSON and return `UserProfile.LoginName`
     (lowercased/trimmed). Any error/timeout/missing-binary → `None`.
   - JSON shape confirmed: top-level `UserProfile.LoginName` (string).

3. **Gate** (`crates/triaged/src/ws.rs`)
   - Keep `is_local_pairing_peer` untouched (loopback / same-concrete-IP).
   - New `async fn allow_pairing_approval(addr, bind_addr, allowlist) -> bool`:
     `is_local_pairing_peer(...) || (!allowlist.is_empty() && whois login ∈ allowlist)`.
   - Only invokes whois for non-loopback peers when the allowlist is non-empty.
   - Move the call inside `tokio::spawn` (it becomes async); thread the allowlist
     (`Arc<Vec<String>>`) into `start_websocket_server`.

4. **Wire config through** (`crates/triaged/src/ws.rs`, `crates/triaged/src/main.rs`)
   - `start_websocket_server(manager, listener, cache, pair_approval_tailnet_users)`.
   - `main.rs:152` passes `config.remote.pair_approval_tailnet_users.clone()`.

5. **Tests** (`crates/triaged/src/ws.rs`)
   - Existing `is_local_pairing_peer` tests stay green.
   - Allowlist empty → non-loopback peer rejected without calling whois.
   - whois-login-on-allowlist → approved; not-on-allowlist → rejected (inject the
     whois result via a small seam so tests don't shell out).

6. **Docs** (`crates/triaged/README.md`)
   - Pairing section: document `pair_approval_tailnet_users` and the
     approve-from-any-tailnet-device flow; note it requires the `tailscale` CLI on
     the daemon host and that identity is authenticated by Tailscale, not source IP.

7. **Validate**: `cargo fmt`, `cargo clippy --all-targets`, `cargo test` (core + triaged).
   `JAVA_HOME` not needed (Rust only). No Flutter changes.
