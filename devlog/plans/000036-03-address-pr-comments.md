# Plan: Address Second Round of PR Comments

This plan details addressing the five review comments on PR #43 regarding GitHub Action workflow input escaping, crates.io path dependency rules, build script rerun conditions, and devlog consistency.

## Thinking

We will systematically resolve each of the five comments:

1.  **Workflow Input Rename**:
    *   In `.github/workflows/publish.yml`, rename the `dry-run` input to `dry_run` (using an underscore) and update all references to `${{ github.event.inputs.dry_run }}`. This avoids the GitHub Actions expression subtraction parsing bug (`inputs.dry - run`).
2.  **Crates.io Path Dependencies**:
    *   Crates.io rejects path-only internal dependencies. We must define our internal workspace crates in the root `Cargo.toml` `[workspace.dependencies]` with both version and path:
        ```toml
        triage-core = { version = "0.1.0", path = "crates/triage-core" }
        triage-transport-ws = { version = "0.1.0", path = "crates/triage-transport-ws" }
        triaged = { version = "0.1.0", path = "crates/triaged" }
        ```
    *   Update all crate-level `Cargo.toml` files to inherit them using `triage-core.workspace = true`, etc.
3.  **Build Script Rerun Conditions**:
    *   In `crates/triaged/build.rs`, watch the entire directories `dist` and `../../flutter/triage_client/build/web` rather than just `index.html` files, ensuring that Cargo reruns the build script if any asset file changes.
4.  **Devlog & Plan Consistency**:
    *   Update historical bullet points in `devlog/plans/000036-01-prepare-release.md` and `devlog/000036-chore-prepare-release.md` to remove references to the deleted `documentation` field, keeping the branch history perfectly consistent.

## Plan

1.  **Modify `.github/workflows/publish.yml`**:
    *   Rename `dry-run` input to `dry_run`.
    *   Replace `${{ github.event.inputs.dry-run }}` with `${{ github.event.inputs.dry_run }}`.
2.  **Modify Workspace `Cargo.toml`**:
    *   Add `triage-core`, `triage-transport-ws`, and `triaged` to `[workspace.dependencies]` with version and path.
3.  **Modify Crate Manifests**:
    *   In all sub-crates, change internal path-only dependencies to inherited workspace dependencies.
4.  **Modify `crates/triaged/build.rs`**:
    *   Change `rerun-if-changed` triggers to point to the directories rather than specific `index.html` files.
5.  **Modify Devlogs**:
    *   Align previous text in `000036-01-prepare-release.md` and `000036-chore-prepare-release.md` to reflect the removed documentation field.
6.  **Verify**:
    *   Verify the workspace builds and all tests pass.
