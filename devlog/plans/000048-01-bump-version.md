## Thinking

The triage Rust workspace version is single-sourced in the root `Cargo.toml`
under `[workspace.package]`; every crate inherits it via `version.workspace = true`.
No Rust source hardcodes the version (code uses `CARGO_PKG_VERSION`), and there is
no CHANGELOG. So the bump is two files: the workspace version and the six
workspace-crate entries in `Cargo.lock`.

## Plan

1. Set `[workspace.package].version` in root `Cargo.toml` from `0.1.1` to `0.1.2`.
2. Run `cargo update --workspace` to refresh only the six triage crate entries in
   `Cargo.lock` (leaving third-party deps untouched).
3. Commit devlog + plan + change, push, open PR.
