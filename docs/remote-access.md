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

### 3. Each client device joins the tailnet

Install the Tailscale app (iOS / Android / macOS / Windows / Linux) and log in
with the same account. Then add the server in the Triage client as
`100.x.y.z:7777`.

MagicDNS also works, so `your-machine:7777` is equivalent and survives an IP
change.

### 4. Pair the device

1. The client connects to `/ws` and displays a device code alongside the CLI
   command to run.
2. On the **daemon host**, run the CLI pairing command as the user running `triaged`:
   ```bash
   triage pair <device-code>
   ```
   The CLI connects over local IPC with kernel-authenticated credentials,
   approves the device code, and prints the 8-character PIN and expiration time.
3. Type the PIN into the client. It receives a persistent per-device token.

The PIN is 8 Crockford Base32 characters with a 5-minute TTL.

## Security notes

- **Do not leave `bind = "0.0.0.0:7777"` once you rely on the tailnet.** With
  an all-interfaces bind, the daemon trusts the connection source IP as an
  identity input, and any device on your LAN can reach the port. `triaged`
  warns at startup in this configuration.
- **No TLS inside the tunnel, by design.** Traffic on the wire is
  WireGuard-encrypted; on the host it is plain HTTP bound to the tailnet
  interface. Anything already running as your user on that host can reach it:
  unchanged from a LAN/tailnet setup today.
- **Host firewalls apply.** Some hosts filter inbound traffic to the daemon
  even on a tailnet interface. On WSL2 in particular, the Hyper-V firewall for
  the VM defaults to blocking inbound connections, which silently drops tailnet
  traffic to `triaged`.

## What this does not cover

Bare-browser access from a machine with no Tailscale client: a borrowed
laptop, say. That requires the reverse-proxy shape, and with it the pre-auth
exposure described above.
