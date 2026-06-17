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

> **Pairing still happens on the host.** Even with a routable bind, the `/pair`
> approval page is only served to loopback / same-host connections (see
> [Pairing](#pairing)), so approving a remote client requires access to the
> daemon machine itself.

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
flow, and crucially the **approval step is restricted to the daemon host itself**,
so a remote client can never authorize its own access.

1. **Challenge.** A new client connects to `/ws` and sends a `hello` with its
   `client_id` (and a stored token, if it has one). With no valid token the
   daemon treats it as unauthenticated, and the client requests a *pairing
   challenge*. The daemon returns a short-lived `device_code`.
2. **Approve (on the daemon host).** The client surfaces the device code. Open
   the approval URL **on the machine running the daemon** —
   `http://127.0.0.1:7777/pair?device_code=<device_code>`. The `/pair` page is
   only served to **loopback / same-host connections** (`is_local_pairing_peer`),
   so it cannot be opened from the remote client's own browser (that request
   404s); approving a remote device means having local or SSH access to the
   daemon host. The page validates the device code and displays a one-time,
   **device-bound PIN** with an expiry.
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
