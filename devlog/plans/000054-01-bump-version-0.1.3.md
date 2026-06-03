## Thinking

Bump the triage workspace from 0.1.2 to 0.1.3 to ship the changes merged since 0.1.2
(triaged web-server/pairing docs, "Triage" desktop branding) to crates.io and to cut a
GitHub release. crates.io metadata is immutable per published version, so the 0.1.2
description/README updates only reach the crates.io page via a new version. The version
is single-sourced in the root `Cargo.toml` `[workspace.package]`; all crates inherit it.

When 0.1.3 is published (Publish workflow, dry_run=false), the merged release automation
auto-creates the `v0.1.3` tag and a GitHub release with the macOS/Windows/Linux Flutter
clients attached.

## Plan

1. Set `[workspace.package].version` in root `Cargo.toml` from `0.1.2` to `0.1.3`.
2. `cargo update --workspace` to refresh the six workspace crate entries in `Cargo.lock`.
3. Commit devlog + plan + change, push, open PR.
