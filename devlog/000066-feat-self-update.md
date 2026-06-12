# 000066 — feat/self-update

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch feat/self-update

## Intent

Add an "update available" notification when the running version is older than the
latest GitHub release tag, and let the user update in place:

- **Daemon (`triaged`)** self-updates via the existing zero-downtime handover
  (`triaged --handover`) — live PTY sessions survive the swap.
- **TUI (`triage`)** and **Flutter client** both surface the update banner.
- **Flutter desktop client** downloads + installs the matching release asset for
  its platform and relaunches.

## Decisions

- 2026-06-11T22:22-0700 Leverage handover for full daemon self-update — reasoning:
  `triaged --handover` already passes live PTY master FDs + the TCP listener over
  `SCM_RIGHTS` and runs a 3-phase teardown sync, so a new binary adopts running
  sessions on the same port with no session loss. Restart-and-lose is unnecessary.
- 2026-06-11T22:22-0700 Binary acquisition = prebuilt download preferred, `cargo
  install --force` fallback (user choice "Both, auto-detect"). Requires extending
  `publish.yml` to build/sign/attach prebuilt `triaged`/`triage` binaries per OS —
  releases currently attach only the Flutter clients.
- 2026-06-11T22:22-0700 Flutter client = in-app download + install + relaunch
  (user choice). Platform-specific; highest UX, most fragile path.
- 2026-06-11T22:22-0700 Surface update info to all clients via the shared session
  API, carried on the `HelloResult` handshake (already transports
  `protocol_version`). One API, many transports.
- 2026-06-11T22:22-0700 Add a handover protocol-version check with graceful
  fallback to persist-and-restart when old↔new daemon are incompatible.

## Research & Discoveries

- Release flow: `.github/workflows/publish.yml` (manual `workflow_dispatch`) →
  publishes 5 crates to crates.io → builds Flutter desktop clients per OS →
  `release` job tags `vX.Y.Z` and attaches `Triage-{macos,windows,linux}-vX.Y.Z`.
  **No prebuilt Rust binaries are attached today.**
- Version source of truth: `VERSION` → `scripts/bump-version.sh` propagates to
  `Cargo.toml` (`[workspace.package].version`) and `pubspec.yaml`. Daemon reads
  its own version via `env!("CARGO_PKG_VERSION")`.
- Handover: `crates/triaged/src/handover.rs` (FD passing) + `main.rs:17-109`
  (`--handover`/`-U` adopt path) + `ipc.rs:418-473` (`handle_handover_server`).
  Unix-only; Windows bails to session-restore.
- Protocol: `crates/triage-core/schema/triage.fbs`. `HelloResult` table
  (`protocol_version`, `authenticated`) is the natural carrier for server version
  + update info. Flutter parses it in
  `lib/services/triage_websocket_client.dart:427`.
- Latest tags on origin: v0.1.0, v0.1.3, v0.1.4, v0.1.5 (current).

## Plan

See `devlog/plans/000066-01-self-update.md`.

## Commits

- (none yet — planning)
