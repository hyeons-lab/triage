# chore/bump-version-0.1.3

## Agent
- 2026-06-02T22:43-0700 — Claude Code (claude-opus-4-8) @ triage branch chore/bump-version-0.1.3 — Bumped the triage workspace version to 0.1.3.

## Intent
- Bump the triage Rust workspace version from 0.1.2 to 0.1.3 so a publish ships the changes merged since 0.1.2 (triaged web-server/pairing docs, "Triage" desktop branding) to crates.io and cuts a tagged GitHub release with the desktop clients attached.

## What Changed
- 2026-06-02T22:43-0700 `Cargo.toml` — Set `[workspace.package].version` to `0.1.3` (inherited by all crates via `version.workspace = true`).
- 2026-06-02T22:43-0700 `Cargo.lock` — Refreshed the six workspace crate entries (triage, triage-core, triage-mcp, triage-test-support, triage-transport-ws, triaged) to 0.1.3 via `cargo update --workspace`; third-party dependency versions untouched.

## Decisions
- 2026-06-02T22:43-0700 Use `cargo update --workspace` rather than hand-editing `Cargo.lock` — it updates only the workspace members and keeps the lockfile internally consistent.

## Notes
- 2026-06-02T22:43-0700 After merge, publishing 0.1.3 via the Publish workflow (`dry_run=false`) updates the crates.io page (immutable per version) and, via the merged release automation, auto-creates the `v0.1.3` tag + GitHub release with the macOS/Windows/Linux Flutter clients attached.

## Commits
- HEAD — chore: bump version to 0.1.3
