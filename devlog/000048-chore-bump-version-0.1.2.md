# chore/bump-version-0.1.2

## Agent
- 2026-06-02T18:17-0700 — Claude Code (claude-opus-4-8) @ argus branch chore/bump-version-0.1.2 — Bumped the triage workspace version to 0.1.2.

## Intent
- Bump the triage Rust workspace version from 0.1.1 to 0.1.2.

## What Changed
- 2026-06-02T18:17-0700 `Cargo.toml` — Set `[workspace.package].version` to `0.1.2` (inherited by all crates via `version.workspace = true`).
- 2026-06-02T18:17-0700 `Cargo.lock` — Refreshed the six workspace crate entries (triage, triage-core, triage-mcp, triage-test-support, triage-transport-ws, triaged) to 0.1.2 via `cargo update --workspace`; third-party dependency versions untouched.

## Decisions
- 2026-06-02T18:17-0700 Use `cargo update --workspace` rather than hand-editing `Cargo.lock` — it updates only the workspace members and keeps the lockfile internally consistent.

## Commits
- HEAD — chore: bump version to 0.1.2
