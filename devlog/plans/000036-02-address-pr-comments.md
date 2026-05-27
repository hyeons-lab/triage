# Plan: Resolve Documentation URL Inheritance in Cargo Manifests

This plan details the removal of the shared `documentation` workspace property from package manifests so that crates.io can automatically and correctly infer individual crate documentation links to their respective `docs.rs/<crate-name>` pages.

## Thinking

All 5 review comments on PR #43 point out that inheriting `documentation.workspace = true` causes all published crates (`triage`, `triaged`, `triage-mcp`, `triage-transport-ws`, and `triage-core`) to point their crates.io "Documentation" link to the shared workspace documentation URL (`https://docs.rs/triage-core`). 

To resolve this issue cleanly, we will remove the `documentation` field entirely from the root manifest and all sub-crate manifests. Crates.io will then automatically generate correct, separate documentation URLs pointing to their respective `docs.rs/<crate-name>` pages.

## Plan

1.  **Modify Workspace `Cargo.toml`**:
    *   Remove `documentation = "https://docs.rs/triage-core"` from `[workspace.package]`.
2.  **Modify Crate Manifests**:
    *   Remove `documentation.workspace = true` from all five crate `Cargo.toml` manifests.
3.  **Verification**:
    *   Run `cargo check --workspace` to ensure manifests are valid.
    *   Commit changes to the branch and push.
    *   Reply to all GitHub review comment threads.
