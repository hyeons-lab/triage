# 000044 chore/bump-triage-0.1.1

## Agent

Codex

## Intent

Bump the Rust Triage workspace packages from `0.1.0` to `0.1.1`.

## Progress

- 2026-05-28T23:42-0700 - Created a dedicated version-bump worktree and confirmed the release version is centralized in the Cargo workspace metadata and internal workspace dependency declarations.
- 2026-05-29T00:11-0700 - Bumped the Rust workspace package version and internal dependency pins to `0.1.1`, refreshed matching lockfile package entries, and validated with Cargo.

## What Changed

- Updated `[workspace.package]` from `0.1.0` to `0.1.1`.
- Updated internal workspace dependency version pins for `triage-core`, `triage-transport-ws`, and `triaged` to `0.1.1`.
- Updated `Cargo.lock` entries for the local Triage workspace crates to `0.1.1`.

## Decisions

- Left the Flutter `triage_client` app version unchanged because it is independent app metadata and not part of the Cargo crate release version.

## Next Steps

- Commit and open a PR when ready.

## Commits

- HEAD - chore: bump triage workspace to 0.1.1
