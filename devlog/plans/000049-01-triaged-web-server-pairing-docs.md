## Thinking

The triaged crates.io page is its `description` field plus the rendered `README.md`.
Neither mentioned the embedded HTTP/WebSocket server, how to connect, or the pairing
flow. These were drafted on the 0.1.2 version-bump branch but that PR (#55) merged with
only the version bump, so the docs need their own PR off the updated main.

Facts verified from the source:
- Default bind `127.0.0.1:7777` (`RemoteConfig::default`), one TCP port serving the
  embedded web client (`/`), the WebSocket API (`/ws`), and the pairing page (`/pair`).
- Config at `~/.config/triage/config.toml`, `[remote]` with `bind`, `require_pairing`
  (default true), `tls_cert`/`tls_key`.
- Pairing is a device-code -> PIN -> bearer-token flow; `/pair` approval is gated to
  loopback/same-host peers (`is_local_pairing_peer`), so a remote client can request a
  challenge but only someone with local access to the host can approve it.

## Plan

1. Broaden `crates/triaged/Cargo.toml` `description` to mention the web client + WebSocket
   API and PIN-paired remote attach.
2. Add "Web Server & Connecting" and "Pairing" sections to `crates/triaged/README.md`.
3. Commit devlog + plan + change, push, open a new PR off main.

Note: triaged 0.1.2 is already published on crates.io, and crates.io metadata is
immutable per published version. Merging this PR updates the repo docs, but the
crates.io page only changes when a new version (>= 0.1.3) is published.
