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

---

## Revisions (from critical review, 2026-06-11)

This section supersedes the phases it names. The original plan above is kept for
history; where they conflict, the revisions win. A code-grounded review surfaced
that the plan systematically under-weighted failure modes and that two of its
assumptions are false against the current codebase. Findings, then the revised
phasing.

### Findings that change the design

- **F1 — A failed handover loses every live session; there is no rollback.** In
  the 3-phase sync the old daemon tears down its readers on the successor's
  adopt signal (`0x01`), *before* the successor proves it can serve. If the new
  binary panics/misconfigures/links wrong after adopting FDs, the PTYs are
  orphaned in a dead process. Acceptable for a rare manual `--handover`;
  unacceptable for a routine auto-update button. **An updater whose failure mode
  is "lose all your work" is not shippable.** Requires a health-gated, abortable
  pre-flight before the point of no return.
- **F2 — The "persist-and-restart" fallback also kills sessions.** Phase 8
  persistence restores metadata + scrollback only; shell recreation is unbuilt
  and arbitrary programs are never resurrected. So the incompatible-handover
  fallback terminates every live shell/agent. It must be an explicit user
  confirmation ("this update will end your running sessions — proceed?"), never
  silent.
- **F3 — macOS in-app install is likely infeasible with current signing.** The
  release is ad-hoc signed; downloaded bundles get `com.apple.quarantine` and a
  self-swapped relaunch hits Gatekeeper. Seamless install needs Developer ID +
  notarization (absent today). Demote to browser-download default; gate in-app
  install on a future signing/notarization prerequisite. Same class on Windows
  (SmartScreen).
- **F4 — The update event is at the wrong protocol layer (confirmed in schema).**
  Events are entirely session-subscription-scoped (`EventPayload.subscription_id`);
  there is no connection-level server push. A daemon-global update notice must be
  a **new connection-level `ServerMessagePayload` variant** (e.g. `ServerNotice`),
  not an entry in `SessionEventPayload`.
- **F5 — There is no outbound HTTP/TLS client (confirmed in Cargo.toml).**
  `triaged` has `hyper` with `server`+`http1` only; the workspace has no
  `reqwest`/`rustls`/`ureq`. Polling `api.github.com` adds a full outbound TLS
  stack + a mandatory `User-Agent`. Cheaper alternative for the *version* check:
  `git ls-remote --tags` over the git protocol (no API limit, no TLS client);
  only **asset download URLs** actually need the releases API.
- **F6 — The handover-versioning migration is itself the breaking moment.**
  `HandoverState` has no version field and uses plain `serde_json`. The first
  version that adds `handover_protocol_version` must treat "field absent" as
  "legacy/compatible" by construction; 0.1.5 can never be taught anything
  retroactively.
- **F7 — Signing is a subsystem, not a bullet.** Scheme undecided (prefer
  **minisign/ed25519** over GPG — trivial Dart-side verification vs GPG's poor
  Dart support). Keys are currently loose untracked files and must become CI
  secrets; `private-key.asc` in the repo root is a latent leak to remove
  regardless. Public key pinned at compile time → plan a rotation story.
- **F8 — Successor daemonization + supervisor conflict.** The successor is
  spawned as a child of the dying daemon and must `setsid`/detach/redirect stdio.
  No launchd/systemd units ship today, but a supervised daemon would fight
  handover-self-update (supervisor restarts the dead pid; port already held).
  Document "if supervised, let the supervisor restart."
- **F9 — Misc:** Linux glibc-vs-musl and macOS universal-vs-arch download
  matching (silent footgun); state the daemon/client skew compat policy
  explicitly (flatbuffers added-field forward-compat covers `HelloResult`); pick
  the TUI update key against the reserved `g w`/`g a`/`g r` namespace; the Phase 3
  two-binary handover integration test is a real test-infra effort; multi-OS/arch
  Rust release builds materially grow CI minutes.

### Revised guiding principle

