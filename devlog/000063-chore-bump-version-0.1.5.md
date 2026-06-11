# chore/bump-version-0.1.5

**Agent:** Claude Code (claude-opus-4-8) @ triage branch chore/bump-version-0.1.5

## Intent

Bump the triage Rust workspace version from 0.1.4 to 0.1.5 in preparation for a new
release, and align the Flutter client's displayed version (the native About panel, driven
by `pubspec.yaml`) so it matches the release version instead of the placeholder `1.0.0`.

The 0.1.5 payload (commits merged since the 0.1.4 bump #64): #65 (Node 24 publish
actions), #66 (heal terminal layout after sleep), #67 (shift-click extend selection),
#68 (drag-edge auto-scroll for selection), #69 (preserve spaces when copying selection),
#71 (restore terminal input focus after resume from sleep).

## What Changed

- 2026-06-10T10:36-0700 `Cargo.toml` — Set `[workspace.package].version` to `0.1.5`
  (inherited by all crates via `version.workspace = true`).
- 2026-06-10T10:36-0700 `Cargo.toml` `[workspace.dependencies]` — Bumped the internal crate
  pins (`triage-core`, `triage-transport-ws`, `triaged`) from `0.1.4` to `0.1.5` so the
  published 0.1.5 metadata is self-consistent.
- 2026-06-10T10:36-0700 `Cargo.lock` — Refreshed the six workspace crate entries to 0.1.5
  via `cargo update --workspace`; third-party versions untouched.
- 2026-06-10T10:36-0700 `flutter/triage_client/pubspec.yaml` — Bumped `version` from
  `1.0.0+1` to `0.1.5+1`. The build-name half flows into `CFBundleShortVersionString`
  (`$(FLUTTER_BUILD_NAME)` in `macos/Runner/Info.plist`), which is what the native
  "About Triage" panel displays — previously stuck at the Flutter-template default `1.0.0`.
- 2026-06-10T11:06-0700 `VERSION` (new) — Single source-of-truth file holding the bare
  version string (`0.1.5`).
- 2026-06-10T11:06-0700 `scripts/bump-version.sh` (new) — Propagates `VERSION` to
  `Cargo.toml` (`[workspace.package].version` + internal `[workspace.dependencies]` pins),
  refreshes `Cargo.lock` via `cargo update --workspace`, and updates the Flutter
  `pubspec.yaml` build name (preserving the `+N` build suffix). Supports `<X.Y.Z>` to set,
  no-arg to re-sync, `--check` for CI drift detection, and validates semver. Uses portable
  `perl -i` edits (works on both BSD/macOS and GNU/Linux).
- 2026-06-10T11:06-0700 `AGENTS.md` — Added a "Versioning and releases" section documenting
  the `VERSION` + script flow and the rule to never hand-edit version literals.
- 2026-06-10T11:55-0700 `.github/workflows/ci.yml` — Added a "Check version consistency"
  step (`scripts/bump-version.sh --check`) to the `check` job, right after checkout so it
  fails fast. Runs before the Rust toolchain install because `--check` only reads files via
  `perl` and never invokes cargo.

## Decisions

- 2026-06-10T10:36-0700 Move the `[workspace.dependencies]` internal pins in lockstep with
  the package version — a published crate would otherwise declare a stale internal-dep
  requirement that doesn't match the release (same alignment done for 0.1.3 and 0.1.4).
- 2026-06-10T10:36-0700 Set the Flutter build name to the same `0.1.5` rather than keeping
  a parallel `1.x` track — the desktop clients ship as part of the triage release, so a
  single shared version number is least surprising in the About panel and release assets.
  Kept the build number at `+1`.
- 2026-06-10T11:06-0700 Keep `VERSION` as a plain bare-string file (not embedded in a
  config) and a thin shell script over the existing files, rather than adopting
  `cargo release`/`cargo set-version` — the latter only covers the Rust side and would add
  a tool dependency, whereas one script also keeps the Flutter `pubspec.yaml` in lockstep
  and runs with no extra installs. The release workflow is unchanged: it still derives the
  tag from `cargo metadata`, which the script keeps equal to `VERSION`.

## Issues

- 2026-06-10T17:51-0700 Rebased this branch onto `origin/main` after PR #71 (restore
  terminal input focus after resume) merged ahead of it, so 0.1.5 now ships #71 too. Added
  #71 to the payload list (Intent + commit body) and refreshed the Commits section hashes,
  which the rebase rewrote.

## Research & Discoveries

- 2026-06-10T10:36-0700 The Rust crates do **not** hardcode versions: each crate's
  `Cargo.toml` uses `version.workspace = true`, so the single source of truth is
  `[workspace.package].version`. The only repeated literals are the three internal
  dependency pins under `[workspace.dependencies]` — Cargo has no `version.workspace`
  inheritance for the dependency-requirement side, and crates.io publishing requires an
  explicit version requirement on path deps, so those three literals are structurally
  required, not accidental duplication.
- 2026-06-10T10:36-0700 The Flutter client has no version string in the Dart UI; the
  displayed version is purely the native bundle version derived from `pubspec.yaml`.

## Next Steps

- After merge, publishing 0.1.5 via the Publish workflow (`dry_run=false`) updates the
  crates.io pages and auto-creates the `v0.1.5` tag + GitHub release with the
  macOS/Windows/Linux Flutter clients attached.
- Done in this PR: `VERSION` + `scripts/bump-version.sh` consolidate the Rust workspace
  version and the Flutter `pubspec.yaml` build name behind one command; CI's `check` job
  runs `--check` to fail on version drift.

## Commits

- 901b816 — chore: bump version to 0.1.5
- 60786a2 — chore: add VERSION file and bump-version script
- HEAD — ci: check version consistency on every build
