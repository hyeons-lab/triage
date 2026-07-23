# 000107-01 — Always show the daemon-host pairing URL

## Thinking

The pairing screen (`_PairingView`) already always shows the **device code**. It
shows a clickable **Verification URL** button only when the daemon host is
loopback (`_verificationUriForClient` returns null otherwise); for a remote
daemon it renders "Local approval required" / "Use the daemon host pairing page
or run triage pair" — no URL at all.

The user's complaint: when pairing from another machine, the screen doesn't tell
you *what URL to open on the daemon machine*. It only helps when you're already
on the daemon host. They want the code **and** the daemon-host URL shown always.

### Why the URL is suppressed today — and the security line we must keep

`_verificationUriForClient` returns null for a non-loopback host on purpose.
`test/widget_test.dart` ("a DNS name starting with 127. is not treated as
local") documents it: rendering the daemon's **claimed host** (e.g.
`127.0.0.1.evil.com`) as a trusted "Verification URL" button carrying the device
code is an attack surface. So the fix must **not** start echoing the daemon's
claimed host.

### The insight that makes this safe

`/pair` only authorizes a **loopback / same-host** request. So the URL to open on
the daemon machine is always `http://127.0.0.1:<port>/pair?device_code=<code>` — a
**fixed loopback literal**, never the daemon's claimed host. `<port>` is the port
the user themselves typed to connect (`wsUri.port`); `<code>` is the
daemon-issued device code already shown on screen. Rendering that instruction
leaks nothing new and never surfaces an attacker-influenced host.

The difference between local and remote is only **whether it's clickable**:
- **Loopback host** (client is on the daemon machine): keep the existing
  clickable button — clicking opens the browser to the daemon. Unchanged.
- **Remote host**: show the same loopback URL as **instruction text** ("Open on
  the computer running triaged") with a copy button — not a clickable link,
  which would hit the *client's own* loopback.

Keeping `_verificationUriForClient` exactly as-is (loopback→clickable uri,
remote→null) means the local case and its tests are untouched; only the remote
branch changes.

## Plan

1. `flutter/triage_client/lib/main.dart`
   - Add `_daemonHostPairingUri(client, {deviceCode})` → always non-null
     `http(s)://127.0.0.1:<wsPort>/pair?device_code=<code>` (loopback literal, never
     `wsUri.host`).
   - Keep `_verificationUriForClient` unchanged (drives the clickable button).
   - Store `_pairingDaemonHostUri`, set it beside `_pairingVerificationUri` in
     `_requestPairingChallenge`.
   - Pass `daemonHostUri` into `_PairingView`.
   - In `_PairingView`: replace the "Local approval required" `else` branch with
     the daemon-host URL (SelectableText + "Copy pairing URL"), labelled "Open on
     the computer running triaged". Reword the header's remote-case sentence to
     point at that URL. Local (clickable) branch unchanged.
2. `flutter/triage_client/test/widget_test.dart`
   - Update the two remote-case tests: drop the "Local approval required" /
     "triage pair" assertions; assert the instruction shows
     `127.0.0.1:7777/pair` + `device_code=…`, and — the security guard — that
     the daemon's claimed host (a LAN IP, or `127.0.0.1.evil.com`) is still
     never rendered. Local-case test stays green untouched.
3. Validate: `flutter analyze`, `flutter test`, `dart format`. Then
   `/review-fix-loop max`, then PR (with confirmation).
