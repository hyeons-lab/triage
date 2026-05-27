# Plan: Prepare Workspace for Crates.io Release

This plan details configuring workspace packaging metadata, inheriting it across all public crates, and authoring premium landing documentation for crates.io pages.

## Thinking

To prepare Triage for crates.io release, we need to populate complete, valid metadata so that each published crate is correctly categorised and documented.

Our steps are:
1.  **Configure Root `Cargo.toml`**:
    *   Set `version` to `"0.1.0"`.
    *   Add `homepage = "https://github.com/hyeons-lab/triage"`.
    *   Add `keywords = ["terminal", "pty", "supervisor", "ratatui", "mcp"]`.
    *   Add `categories = ["command-line-utilities", "development-tools"]`.
2.  **Inherit and Reference in Sub-Crates**:
    *   In `crates/triage-core/Cargo.toml`, `crates/triage-transport-ws/Cargo.toml`, `crates/triaged/Cargo.toml`, `crates/triage-mcp/Cargo.toml`, and `crates/triage/Cargo.toml`:
        *   Inherit `homepage`, `keywords`, and `categories` from the workspace.
        *   Define `readme = "README.md"` pointing to a local file in their directories.
3.  **Author Individual READMEs**:
    *   Create a clean, descriptive `README.md` file in each crate directory:
        *   `crates/triage-core/README.md`
        *   `crates/triage-transport-ws/README.md`
        *   `crates/triaged/README.md`
        *   `crates/triage-mcp/README.md`
        *   `crates/triage/README.md`
4.  **Verification**:
    *   Run `cargo check --workspace` to ensure manifests are valid.
    *   Run `cargo fmt` and verify all tests pass.

## Plan

1.  **Modify Workspace `Cargo.toml`**:
    *   Update `version` under `[workspace.package]` to `"0.1.0"`.
    *   Add `homepage`, `keywords`, and `categories`.
2.  **Modify Crate manifests**:
    *   Append inherited properties and add `readme = "README.md"` to each public crate manifest.
3.  **Create Crate READMEs**:
    *   Write concise, professional documentation for each crate detailing its purpose, installation, and integration instructions.
4.  **Verify**:
    *   Type-check the workspace using `cargo check --workspace`.
    *   Verify with a dry-run publish validation: `cargo publish --dry-run` on each crate in order.

## Update: Address PR Comments on Documentation URLs (2026-05-26)

Following PR review comments, the shared `documentation` URL inheritance has been removed from all package manifests to let crates.io naturally infer separate docs.rs links for every crate.
