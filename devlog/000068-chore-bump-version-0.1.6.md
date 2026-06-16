# chore/bump-version-0.1.6

**Agent:** Claude Code (claude-opus-4-8) @ triage branch chore/bump-version-0.1.6

## Intent

Bump the triage Rust workspace version from 0.1.5 to 0.1.6 in preparation for a new
release, keeping the Flutter client's displayed version (the native About panel, driven by
`pubspec.yaml`) in lockstep.

The 0.1.6 payload (commits merged since the 0.1.5 bump #70): #72 (force-finalize first-fit
so session history renders on load), #73 (keep terminal scroll position anchored across
scrollback trims), #74 (local-LLM session snippets in the side rail), #75 (side-rail
glance — branch/repo/worktree, hover detail popover, drag reorder).

## What Changed

- 2026-06-16T06:50-0700 `VERSION` — `0.1.5` → `0.1.6` (single source of truth).
- 2026-06-16T06:50-0700 `Cargo.toml` — `[workspace.package].version` and the internal
  `[workspace.dependencies]` pins (`triage-core`, `triage-transport-ws`, `triaged`) bumped
  to `0.1.6`.
- 2026-06-16T06:50-0700 `Cargo.lock` — Refreshed the six workspace crate entries (`triage`,
  `triage-core`, `triage-mcp`, `triage-test-support`, `triage-transport-ws`, `triaged`) to
  `0.1.6` via `cargo update --workspace`; third-party versions untouched.
- 2026-06-16T06:50-0700 `flutter/triage_client/pubspec.yaml` — `version` `0.1.5+1` →
  `0.1.6+1`; the build-name half flows into `CFBundleShortVersionString` for the native
  About panel. Build number kept at `+1`.

All edits produced by `scripts/bump-version.sh 0.1.6`; `scripts/bump-version.sh --check`
(the same check CI runs) reports `OK: all files match VERSION 0.1.6`.

## Decisions

- 2026-06-16T06:50-0700 Used `scripts/bump-version.sh` (introduced in the 0.1.5 bump)
  rather than hand-editing the literals, so `VERSION`, the Cargo workspace, `Cargo.lock`,
  and the Flutter pubspec move in one validated step.

## Next Steps

- After merge, publishing 0.1.6 via the Publish workflow (`dry_run=false`) updates the
  crates.io pages and auto-creates the `v0.1.6` tag + GitHub release with the
  macOS/Windows/Linux Flutter clients attached.

## Commits

- HEAD — chore: bump version to 0.1.6
