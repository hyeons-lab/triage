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
- 2026-06-19T07:04-0700 PR 2 (Phases 1–2) implementation choices. Version check
  via `git ls-remote --tags --refs` (per F5 — no outbound TLS client added);
  `--refs` drops the peeled `^{}` lines but parsing tolerates them anyway.
  Semver parsing is a hand-rolled strict `X.Y.Z` parse rather than a new `semver`
  dependency — release tags are trivial, and a non-`X.Y.Z` tag (prerelease,
  `nightly`) naturally fails the parse, which *is* the stable-channel policy.
  The poller is a plain `std::thread` + `thread::sleep` (no async runtime in the
  daemon's main thread; `git ls-remote` is a blocking subprocess anyway). Update
  status is surfaced two ways: it rides every `HelloResult` (new
  `server_version` / `update_available` / `latest_version` fields, appended for
  FB compatibility) and is pushed once on the transition via a new
  connection-level `UpdateAvailablePayload` (per F4 — a `ServerMessagePayload`
  variant, not a `SessionEventPayload`), reusing the existing
  `broadcast_global` / `global_senders` fan-out the snippet/context pushes use.
  A missed push is self-healing because the same data is on the next handshake.
  Surfaced to the transport layer through a defaulted `SessionApi::server_update_info`
  so non-daemon implementors (mocks, MCP recorder) are unaffected; the `Arc<T>`
  blanket impl forwards it so the daemon's real status reaches `Hello`.

## What Changed

- 2026-06-19T07:04-0700 `crates/triage-core/src/config.rs` — new `[update]`
  config section (`UpdateConfig`: `check` = true, `interval_hours` = 6,
  `channel` = "stable") with `Default` + `validate`, wired into `Config`.
- 2026-06-19T07:04-0700 `crates/triaged/src/update.rs` (new) — Phase 1 update
  check: `UpdateStatus`, `current_version()`, `fetch_latest_tag()` via
  `git ls-remote`, pure `latest_tag_from_ls_remote` / `parse_semver` /
  `compute_status` helpers, and a best-effort background poll thread
  (`spawn_poller`) that stores the status and fires a callback on the transition
  into "update available". 7 unit tests (tag parsing, prerelease/peeled
  rejection, version compare, transition-only signalling).
- 2026-06-19T07:04-0700 `crates/triaged/src/session.rs` — `SessionManager` gains
  an `Arc<RwLock<UpdateStatus>>`, an `update_status()` accessor,
  `start_update_poller()` (spawns the poller with a weak-ref broadcast callback,
  mirroring `start_summarizer`), `broadcast_update_available()`, and an override
  of `SessionApi::server_update_info`. `crates/triaged/src/main.rs` starts the
  poller at daemon startup alongside the summarizer. `lib.rs` registers the
  module.
- 2026-06-19T07:04-0700 `crates/triage-core/src/session.rs` — `SessionApi` gains
  a defaulted `server_update_info() -> ServerUpdateInfo`; `Arc<T>` blanket impl
  forwards it; new `ServerUpdateInfo` type.
- 2026-06-19T07:04-0700 `crates/triage-core/schema/triage.fbs` — appended
  `server_version` / `update_available` / `latest_version` to `HelloResult` and
  a new `UpdateAvailablePayload` table + `ServerMessagePayload` union member.
  Rust bindings auto-regen via `build.rs`; Dart bindings regenerated with
  `flatc --dart` (committed).
- 2026-06-19T07:04-0700 `crates/triage-transport-ws/src/lib.rs` +
  `flatbuffers_proto.rs` — extended `ServerResult::Hello` (owned + borrowed),
  added `ServerMessage::UpdateAvailable` (owned + borrowed) with FB
  serialize/parse, and populated `Hello` from `api.server_update_info()`. New
  `flatbuffers_update_available_roundtrip` test; `hello` tests assert the new
  fields. `stress_client.rs` Hello patterns gained `..` for the new fields.

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

### PR review comments (Copilot, #91)

- 2026-06-19T07:27-0700 `crates/triage-core/src/config.rs` — Copilot: `update.channel`
  was documented as "only `stable`" but validation only checked non-empty, so an
  unknown channel was silently accepted with no effect. Now `validate` rejects
  anything but `stable` (relax to an enum when more channels exist). Added tests:
  default config validates, unknown channel rejected, zero interval rejected.
- 2026-06-19T07:27-0700 `crates/triaged/src/update.rs` — Copilot: use the
  canonical `.git` remote URL for `git ls-remote` to avoid relying on a GitHub
  redirect. Changed `RELEASE_REPO_URL` to `…/triage.git`.
- 2026-06-19T07:27-0700 `crates/triage-transport-ws/src/flatbuffers_proto.rs` —
  Copilot: the borrowed `Hello.latest_version` was `&str` with `unwrap_or("")`,
  collapsing the FlatBuffers "field absent" case into an empty string while the
  owned side is `Option<String>`. Changed the borrowed field to `Option<&str>`
  and the parser to pass `hello.latest_version()` through unchanged.
- 2026-06-19T07:27-0700 `crates/triage-core/schema/triage.fbs` — Copilot: comment
  said `latest_version` is "empty until the first check"; reworded to "absent
  (null)" to match how FlatBuffers omits an unset field. Comment-only; bindings
  unchanged.

## Commits

- 8f8ebfe — docs(devlog): plan self-update & update notifications
- 95ac71b — docs(devlog): revise self-update plan after critical review
- 2d5d32d — feat(triaged): background update check + surface over session API
- HEAD — fix(triaged): enforce stable channel, canonical ls-remote URL, optional borrowed latest_version
