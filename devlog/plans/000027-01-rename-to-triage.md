# 000027-01-rename-to-triage

## Thinking
We need to rename the whole repository structure, packages, imports, configurations, logs, and docs from `argus` to `triage` (with the daemon package/binary named `triaged`).

We must follow a clean sequence of steps:
1. Rename all directories under `crates/` and `flutter/`.
2. Update all Cargo.toml files in the workspace (including the root Cargo.toml and crate-specific Cargo.toml files) with correct package names, paths, repositories, and description texts.
3. Perform search-and-replace for library names (`argus_core` -> `triage_core`, `argus_daemon` -> `triaged`, `argus_tui` -> `triage`, etc.) in the Rust code.
4. Rename runtime constants: config directory (`argus` -> `triage`), log directory (`argus` -> `triage`), log file name (`argus.log` -> `triaged.log`), socket files (`argus.sock` -> `triage.sock`), and thread/IPC component names.
5. Update Flutter package metadata and imports.
6. Rename rule files, guidelines, and devlog/design-docs, replacing text occurrences of `argus` with `triage` or `triaged`.
7. Build the workspace and verify all tests pass.

## Plan

### Phase 1: Directory Renaming
- Rename crate directories:
  - `crates/argus-core` -> `crates/triage-core`
  - `crates/argus-daemon` -> `crates/triaged`
  - `crates/argus-tui` -> `crates/triage`
  - `crates/argus-mcp` -> `crates/triage-mcp`
  - `crates/argus-transport-ws` -> `crates/triage-transport-ws`
  - `crates/argus-test-support` -> `crates/triage-test-support`
- Rename Flutter client directory:
  - `flutter/argus_client` -> `flutter/triage_client`

### Phase 2: Cargo & Dependency Configuration updates
- Update root `Cargo.toml` workspace members list and package repository URL.
- Update each individual crate's `Cargo.toml` with the new package names, workspace dependencies, and file path references.

### Phase 3: Rust Code Search & Replace (Imports and Module references)
- Replace all instances of `argus_core` with `triage_core`.
- Replace all instances of `argus_daemon` with `triaged`.
- Replace all instances of `argus_tui` with `triage`.
- Replace all instances of `argus_transport_ws` with `triage_transport_ws`.
- Replace all instances of `argus_mcp` with `triage_mcp`.
- Replace all instances of `argus_test_support` with `triage_test_support`.

### Phase 4: Runtime constants, paths, and environment refactoring
- In `triage-core` configuration files and logger paths:
  - Change `.config/argus/config.toml` -> `.config/triage/config.toml`
  - Change `.local/state/argus/argus.log` -> `.local/state/triage/triaged.log`
  - Change `argus.sock` -> `triage.sock`
  - Change thread names and log identifiers (e.g. `argus-ipc-client` -> `triage-ipc-client`, etc.)

### Phase 5: Flutter package updates
- In `flutter/triage_client/pubspec.yaml`, change package name to `triage_client`.
- Update Dart imports across all files.

### Phase 6: Documentation and Workspace guidelines
- Update `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `QODER.md`, `.cursorrules`, `.windsurfrules`.
- Rename `devlog/argus-design-doc.md` to `devlog/triage-design-doc.md` and update internal text.
- Rename references in README.md.

### Phase 7: Verification and Build
- Run `cargo fmt --all` to format everything.
- Run `cargo check --workspace` to verify typing.
- Run `cargo clippy --all-targets --all-features -- -D warnings` to verify lints.
- Run `cargo test --workspace` to ensure all tests pass.
