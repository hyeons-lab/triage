# Plan: bump version to 0.1.5

## Thinking

Bump the triage workspace from 0.1.4 to 0.1.5 to ship the changes merged since 0.1.4 and
cut a tagged GitHub release. The version lives in the root `Cargo.toml`
`[workspace.package]` and is inherited by every crate via `version.workspace = true`; the
internal `[workspace.dependencies]` pins must move in lockstep so the published 0.1.5
metadata is self-consistent.

Separately, the Flutter desktop client's About panel shows `1.0.0` — the Flutter-template
default in `pubspec.yaml` (`version: 1.0.0+1`). macOS maps `CFBundleShortVersionString` to
`$(FLUTTER_BUILD_NAME)`, i.e. the build-name half of the pubspec version. Aligning it to
`0.1.5` makes the client About panel and release assets report the same number as the
crates.

Changes merged since 0.1.4 (the 0.1.5 payload): #65 (Node 24 publish actions), #66 (heal
terminal layout after sleep), #67 (shift-click extend selection), #68 (drag-edge
auto-scroll), #69 (preserve spaces when copying selection).

## Plan

1. Set `[workspace.package].version` in root `Cargo.toml` from `0.1.4` to `0.1.5`.
2. Bump the internal `[workspace.dependencies]` pins (`triage-core`, `triage-transport-ws`,
   `triaged`) from `0.1.4` to `0.1.5`.
3. Refresh the six workspace crate entries in `Cargo.lock` via `cargo update --workspace`.
4. Bump `flutter/triage_client/pubspec.yaml` `version` from `1.0.0+1` to `0.1.5+1`.
5. Verify with `cargo check --workspace --locked`.
6. Commit devlog + plan + Cargo.toml + Cargo.lock + pubspec.yaml together; open PR.
