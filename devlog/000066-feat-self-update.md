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
- 2026-06-11T22:41-0700 Plan revised after a code-grounded critical review (see
  Issues). Self-update handover is rewritten around a health-gated, abortable
  pre-flight with rollback intent; the incompatible-version fallback requires
  explicit user confirmation (it kills live sessions). Update push uses a new
  connection-level `ServerNotice`, not `SessionEventPayload`. Version check
  defaults to `git ls-remote --tags` (no outbound TLS dep); asset URLs add TLS
  only when downloading. Signing split into Phase 0b (minisign keys as CI
  secrets) and is a prerequisite for download-install. Flutter in-app install
  demoted to a later sub-phase gated on notarization; browser-download is the
  default. Revisions captured in the plan's "Revisions" section.

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

## Issues

- 2026-06-11T22:41-0700 Critical review found two false assumptions in v1 of the
  plan, verified against code: (1) no outbound HTTP/TLS client exists in `triaged`
  (`hyper` is server-only; no `reqwest`/`rustls` in the workspace), so the GitHub
  poll needs a new TLS stack — avoided for the version check by using `git
  ls-remote`; (2) the event system is session-subscription-scoped only
  (`EventPayload.subscription_id`), so a daemon-global update push needs a new
  connection-level `ServerMessagePayload` variant, not `SessionEventPayload`.
  Also surfaced: handover failure orphans live PTYs with no rollback (now
  health-gated/abortable); persist-and-restart fallback silently kills sessions
  (now requires confirmation); macOS in-app install fights Gatekeeper under
  ad-hoc signing (now browser-download default). Full findings F1–F9 in the plan.

## Commits

- 63b9117 — docs(devlog): plan self-update & update notifications
- HEAD — docs(devlog): revise self-update plan after critical review
