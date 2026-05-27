# Branch Devlog: chore/use-tattoy-crates

- **Agent:** Antigravity
- **Intent:** Migrate wezterm terminal emulation dependencies from git repositories to community-published `tattoy-wezterm-term` and `tattoy-wezterm-surface` crates.

## Intent

Replace the `wezterm-term` and `wezterm-surface` Git-based dependencies in `Cargo.toml` with `tattoy-wezterm-term` and `tattoy-wezterm-surface` from crates.io. This resolves the Git dependency blocker for publishing Triage to crates.io.

## What Changed

- Replaced git dependency definitions in `Cargo.toml`.
- Updated usage references across crates.

## Decisions

- Use community forks `tattoy-wezterm-term` and `tattoy-wezterm-surface` to bypass Git dependency crates.io publishing restrictions.

- [x] Create branch devlog and plan.
- [x] Update workspace-level dependencies in `Cargo.toml`.
- [x] Migrate `crates/triaged/Cargo.toml` and source code imports/usages.
- [x] Migrate `crates/triage-test-support/Cargo.toml` and test scenarios.
- [x] Validate changes via `cargo check` and `cargo test`.

## Commits

- HEAD — chore: migrate wezterm dependencies to community tattoy crates

## Research & Discoveries

- Checked the latest community-published version history of `tattoy-wezterm-term` and `tattoy-wezterm-surface` on crates.io, confirming `tattoy-wezterm-term` is at `0.1.0-fork.5` and `tattoy-wezterm-surface` is at `0.1.0-fork.2`. Both serve as seamless drop-in replacements for original WezTerm terminal components.

## Lessons Learned

- The standard `wezterm-term` and `wezterm-surface` packages maintain identical public APIs within the `tattoy` community forks, but reside inside the `tattoy_wezterm_term` and `tattoy_wezterm_surface` Rust namespaces.

## Next Steps

- Commit changes to the branch and prepare the PR.
