# docs/triaged-web-server-pairing

## Agent
- 2026-06-02T18:53-0700 — Claude Code (claude-opus-4-8) @ argus branch docs/triaged-web-server-pairing — Documented the triaged web server, connecting, and pairing in the crate's crates.io metadata.

## Intent
- Update the triaged crates.io metadata (description + README) to explain the embedded web server, how to connect, and the pairing process. Originally drafted on the 0.1.2 bump branch; PR #55 merged with only the version bump, so the docs land in this separate PR.

## What Changed
- 2026-06-02T18:53-0700 `crates/triaged/Cargo.toml` — Broadened the crates.io `description` to mention the built-in web client + WebSocket API and PIN-paired remote attach.
- 2026-06-02T18:53-0700 `crates/triaged/README.md` — Added "Web Server & Connecting" (default `127.0.0.1:7777` loopback bind serving the web UI at `/`, the WebSocket API at `/ws`, and `/pair`; binding a routable address via `~/.config/triage/config.toml`) and "Pairing" (device-code → loopback-only PIN approval → bearer-token flow).

## Decisions
- 2026-06-02T18:53-0700 Documented pairing around the loopback/same-host approval gate (`is_local_pairing_peer`): a remote client can request a challenge but only someone with local access to the daemon host can open `/pair`, approve the device code, and read the device-bound PIN.
- 2026-06-02T19:20-0700 (PR #56 review) Dropped the TLS/`https`/`wss` guidance from the README and devlog. `triaged` has no TLS dependency and never reads the `remote.tls_cert`/`tls_key` config fields (they are only schema-validated), so documenting TLS would imply transport security the daemon does not provide; the README now states it serves plain HTTP/WS and points to a reverse proxy for TLS. Corrected the pairing approval URL to `http://127.0.0.1:7777/pair...` opened on the daemon host (the LAN host URL 404s for a remote browser).

## Research & Discoveries
- 2026-06-02T18:53-0700 triaged 0.1.2 is already published on crates.io (versions 0.1.2/0.1.1/0.1.0). crates.io metadata (description + README) is immutable per published version, so these doc changes will only appear on the crates.io page after a new version (>= 0.1.3) is published; merging this PR alone updates only the in-repo docs.

## Commits
- HEAD — docs(triaged): document web server, connecting, and pairing
