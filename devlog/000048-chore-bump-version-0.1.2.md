# chore/bump-version-0.1.2

## Agent
- 2026-06-02T18:17-0700 — Claude Code (claude-opus-4-8) @ argus branch chore/bump-version-0.1.2 — Bumped the triage workspace version to 0.1.2.

## Intent
- Bump the triage Rust workspace version from 0.1.1 to 0.1.2.
- Document the triaged web server, how to connect, and the pairing process in the crate's crates.io metadata (description + README), so the 0.1.2 publish ships the new docs.

## What Changed
- 2026-06-02T18:17-0700 `Cargo.toml` — Set `[workspace.package].version` to `0.1.2` (inherited by all crates via `version.workspace = true`).
- 2026-06-02T18:17-0700 `Cargo.lock` — Refreshed the six workspace crate entries (triage, triage-core, triage-mcp, triage-test-support, triage-transport-ws, triaged) to 0.1.2 via `cargo update --workspace`; third-party dependency versions untouched.
- 2026-06-02T18:30-0700 `crates/triaged/Cargo.toml` — Expanded the crates.io `description` to mention the built-in web client + WebSocket API and PIN-paired remote attach.
- 2026-06-02T18:30-0700 `crates/triaged/README.md` — Added a "Web Server & Connecting" section (default `127.0.0.1:7777` loopback bind serving the web UI at `/`, the WebSocket API at `/ws`, and `/pair`; how to bind a routable address / TLS in `~/.config/triage/config.toml`) and a "Pairing" section explaining the device-code → loopback-only PIN approval → bearer-token flow.

## Decisions
- 2026-06-02T18:17-0700 Use `cargo update --workspace` rather than hand-editing `Cargo.lock` — it updates only the workspace members and keeps the lockfile internally consistent.
- 2026-06-02T18:30-0700 Fold the triaged doc update into the 0.1.2 bump PR rather than a separate one — the `description` field and README ship as crate metadata with the 0.1.2 publish, so they belong with the version bump.
- 2026-06-02T18:30-0700 Documented pairing emphasizing the loopback/same-host approval gate (`is_local_pairing_peer`): a remote client can request a challenge but only someone with local access to the daemon host can approve it and read the device-bound PIN.

## Commits
- 2c3c7ea — chore: bump version to 0.1.2
- HEAD — docs(triaged): document web server, connecting, and pairing
