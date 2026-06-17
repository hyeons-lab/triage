# triaged

Persistent daemon process that manages terminal session state, PTY multiplexing, and canonical VT performance structures for **Triage**, the attention-routing terminal supervisor.

The daemon runs persistently in the background, keeping terminal scrollbacks, layout grids, and active PTY handles alive even when no clients are attached.

## Installation

```bash
cargo install triaged
```

## Running the Daemon

Start the persistent supervisor process:

```bash
triaged
```

---

## Web Server & Connecting

`triaged` embeds an HTTP/WebSocket server that, by default, listens on
`0.0.0.0:7777` — all interfaces, so the client can connect from another device
on your LAN/tailnet. Access is gated by device-code + PIN pairing
(`require_pairing`, default true), and the daemon logs a warning at startup when
bound to an unspecified address. A single TCP port serves three things:

- **Web client** — a built-in browser UI is served at `/`. Open
  <http://127.0.0.1:7777> (or `http://<daemon-host>:7777` from another device) to
  attach to your sessions from a browser, no separate install required.
- **WebSocket API** — clients (the web UI, the native desktop/mobile clients, or
  your own integration) attach over `ws://<daemon-host>:7777/ws`.
- **Pairing approval page** — served at `/pair` (see [Pairing](#pairing) below).

### Connecting from another device

The default bind (`0.0.0.0:7777`) is already reachable from other devices on your
network. To restrict the daemon to loopback instead, set a narrower bind address
in `~/.config/triage/config.toml`:

```toml
[remote]
bind = "127.0.0.1:7777"   # loopback only; or a specific tailnet IP
require_pairing = true
```

Then point a client at `http://<daemon-host>:7777` (web UI) or
`ws://<daemon-host>:7777/ws` (API). The daemon serves plain HTTP and WebSocket
only — it does not terminate TLS, so front it with a reverse proxy (e.g. Caddy
or nginx) if you need `https`/`wss`. Because the daemon owns live PTYs and
scrollback, you can detach and re-attach from any client without disturbing the
running shells.

> **Pairing approval is host-only by default.** Even with a routable bind, the
> `/pair` approval page is only served to loopback / same-host connections unless
> you opt in to tailnet identity approval (see [Pairing](#pairing)).

### Prebuilt desktop clients

Besides the browser UI, native desktop clients are published as artifacts on each
GitHub release. Publishing a new `triaged` version automatically creates the
`v<version>` tag, compiles the Flutter client on each platform, and attaches the
builds to the [Releases](https://github.com/hyeons-lab/triage/releases) page:

| Platform | Asset | Contains |
| -------- | ----- | -------- |
| macOS   | `Triage-macos-v<version>.zip`    | `Triage.app` |
| Windows | `Triage-windows-v<version>.zip`  | `triage_client.exe` + DLLs + `data/` |
| Linux   | `Triage-linux-v<version>.tar.gz` | `triage_client` + `lib/` + `data/` |

Download the one for your OS, unpack it, and point it at your daemon's address.

> **The release binaries are unsigned.** They are ad-hoc signed (macOS) or fully
> unsigned (Windows/Linux) — no notarization and no code-signing certificate — so
> each OS will warn before running them. This is expected for these builds; follow
> the per-platform steps below, or build from source if you'd rather not bypass
> those protections.

**macOS** — unzip, then clear the download quarantine so Gatekeeper allows the app:

```bash
unzip Triage-macos-v<version>.zip
# Remove the "downloaded from the internet" flag so macOS will run the unsigned app:
xattr -dr com.apple.quarantine Triage.app
open Triage.app
```

Without the terminal you can instead right-click `Triage.app` → **Open** → **Open**
in the dialog (only needed once); if it's still blocked, allow it under **System
Settings → Privacy & Security → Open Anyway**.

**Windows** — unzip and run `triage_client.exe`. SmartScreen may show "Windows
protected your PC" → choose **More info → Run anyway**.

**Linux** — extract and run the binary. A Secret Service provider (e.g.
`gnome-keyring`) must be available for the pairing token to persist:

```bash
tar -xzf Triage-linux-v<version>.tar.gz
chmod +x triage_client
./triage_client
```

---

## Pairing

When `require_pairing` is enabled (the default), every client must complete a
one-time PIN exchange before it can attach. This is a device-authorization-style
flow, and the **approval step is restricted to the daemon host by default**. You
can also opt in to approval from allowlisted Tailscale identities.

1. **Challenge.** A new client connects to `/ws` and sends a `hello` with its
   `client_id` (and a stored token, if it has one). With no valid token the
   daemon treats it as unauthenticated, and the client requests a *pairing
   challenge*. The daemon returns a short-lived `device_code`.
2. **Approve.** The client surfaces the device code. By default, open the
   approval URL **on the machine running the daemon** —
   `http://127.0.0.1:7777/pair?device_code=<device_code>`. By default the `/pair`
   page is served to **loopback / same-host connections** (`is_local_pairing_peer`).
   If `pair_approval_tailnet_users` is configured, it is also served to remote
   peers whose authenticated Tailscale login is on that allowlist. (Setting
   `pair_approval_trust_local_peers = false` — for a loopback reverse-proxy
   deployment — drops the loopback/same-host shortcut entirely, so even
   `127.0.0.1` requests must be on the tailnet allowlist or `/pair` returns 404.)
   The page validates the device code and displays a one-time, **device-bound
   PIN** with an expiry.
3. **Enter the PIN.** That PIN is typed back into the waiting client. The client
   exchanges it (`pair(pin, client_id)`) and the daemon — after verifying the PIN
   is bound to that exact client/device — issues a **bearer token**.
4. **Attach.** The client stores the token and reconnects with
   `hello { client_id, token }`; the daemon authenticates it and the session
   attaches. The token is reused on subsequent launches, so pairing is a
   one-time step per client.

Pairing can be disabled for trusted, isolated setups by setting
`require_pairing = false` under `[remote]`, in which case clients attach without
the PIN exchange.

To approve pairing from your own tailnet devices, add the Tailscale login names
that may open `/pair`:

```toml
[remote]
# Bind to this host's Tailscale IP so only tailnet traffic can reach /pair
# (see the security caveats below); avoid 0.0.0.0 with tailnet approval.
bind = "100.x.y.z:7777"
require_pairing = true
pair_approval_tailnet_users = ["you@example.com"]
# Optional. Set false when a loopback reverse proxy fronts the daemon, so
# forwarded requests are NOT auto-trusted as local and must pass the allowlist.
# pair_approval_trust_local_peers = false
```

When a non-local peer requests `/pair`, `triaged` runs
`tailscale whois --json <peer-ip>:<peer-port>` on the daemon host, reads
`UserProfile.LoginName`, and compares it with the allowlist. If the `tailscale`
CLI is missing, the lookup times out, or the login is not allowlisted, `/pair`
remains unavailable to that peer. A successful lookup is cached per peer IP for
a few seconds; a *failed* lookup is cached only briefly, so a transient
`tailscale` hiccup won't lock out a legitimate user for long. `triaged` logs a
startup warning if the allowlist is set but `tailscale` isn't runnable, or if it
is bound to an unspecified address.

> **Security caveats for tailnet approval.** Identity is derived from the
> peer's TCP connection, so deploy accordingly:
>
> - **Bind to the tailnet interface, not `0.0.0.0`.** With an all-interfaces
>   bind the daemon trusts the connection's source IP as the identity input;
>   bind to the host's Tailscale IP (e.g. `bind = "100.x.y.z:7777"`) so only
>   traffic that actually arrives over tailscale can reach `/pair`. `triaged`
>   warns at startup when an allowlist is configured on an unspecified bind.
> - **A loopback reverse proxy bypasses the local-peer check.** `triaged`
>   terminates no TLS, so an HTTPS reverse proxy forwards over loopback — every
>   proxied request then looks like a same-host connection. By default such
>   peers are auto-approved; set `pair_approval_trust_local_peers = false` so
>   that even loopback peers must pass the tailnet allowlist (the proxy must
>   then forward genuine tailnet source IPs, or enforce the allowlist itself).
> - **Tagged nodes share one identity.** Tailscale reports every tag-owned
>   (non-user) node with the synthetic login `tagged-devices`, so it is rejected
>   from the allowlist — list real user logins, not shared/service identities.
> - **Allowlisted identities can self-approve.** An allowlisted device can both
>   request *and* approve its own pairing, so list only identities you trust to
>   authorize new devices — the allowlist replaces, it does not add to, the
>   "approval requires host access" guarantee.

---

## Zero-Downtime Upgrades (Process Handover)

On Unix-like operating systems (including Linux, WSL, and macOS), `triaged` supports **zero-downtime updates**. This allows you to upgrade the daemon binary or restart the service without dropping active terminal sessions or interrupting running foreground shells.

### How it Works

The upgrade is performed using a robust, low-level **Three-Phase Sync Protocol**:
1.  **Transfer Phase**: The new daemon process is launched and connects to the running old daemon over a Unix Domain Socket, initiating a file descriptor transfer using `SCM_RIGHTS` (`sendmsg`/`recvmsg`). The old daemon passes all active master PTY file descriptors and the bound TCP listening socket directly to the new process.
2.  **Adoption & Sync Phase**: The new daemon adopts the active descriptors, reconstructs the in-memory virtual terminal grids and scrollback history by replaying the session log files, and starts network supervision.
3.  **Teardown Phase**: Once adopted, the new daemon writes a synchronization byte back to the old daemon. The old daemon gracefully drops its session references (without closing the underlying shells), closes its Unix socket, and exits, completing a zero-downtime handover.

### Initiating a Handover

To upgrade or restart the daemon with zero downtime, run the new binary with the `--handover` (or `-U`) flag:

```bash
triaged --handover
```

### Windows Graceful Fallback

Because low-level file descriptor passing and raw Unix domain sockets are native to POSIX platforms, native Windows installations will fall back gracefully to Triage's robust **Session Restore** flow, which saves session metadata and restores shell/workspace layout structures on restart.
