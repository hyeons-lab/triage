# Plan 000079-01 — prebuilt release binaries (self-update Phase 0)

## Thinking

Self-update wants to prefer downloading a prebuilt binary over `cargo install
--force`. That requires releases to actually carry `triaged`/`triage` binaries —
they don't today. `publish.yml` already builds the Flutter clients per-OS and a
`release` job attaches `release-assets/**/Triage-*` to the GitHub release.

The cross-platform Rust build is low-risk: `setup-flatc` is already cross-platform
(pwsh) and `ci.yml` already runs `cargo test --workspace` on ubuntu/macos/windows.
The only new work is staging web assets (so the daemon embeds the UI), packaging,
and uploading — and naming the archives to match the existing `Triage-*` glob.

Build web assets once (publish job) and share via an artifact, rather than
rebuilding Flutter on three runners.

## Plan

1. `publish` job: upload `crates/triaged/dist` as a `web-assets` artifact after
   staging.
2. New `build-cli` matrix job (macos/windows/ubuntu): Rust nightly + cache +
   flatc → download `web-assets` into `crates/triaged/dist` → `cargo build
   --release --locked -p triaged -p triage -p triage-mcp` → package
   `Triage-cli-<os>-v<version>.{tar.gz,zip}` → upload artifact.
3. `release` job: add `build-cli` to `needs` (the `Triage-*` glob already
   attaches the new archives).
4. README: document the prebuilt binaries.
5. Validate locally (build + package + actionlint), since a real release can't be
   dry-run in isolation.
