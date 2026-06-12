# 000066-01 — Self-update & update notifications

## Thinking

### What "update" means here, component by component

Triage ships as four artifacts from one release:

| Component   | How it's distributed today                         | How it runs                          |
| ----------- | -------------------------------------------------- | ------------------------------------ |
| `triaged`   | crates.io (`cargo install`)                        | long-lived headless daemon (Unix)    |
| `triage`    | crates.io (`cargo install`)                        | TUI client; in default mode also embeds a daemon |
| Flutter app | GitHub release asset `Triage-<os>-vX.Y.Z`          | desktop GUI client (web served by daemon) |
| `triage-mcp`| crates.io                                          | stdio MCP server (spawned by agents) |

The release is cut by `publish.yml` and the canonical version is the git tag
`vX.Y.Z` (derived from `cargo metadata` on `triaged`). So "newer version
available" ≡ "latest GitHub release tag > my compiled `CARGO_PKG_VERSION`".

### Where the version check belongs

The daemon is the one always-on, network-capable, shared component. It should:
1. Know its own version (`env!("CARGO_PKG_VERSION")`).
2. Periodically query GitHub for the latest release tag.
3. Expose `{current, latest, update_available, asset_urls}` over the **shared
   session API**, so the TUI and Flutter client both render the same banner
   without each re-implementing the check. This carries on `HelloResult` (sent on
   every client handshake) plus a lightweight push event when the state changes
   mid-session.

The web client (served by the daemon) is a special case: it's bytes embedded in
the daemon, so "updating the web client" happens automatically when the daemon
updates. It only needs the banner + a "reload" affordance, not a download.

### The daemon self-update insight: handover IS the upgrade primitive

`triaged --handover` (`-U`) already does a zero-downtime process swap:
- new process connects to the running daemon's Unix socket,
- old daemon sends live PTY master FDs + the TCP listener FD via `SCM_RIGHTS`
  plus serialized `HandoverState`,
- 3-phase sync (`0x01` adopt → old tears down readers → `0x02` confirm),
- new process adopts sessions and serves on the **same inherited TCP port**.

So a full daemon self-update is just: **land the new binary on disk → spawn it
with `--handover`.** Live terminals survive; WS clients drop and hit their
existing reconnect-with-backoff against the same port. This is the headline: we
upgrade without losing a single running session.

Two non-obvious risks:
- **Binary acquisition is separate from handover.** Handover swaps a running
  process for a binary *already on disk*; it fetches nothing. We must first put
  the new binary at the exec path (download prebuilt, or `cargo install --force`).
- **Handover wire compatibility.** Adoption only works if the new binary can
  deserialize the old daemon's `HandoverState` + FD protocol. A breaking change
  there bricks in-place upgrade. Need an explicit `handover_protocol_version`
  exchanged before FD transfer, with fallback to persist-and-restart (Phase 8
  session-restore) when incompatible.

Windows has no handover → always persist-and-restart there.

### Binary acquisition (decision: both, auto-detect)

Prefer a prebuilt binary from the release (fast, no toolchain); fall back to
`cargo install triaged triage --force` (works today, needs Rust). Prebuilt
requires extending `publish.yml` to build + sign + attach per-OS Rust binaries —
they are not attached today. Signing keys (`prism_release_signing`) already
exist in the repo for this.

### Flutter client self-update (decision: in-app download + install)

The desktop app is a downloaded asset, so it self-updates independently of the
daemon. Detect OS at runtime, download `Triage-<os>-vX.Y.Z.{zip,tar.gz}`, verify
(size + checksum/signature), then replace the running bundle and relaunch.
Platform-branched and fragile:
- **macOS:** can't overwrite a running `.app` in place cleanly; stage to a temp
  dir, then a small helper script swaps the bundle and relaunches after exit.
  Watch quarantine/codesign (release is ad-hoc signed; see `publish.yml` notes).
- **Linux:** swap the bundle dir, relaunch.
- **Windows:** can't replace a running `.exe`; download installer/zip, spawn a
  helper that waits for exit, swaps, relaunches.
- **Web/mobile:** no in-app install — web shows "reload"; mobile defers to store
  / TestFlight later. Out of scope for v1 beyond the banner.

This is the riskiest surface, so it ships behind its own phase and a "download in
browser" fallback if install fails.

### Surfacing (decision: both TUI + Flutter)

- **TUI:** a dismissible status-line/banner row: `⬆ Triage 0.1.6 available
  (you have 0.1.5) — press U to update`. `U` triggers the daemon self-update;
  show progress + a reconnect note. Respect a config opt-out.
- **Flutter:** a Material banner / snackbar with "What's new" link + "Update"
  button. Daemon update and client update are two distinct actions (the daemon
  runs the handover; the app updates its own bundle), so the banner may show one
  or both depending on which is stale.

### Security & safety

- GitHub query is read-only and unauthenticated (public repo); cache + rate-limit
  (one check per N hours; respect `If-None-Match`/ETag). Network failures are
  silent — never block startup.
- Verify downloaded artifacts before executing: pin the GitHub release host,
  check size, and verify a signature/checksum (reuse `prism_release_signing`;
  `sha2`/`hex` already in the workspace).
- Self-update is **opt-in per action** (user presses Update / clicks the button) —
  no silent auto-update. Config flag to disable the check entirely.
- Don't log tokens/URLs with secrets (none expected; public release API).