Ship value cheaply and safely first; gate the two high-risk capabilities
(handover auto-update, in-app install) behind explicit prerequisites. Most of the
value is the banner + a correct manual path; almost all the risk is in the
seamless paths.

### Revised phasing

**Phase 0 — Release: prebuilt binaries + signing (split).**
- 0a: build + attach prebuilt `triaged`/`triage` (+`triage-mcp`) per OS/arch,
  documenting the asset-name convention. Address glibc/musl + macOS universal.
- 0b (**prerequisite for any download-install**): signing infrastructure —
  minisign keys as CI secrets, `.minisig` per asset, remove loose key files from
  the working tree, decide key-pinning/rotation. Until 0b lands, download paths
  verify checksums only and the daemon self-update prefers `cargo install`.

**Phase 1 — Update check (revised per F5).** Default the *version* check to
`git ls-remote --tags` (no new TLS dep). Add an outbound TLS client *only* when
asset URLs are needed for download, and isolate it behind a feature/module. ETag
where applicable, N-hour interval, `User-Agent`, non-blocking, failures swallowed.

**Phase 2 — Surface (revised per F4).** Add `server_version` + `UpdateInfo` to
`HelloResult`, and a new connection-level `ServerNotice` variant on
`ServerMessagePayload` for mid-session pushes — *not* `SessionEventPayload`.
State the skew compat policy in the PR.

**Phase 3 — Daemon self-update via health-gated, abortable handover (rewritten;
supersedes original Phase 3; addresses F1, F2, F6, F8).**
1. Pre-flight: place the new binary, then spawn it in a **probe mode** that binds
   a throwaway socket and self-checks *without* requesting FD adoption. Only on a
   healthy probe does the real `--handover` proceed. If the probe fails, abort —
   the running daemon never tore anything down; report the error.
2. Add `handover_protocol_version` to the handover handshake with the F6 migration
   rule (absent ⇒ legacy/compatible). On mismatch, **do not** silently fall back —
   return "incompatible; updating will end live sessions" and require explicit
   user confirmation (F2) before any persist-and-restart.
3. Rollback intent: structure the sync so that until the successor confirms it is
   serving, the old daemon can still resume. (Full crash-after-adopt recovery is
   bounded by the existing protocol; document the residual risk window honestly.)
4. Daemonize the successor (`setsid`/detach/stdio) so it survives the parent's
   exit (F8). Detect supervised launch and defer to the supervisor instead.
5. `update_now` IPC action streams progress; binary acquisition = verified
   prebuilt download (checksum now, signature after 0b) else `cargo install
   --force`, placed at `current_exe()` via temp+rename, failing closed if the
   exec path is not writable.
6. Tests: probe-fail aborts with sessions intact; incompatible-version path
   requires confirmation; happy path preserves a live session across the swap.

**Phase 4 — TUI banner (unchanged), plus:** the `U`-equivalent action routes
through the Phase 3 pre-flight; show the explicit session-loss confirmation when
the path is the killing fallback. Pick the key against the reserved namespace.

**Phase 5 — Flutter (revised per F3).** Banner + **browser-download as the
default** ("Update" opens the matching release asset/page via `url_launcher`).
In-app download + install + relaunch is a **later sub-phase gated on Phase 0b
notarization**; until then it is opt-in/experimental with the browser fallback
always available. Web → reload affordance; mobile → banner only.

**Phase 6 — Docs/tests (unchanged), plus:** document the skew compat policy, the
supervised-daemon guidance, and the residual crash-window risk of in-place
upgrade.

### Revised PR slicing
- PR 1: Phase 0a (prebuilt binaries, checksums) — independently shippable.
- PR 2: Phases 1–2 (check via `ls-remote` + `HelloResult`/`ServerNotice`).
- PR 3: Phase 4 read-only TUI banner.
- PR 4: Phase 0b signing + Phase 3 health-gated handover self-update.
- PR 5: Phase 5 Flutter banner + browser-download (in-app install deferred).
- PR 6: docs/tests; in-app install only after notarization exists.
