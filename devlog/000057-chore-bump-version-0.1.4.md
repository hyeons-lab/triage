# chore/bump-version-0.1.4

**Agent:** Claude Code (claude-opus-4-8) @ triage branch chore/bump-version-0.1.4

## Intent

Bump the triage Rust workspace version from 0.1.3 to 0.1.4 so a publish ships the changes
merged since 0.1.3 to crates.io and cuts a tagged GitHub release with the desktop clients
attached. The 0.1.4 payload: #62 (strip get-task-allow from the macOS client to fix
Keychain prompts) and #63 (unidirectional MVI raw-byte terminal pipeline + JetBrains Mono
+ Flutter 3.44.1).

## What Changed

- 2026-06-05T07:00-0700 `Cargo.toml` — Set `[workspace.package].version` to `0.1.4`
  (inherited by all crates via `version.workspace = true`).
- 2026-06-05T07:00-0700 `Cargo.toml` `[workspace.dependencies]` — Bumped the internal crate
  version pins (`triage-core`, `triage-transport-ws`, `triaged`) from `0.1.3` to `0.1.4`,
  so the published 0.1.4 metadata is self-consistent (each crate declares `^0.1.4` on its
  internal deps).
- 2026-06-05T07:00-0700 `Cargo.lock` — Refreshed the six workspace crate entries (triage,
  triage-core, triage-mcp, triage-test-support, triage-transport-ws, triaged) to 0.1.4 via
  `cargo update --workspace`; third-party dependency versions untouched.

## Decisions

- 2026-06-05T07:00-0700 Move the `[workspace.dependencies]` internal pins in lockstep with
  the package version — reasoning: a published crate would otherwise declare a stale
  internal-dependency requirement that doesn't match the release (the same alignment fix
  done in PR #61 for 0.1.3).

## Next Steps

- After merge, publishing 0.1.4 via the Publish workflow (`dry_run=false`) updates the
  crates.io pages and, via the merged release automation, auto-creates the `v0.1.4` tag +
  GitHub release with the macOS/Windows/Linux Flutter clients attached.

## Commits

- HEAD — chore: bump version to 0.1.4
