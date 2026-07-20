# 000093 — docs/remote-access

## Intent

Write the remote-access setup guide, closing the Phase 6 gap in
`devlog/triage-design-doc.md` ("Tailscale setup doc — *not written*").

## What Changed

- Added `docs/remote-access.md`.
- Ticked the Phase 6 checkbox in `devlog/triage-design-doc.md`.
- Linked the guide from the root `README.md` remote-clients paragraph.

## Decisions

- **Recommend a tailnet, not a self-hosted relay.** This follows the design
  doc's existing position (§ "Across NAT": lean on Tailscale or WireGuard, do
  not build relay infrastructure). The guide states the reasoning rather than
  just the conclusion, because the relay shape is the intuitive one and needs
  an explicit argument against it:
  - a TLS relay exposes the daemon's pre-auth surface to the whole internet,
    where a tailnet does not respond to unauthenticated packets at all;
  - a relay terminates TLS, so it reads terminal I/O in plaintext;
  - a loopback-forwarding proxy makes every peer look like a same-host
    connection, which is auto-approved by default.
- **Rejected a self-hosted WireGuard hub**, which was the initial shape
  considered. A hub is a routing peer: it decrypts and re-encrypts, so a
  compromised instance sees keystrokes and scrollback. Tailscale's DERP relays
  forward only ciphertext. Headscale was also considered — it has the same
  end-to-end property — but it is meaningful ongoing ops (control plane, DERP,
  key rotation) for security properties the SaaS free tier already provides.
- **Documented the bind/pairing-page interaction prominently.** Narrowing
  `remote.bind` to the tailnet IP is the step that actually closes the
  exposure, but it also stops `127.0.0.1:7777` from listening, which breaks the
  pairing flow as documented elsewhere. Verified empirically: a loopback
  connection to a listener bound to a concrete non-loopback address is refused,
  and a host connecting to its own interface IP is seen by the listener with
  that same IP as the source (so same-host approval still succeeds).
- **Prose links instead of line-number citations.** Line numbers in docs go
  stale silently; the guide links to files and anchors instead.

## Research & Discoveries

- `remote.tls_cert` / `remote.tls_key` are declared and cross-validated in
  `RemoteConfig` but read by no Rust code — TLS is unimplemented, so transport
  confidentiality has to come from below regardless of deployment shape.
- The `pair_approval_trust_local_peers = false` safety setting is unreachable
  for a proxy-only deployment: config validation requires a non-empty tailnet
  allowlist, which such a deployment has no way to satisfy. Recorded in the
  guide's "What this does not cover" section rather than fixed here.
- WSL2's Hyper-V firewall defaults to blocking inbound connections to the VM,
  which silently drops tailnet traffic to `triaged`. Noted in the security
  section, as it presents as "the daemon is not responding".

## Progress

- Verified every code reference against `origin/main` before landing, and
  confirmed the `#pairing` anchor resolves.

## Commits

- HEAD — docs: add remote-access setup guide

## Next Steps

- Consider whether `remote.bind` should default to dual-stack `[::]:7777`.
  Windows resolves `localhost` to `::1` first, so an IPv4-only bind makes
  `http://localhost:7777` fail from a Windows client while
  `http://127.0.0.1:7777` works.
- Consider a config option to require a PIN even for apparently-local peers,
  which would make the reverse-proxy shape safely supportable.
