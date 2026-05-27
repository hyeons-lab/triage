# Plan: Migrate to Tattoy Crate Dependencies

This plan details the migration of WezTerm dependencies from Git to published `tattoy` packages to enable crates.io publishing compatibility.

## Thinking

To publish our crates to crates.io, we cannot have any git dependencies. Since `wezterm-term` and `wezterm-surface` are git dependencies, we must replace them with published equivalents. The community-maintained `tattoy-wezterm-term` and `tattoy-wezterm-surface` crates are direct packaging forks of WezTerm's terminal components on crates.io and can serve as direct drop-in replacements.

Our tasks are:
1. Update `Cargo.toml` in the workspace root to define the `tattoy-wezterm-term` and `tattoy-wezterm-surface` dependencies.
2. Update crate-level `Cargo.toml` references to use the new names.
3. Update source file `use` statements, replacing references to `wezterm_term` and `wezterm_surface` with `tattoy_wezterm_term` and `tattoy_wezterm_surface` respectively.
4. Run `cargo check --workspace` and `cargo test --workspace` to verify type-checking and tests pass.

## Plan

1.  **Modify Workspace `Cargo.toml`**:
    *   Remove `wezterm-term` and `wezterm-surface` Git-based dependencies.
    *   Add `tattoy-wezterm-term = "0.1.0-fork.5"` and `tattoy-wezterm-surface = "0.1.0-fork.5"` to `[workspace.dependencies]`.
2.  **Modify Crate `Cargo.toml` files**:
    *   In `crates/triaged/Cargo.toml`, replace `wezterm-term.workspace = true` and `wezterm-surface.workspace = true` with `tattoy-wezterm-term.workspace = true` and `tattoy-wezterm-surface.workspace = true`.
    *   In `crates/triage-test-support/Cargo.toml`, replace `wezterm-term` references.
3.  **Refactor Source Files**:
    *   In `crates/triaged/src/session.rs`, find and replace `wezterm_term` with `tattoy_wezterm_term`, and `wezterm_surface` with `tattoy_wezterm_surface`.
    *   In `crates/triage-test-support/tests/wezterm_engine_spike.rs`, find and replace `wezterm_term` with `tattoy_wezterm_term`.
4.  **Verification**:
    *   Run `cargo check --workspace` to ensure compiling works.
    *   Run `cargo test --workspace` to ensure all unit and integration tests pass.
