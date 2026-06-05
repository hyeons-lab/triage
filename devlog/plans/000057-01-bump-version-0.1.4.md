# Plan: bump version to 0.1.4

## Thinking

Bump the triage workspace from 0.1.3 to 0.1.4 to ship the changes merged since 0.1.3
to crates.io and cut a tagged GitHub release. crates.io metadata is immutable per
published version, so the changes since 0.1.3 only reach users via a new version. The
version lives in the root `Cargo.toml` `[workspace.package]` and is inherited by every
crate via `version.workspace = true`; the internal `[workspace.dependencies]` pins must
move in lockstep so the published 0.1.4 metadata is self-consistent (each crate declares
`^0.1.4` on its internal deps, not a stale lower bound).

Changes merged since 0.1.3 (the 0.1.4 payload):
- #62 ci(publish): strip get-task-allow from the macOS client to fix Keychain prompts.
- #63 Fix terminal corruption: unidirectional MVI raw-byte terminal pipeline (host
  raw-output history + Flutter MVI client), JetBrains Mono bundling, Flutter 3.44.1.

When 0.1.4 is published (Publish workflow, `dry_run=false`), the merged release automation
auto-creates the `v0.1.4` tag and a GitHub release with the macOS/Windows/Linux Flutter
clients attached.

## Plan

1. Set `[workspace.package].version` in root `Cargo.toml` from `0.1.3` to `0.1.4`.
2. Bump the internal `[workspace.dependencies]` pins (`triage-core`, `triage-transport-ws`,
   `triaged`) from `0.1.3` to `0.1.4`.
3. Refresh the six workspace crate entries in `Cargo.lock` via `cargo update --workspace`
   (third-party dependency versions untouched).
4. Verify with `cargo check --workspace --locked`.
5. Commit devlog + plan + Cargo.toml + Cargo.lock together; open PR.