### Open questions to resolve during implementation

- Exact GitHub endpoint: `GET /repos/hyeons-lab/triage/releases/latest` (ignores
  prereleases) vs `/tags`. Lean on `releases/latest` since assets live there.
- Channel/prerelease policy (stable-only for now).
- Whether `triage` (embedded-daemon default mode) self-updates by re-exec +
  handover against its own embedded daemon, or just instructs a TUI relaunch.
  Lean: headless `triaged` uses handover; `triage` TUI does re-exec relaunch
  (its embedded daemon can hand over to the re-exec'd process the same way).

---

## Plan

### Phase 0 — Release pipeline: attach prebuilt binaries (`publish.yml`)
1. Add per-OS jobs (macOS arm64+x86_64, Linux x86_64, optionally musl, Windows)
   that `cargo build --release -p triaged -p triage` (and `triage-mcp`).
2. Sign/checksum each binary with `prism_release_signing`; emit `.sig`/`.sha256`.
3. Upload as workflow artifacts; extend the `release` job `files:` glob to attach
   `triaged-<os>-<arch>`, `triage-<os>-<arch>` alongside the Flutter clients.
4. Document the asset naming convention (the updater parses it).

### Phase 1 — Update-check service in the daemon
5. New module `crates/triaged/src/update.rs`:
   - `current_version()` from `env!("CARGO_PKG_VERSION")`.
   - `fetch_latest_release()` → GitHub releases API (reuse `hyper`/an http client
     already in deps; add `rustls` if TLS to api.github.com is needed). ETag
     cache, N-hour interval, fully non-blocking, failures swallowed.
   - semver compare → `UpdateStatus { current, latest, update_available,
     assets: Vec<ReleaseAsset> }`.
6. Background poll task spawned at daemon start; store latest `UpdateStatus`
   behind the `SessionManager` (e.g. `Arc<RwLock<UpdateStatus>>`).
7. Config: `[update] check = true`, `interval_hours = 6`, `channel = "stable"`.

### Phase 2 — Surface update status over the session API
8. Schema (`triage.fbs`): add `server_version`, and an `UpdateInfo` table
   (`current`, `latest`, `update_available`, asset descriptors) to `HelloResult`;
   add an `UpdateAvailableEvent` to `SessionEventPayload` for mid-session pushes.
   Regenerate flatbuffers (Rust + Dart `lib/generated`).
9. Populate `HelloResult` in `triage-transport-ws` from the daemon's
   `UpdateStatus`; broadcast `UpdateAvailableEvent` when the poll flips the state.
10. Unit tests: hello reports version + update info; event fires on state change.

### Phase 3 — Daemon self-update via handover
11. Handover protocol-version: add `handover_protocol_version` to `HandoverState`
    (or the wire handshake); new daemon refuses adoption + reports incompatibility
    instead of corrupting state. Fallback path: persist-and-restart.
12. `triaged` self-update command/IPC action `update_now`:
    - resolve target: prebuilt asset for this `<os>-<arch>` → download + verify →
      place at exec path (atomic temp+rename); else `cargo install --force`.
    - spawn `triaged --handover` from the new binary; on success the old process
      exits via the existing 3-phase sync.
    - stream progress/status back to the requesting client.
13. Integration test (Unix): start daemon with a live session → run update against
    a built "newer" binary → assert session survives + version advanced.

### Phase 4 — TUI banner + trigger (`crates/triage`)
14. Read update info from `HelloResult`/event; render a dismissible banner row in
    `draw_sidebar`/status line. Hotkey `U` → invoke `update_now`; show progress,
    reconnect note, and result. Honor `[update] check` opt-out.
15. For `triage` default (embedded daemon) mode: re-exec + handover against its
    own embedded daemon, or relaunch instructions if not feasible.

### Phase 5 — Flutter client banner + in-app install
16. Add `package_info_plus` (read app version) and a download/install service.
17. Banner widget (Material) showing daemon-update and/or client-update actions
    from the parsed `HelloResult`/event.
18. Platform-branched installer service (`kIsWeb`/`Platform.is*`):
    - download matching asset (url from update info), verify size + signature,
    - macOS/Linux/Windows bundle swap via a small relaunch helper,
    - web → "reload" affordance; mobile → banner only (store/TestFlight later),
    - fallback to opening the release page via `url_launcher` on failure.
19. Daemon-update button calls the same `update_now` action; show progress and
    auto-reconnect when the daemon comes back on the same port.

### Phase 6 — Docs, config, tests
20. Document the update model + asset naming in `AGENTS.md`/README; add `[update]`
    to the config doc in the design doc.
21. End-to-end manual checklist: stale daemon → banner in TUI + Flutter → daemon
    self-update keeps sessions → client self-update relaunches.
22. `bump-version.sh` unaffected (still the version source of truth); verify the
    updater's asset-name parser matches the names emitted by Phase 0.

### Sequencing / PR slicing
- PR 1: Phase 0 (release attaches prebuilt binaries) — independently shippable.
- PR 2: Phases 1–2 (daemon check + API surface) — banner data, no actions yet.
- PR 3: Phase 4 TUI banner (read-only "update available", manual instructions).
- PR 4: Phase 3 daemon self-update via handover + wire the TUI `U` action.
- PR 5: Phase 5 Flutter banner + in-app install.
- PR 6: Phase 6 docs/tests cleanup.
