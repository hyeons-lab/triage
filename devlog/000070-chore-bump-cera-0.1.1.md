# chore/bump-cera-0.1.1

**Agent:** Claude Code (claude-opus-4-8) @ triage branch chore/bump-cera-0.1.1
(worktree: worktrees/bump-cera-0.1.1)

## Intent

Pull triage onto the freshly released `cera` 0.1.1 (carries the sampling-param
additions and updated READMEs). The workspace requirement was the loose
`"0.1"` and the lockfile was still pinned to 0.1.0.

## What Changed

- 2026-06-16T21:34-0700 `Cargo.toml` — `cera` dependency requirement
  `version = "0.1"` → `"0.1.1"`, making the new release floor explicit (the
  `remote` feature is unchanged).
- 2026-06-16T21:34-0700 `Cargo.lock` — `cera` `0.1.0` → `0.1.1`
  (`cargo update -p cera --precise 0.1.1`); checksum updated to the published
  0.1.1 artifact.

## Decisions

- 2026-06-16T21:34-0700 Pinned the requirement to `0.1.1` rather than leaving
  `"0.1"` — the bump's intent is to adopt the new release, and an explicit floor
  documents that triage depends on 0.1.1's additions. Confirmed 0.1.1 is live on
  the crates.io sparse index before updating.

## Issues

- 2026-06-16T21:34-0700 `cargo check -p triaged` builds clean against
  `cera v0.1.1`; no API breakage.

## Commits

- HEAD — chore: bump cera dependency to 0.1.1
