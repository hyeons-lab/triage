# Plan: Upgrade Flutter Client Transitive Dependencies & Resolve Release Secrets

This plan details investigating the transitive dependency upgrades in the Flutter client workspace and correcting the repository secret mismatch in `.github/workflows/publish.yml`.

## Thinking

We need to resolve both the publish pipeline failure and check for transitive dependency updates:
1.  **Workflow Secret Fix**:
    *   The manual dispatch crates.io publish run failed with `please provide a non-empty token`.
    *   Inspecting repository secrets reveals that the secret is named `CARGO_REGISTRY_TOKEN`, but `.github/workflows/publish.yml` referred to `secrets.CRATES_IO_TOKEN`.
    *   Changing the secret reference to `${{ secrets.CARGO_REGISTRY_TOKEN }}` will restore the authentication chain.
2.  **Transitive Dependency Upgrades**:
    *   Run `flutter pub upgrade` and `flutter pub outdated` to check if `matcher`, `meta`, `test_api`, and `vector_math` can be upgraded under current dependency constraints and Flutter stable SDK `3.44.0` limits.
    *   Verify the workspace with unit tests to ensure no regressions occur.

## Plan

1.  **Modify `.github/workflows/publish.yml`**:
    *   Change the environment secret reference on line 71 to use `secrets.CARGO_REGISTRY_TOKEN`.
2.  **Upgrade and Outdated Checks**:
    *   Run `flutter pub upgrade` and `flutter pub outdated` in `flutter/triage_client`.
    *   Verify package constraints and log findings.
3.  **Run All Tests**:
    *   Execute `flutter test` in `flutter/triage_client` to verify client tests pass.
    *   Execute `cargo test --workspace` in the workspace to verify all Rust tests pass.
