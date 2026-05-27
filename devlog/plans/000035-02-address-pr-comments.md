# Plan: Address PR Comments on Dependency Versions

This plan details correcting the version discrepancy in the plan documentation for `tattoy-wezterm-surface` to match the actual applied version (`0.1.0-fork.2`).

## Thinking

In the first plan file, we originally projected using version `0.1.0-fork.5` for both packages. However, since the `tattoy-wezterm-surface` crate only exists up to version `0.1.0-fork.2` on crates.io, we adjusted our implementation to use `0.1.0-fork.2`. The PR reviewer noted that the first plan file still lists `0.1.0-fork.5` as planned.

To maintain the append-only record of our plans, we will:
1. Append a postscript update to the end of the original plan file `devlog/plans/000035-01-use-tattoy-crates.md` to formally note this change.
2. Commit and push the documentation correction.

## Plan

1. Append a "## Update: Applied Version Correction" section to `devlog/plans/000035-01-use-tattoy-crates.md` noting the switch to `0.1.0-fork.2` for `tattoy-wezterm-surface` due to crates.io availability.
2. Verify all files build and check formatting.
