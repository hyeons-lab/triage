# Remote Access

How to use Triage from your phone or laptop away from home, without exposing
the daemon to the public internet.

## Why not a cloud relay

The intuitive setup is a VPS with a TLS certificate proxying to your daemon.
It works, but it is strictly worse here:

- **It exposes the daemon pre-auth.** Any internet scanner completes a TLS
  handshake and starts speaking WebSocket to `triaged`. On a tailnet,
  WireGuard never replies to unauthenticated packets — the port is invisible.
- **The relay reads your terminal.** It terminates TLS, so it sees keystrokes
  and scrollback in plaintext. A compromised relay is a compromised shell.
  A self-hosted WireGuard *hub* has the same flaw: a hub is a routing peer, so
  it decrypts and re-encrypts.
- **It breaks the local-peer check.** `triaged` terminates no TLS, so a proxy
  forwards over loopback and every request then looks like a same-host
  connection — which is auto-approved by default. See the security caveats in
  [`crates/triaged/README.md`](../crates/triaged/README.md#pairing).

Tailscale avoids all three: devices are end-to-end encrypted, and DERP relays
forward only ciphertext, so Tailscale itself cannot read your traffic. There is
no server to run, and the free tier covers personal use.

`triaged` terminates no TLS at all — `remote.tls_cert` / `remote.tls_key` are
schema-validated but never read — so confidentiality has to come from the
transport underneath it either way.

## Setup

### 1. Daemon host joins your tailnet

```bash
tailscale up
tailscale ip -4          # -> 100.x.y.z
```

### 2. Narrow the Triage bind to the tailnet interface

This is the step that actually closes the exposure. The shipped default is
`0.0.0.0:7777` — all interfaces, including your LAN.

```toml
# ~/.config/triage/config.toml
[remote]
bind = "100.x.y.z:7777"    # the tailnet IP from step 1, NOT 0.0.0.0
require_pairing = true
```

> **This moves the pairing page.** Binding to a specific non-loopback address
> means `127.0.0.1:7777` is no longer listening — a loopback connection gets
> `ECONNREFUSED`. Use `http://100.x.y.z:7777/pair` on the daemon host instead.
> Approval still works there: a host connecting to its own interface IP is seen
> by the listener with that same IP as the source, which satisfies the
> same-host check in `is_local_pairing_peer`
> ([`crates/triaged/src/ws.rs`](../crates/triaged/src/ws.rs)).

### 3. Each client device joins the tailnet

Install the Tailscale app (iOS / Android / macOS / Windows / Linux) and log in
with the same account. Then add the server in the Triage client as
`100.x.y.z:7777`.

MagicDNS also works, so `your-machine:7777` is equivalent and survives an IP
change.

### 4. Pair the device

1. The client shows a device code. (It connects to `/ws`; it never hits
   `/pair`.)
2. On the **daemon host**, open `http://100.x.y.z:7777/pair`, enter the device
   code, and get a PIN.
3. Type the PIN into the client. It receives a persistent per-device token.

The PIN is 8 Crockford Base32 characters — roughly 1.1 trillion combinations
with a 5-minute TTL, so it is sound without brute-force throttling.

### Optional: approve pairing without host access

To approve a new device from your phone rather than walking to the daemon host,
allowlist your tailnet identity:

```toml
[remote]
pair_approval_tailnet_users = ["you@example.com"]
```

The daemon resolves the peer's identity with `tailscale whois` and matches it
against this list. Read the security caveats in
[`crates/triaged/README.md`](../crates/triaged/README.md#pairing) first — in
particular, an allowlisted device can approve *its own* pairing, so this
replaces rather than adds to the "approval requires host access" guarantee.

If `tailscale` is not runnable on `PATH`, the gate fails closed (every remote
peer denied) and the daemon warns at startup.

## Security notes

- **Do not leave `bind = "0.0.0.0:7777"` once you rely on the tailnet.** With
  an all-interfaces bind, the daemon trusts the connection source IP as an
  identity input, and any device on your LAN can reach the port. `triaged`
  warns at startup in this configuration.
- **No TLS inside the tunnel, by design.** Traffic on the wire is
  WireGuard-encrypted; on the host it is plain HTTP bound to the tailnet
  interface. Anything already running as your user on that host can reach it —
  unchanged from a LAN/tailnet setup today.
- **Tagged nodes share one identity.** Tailscale reports tag-owned nodes as the
  synthetic login `tagged-devices`, which is rejected from the allowlist. List
  real user logins.
- **Host firewalls apply.** Some hosts filter inbound traffic to the daemon
  even on a tailnet interface. On WSL2 in particular, the Hyper-V firewall for
  the VM defaults to blocking inbound connections, which silently drops tailnet
  traffic to `triaged`.

## What this does not cover

Bare-browser access from a machine with no Tailscale client — a borrowed
laptop, say. That requires the reverse-proxy shape, and with it the pre-auth
exposure described above.

It also needs a config option that does not exist yet: a way to require a PIN
even for apparently-local peers. Setting `pair_approval_trust_local_peers =
false` currently demands a non-empty tailnet allowlist
([`crates/triage-core/src/config.rs`](../crates/triage-core/src/config.rs)),
which a proxy-only deployment has no way to satisfy.
