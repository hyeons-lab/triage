# Plan: bump version to 0.1.6

## Thinking

Bump the triage workspace from 0.1.5 to 0.1.6 to ship the changes merged since 0.1.5 and
cut a tagged GitHub release. Since 0.1.5, a single source-of-truth `VERSION` file plus
`scripts/bump-version.sh` handle propagation: the script writes `VERSION`, the root
`Cargo.toml` `[workspace.package].version` (inherited by every crate via
`version.workspace = true`), the internal `[workspace.dependencies]` pins
(`triage-core`, `triage-transport-ws`, `triaged`), refreshes the workspace entries in
`Cargo.lock` via `cargo update --workspace`, and the Flutter `pubspec.yaml` build name
(preserving the `+N` suffix). So this bump is a single command rather than a manual
multi-file edit.

Changes merged since 0.1.5 (the 0.1.6 payload): #72 (force-finalize first-fit so session
history renders on load), #73 (keep terminal scroll anchored across scrollback trims),
#74 (local-LLM session snippets in the side rail), #75 (side-rail glance —
branch/repo/worktree, hover detail popover, drag reorder).

## Plan

1. Run `scripts/bump-version.sh 0.1.6` to set the version across `VERSION`, `Cargo.toml`
   (`[workspace.package].version` + internal `[workspace.dependencies]` pins), `Cargo.lock`
   (workspace entries via `cargo update --workspace`), and the Flutter `pubspec.yaml`
   build name.
2. Verify with `scripts/bump-version.sh --check` (the same check CI runs).
3. Commit devlog + plan + Cargo.toml + Cargo.lock + VERSION + pubspec.yaml together; open
   PR.
