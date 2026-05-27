# Devlog: Fix Publish Dry Run

## Agent
Antigravity (Gemini 3.5 Flash)

## Intent
Resolve the crates.io release publication dry-run failure by updating the Flutter SDK setup configuration, pinning dependencies, and optimizing the publish workflow dry-run step.

## Progress
- [x] Fix publish workflow Flutter version and dry-run package commands.
- [x] Configure daemon package Cargo.toml include paths.
- [x] Pin client Flutter SDK environment requirements.

## Decisions
- Update Flutter SDK setup version in `publish.yml` to `'3.44.0'` to match the actual Flutter release version floor.
- Avoid using `cargo publish --dry-run` in the workflow dry-run step for internal workspace dependencies, and instead use manual `cargo package` checks with path overrides.
- Exclude CanvasKit runtime assets in `triaged/Cargo.toml` to ensure the packed crate size stays comfortably below crates.io's 10 MiB limit.

## Commits
- HEAD — chore: fix crates.io publish dry-run workflow and SDK requirements
