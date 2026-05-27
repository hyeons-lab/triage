# Devlog: Upgrade Flutter Client Transitive Dependencies & Resolve Release Secrets

- **Agent:** Antigravity
- **Intent:** Upgrade outdated transitive dependencies (`matcher`, `meta`, `test_api`, and `vector_math`) in the Flutter client workspace and resolve the crates.io release workflow failure caused by mismatched authentication secrets.

## Intent

Investigate transitive dependency updates in `flutter/triage_client` to address warnings and fix the authentication token issue in the release pipeline to enable crates.io publishing.

## What Changed

- Fixed the release workflow in `.github/workflows/publish.yml` to utilize the correct secret name `secrets.CARGO_REGISTRY_TOKEN` instead of `secrets.CRATES_IO_TOKEN`.
- Investigated the transitive dependencies `matcher`, `meta`, `test_api`, and `vector_math` in the Flutter client.
- Verified that all transitive packages are already at their maximum possible versions compatible with the current Flutter stable SDK `3.44.0` (Dart `3.12.0`) constraints.

## Decisions

- Map the workflow environment variable `CARGO_REGISTRY_TOKEN` directly to the repository secret `secrets.CARGO_REGISTRY_TOKEN` which exists in GitHub.
- Maintain transitive package versions as currently constrained by direct dependencies and SDK pins.

- [x] Fix release workflow authentication secret in `.github/workflows/publish.yml`.
- [x] Investigate transitive dependencies and verify lockfile constraints.
- [x] Run Dart unit tests.
- [x] Run Rust workspace checks and unit tests.

## Commits

- HEAD — chore: fix crates.io workflow registry secret name and verify dependencies

## Research & Discoveries

- The repository secret is explicitly named `CARGO_REGISTRY_TOKEN` rather than `CRATES_IO_TOKEN`, which caused `cargo publish` to fail with `please provide a non-empty token`.
- Direct dependencies like `flutter_test` pin transitive dependencies like `matcher` and `test_api` directly, restricting upgrades to major or minor versions outside the SDK floor.

## Lessons Learned

- Always double check the exact secret naming in repository settings using `gh secret list` when debugging GHA authentication failures.
