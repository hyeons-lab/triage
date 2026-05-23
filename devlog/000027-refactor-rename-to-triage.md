# refactor/rename-to-triage

## Agent
- Antigravity (Gemini 1.5 Pro) @ triage branch refactor/rename-to-triage

## Intent
- Rename the project from "argus" to "triage", with the daemon named "triaged", to prepare for crates.io publication since the name "argus" is already taken.

## What Changed
- 2026-05-23T14:41-0700 Created git worktree and branch refactor/rename-to-triage.
- 2026-05-23T14:41-0700 Initialized devlog 000027 and plan 000027-01.
- 2026-05-23T14:56-0700 Completed directory renames for crates and Flutter client.
- 2026-05-23T14:56-0700 Updated Cargo.toml packages and dependency declarations in root and crates.
- 2026-05-23T14:56-0700 Refactored all Rust source files for imports, socket files, config directories, log files, thread names, and string markers.
- 2026-05-23T14:56-0700 Refactored all Flutter/Dart app client source code, pubspec configuration, and target manifests.
- 2026-05-23T14:56-0700 Updated workspace conventions (AGENTS.md), README.md, and created triage-design-doc.md.
- 2026-05-23T14:56-0700 Aligned all golden test snapshots under triage-test-support.

## Decisions
- 2026-05-23T14:41-0700 Establish a plan-first renaming architecture across the Rust crates, Flutter packages, documents, thread names, paths, and config names.
- 2026-05-23T14:56-0700 Align all active code, configurations, snapshots, and documentation with the new Triage and triaged branding, while preserving historical logs in their original naming for git integrity.

## Commits
- HEAD — refactor: rename project to triage and daemon to triaged

## Next Steps
- Run `cargo check --workspace`, `cargo clippy --all-targets --all-features`, `cargo test --workspace`, and `cargo fmt --all`.
- Rename the GitHub repository to `hyeons-lab/triage`, update local git remote URL, and push the branch.
- Create a draft pull request on GitHub.
