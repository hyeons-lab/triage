# 000079 — ci/release-rust-binaries

**Agent:** Claude (claude-opus-4-8) @ triage branch ci/release-rust-binaries

## Intent

Phase 0 of the self-update epic: attach prebuilt `triaged` / `triage` /
`triage-mcp` binaries to every GitHub release, so self-update (and plain
installs) can prefer a download over `cargo install --force`. Today `publish.yml`
publishes the crates to crates.io and builds the three Flutter desktop clients,
but ships no prebuilt Rust binaries.

## Decisions

- 2026-06-18T23:55-07:00 New `build-cli` matrix job (macos/windows/ubuntu) rather
  than bolting binary builds onto the existing `build-<os>` client jobs — keeps
  the Flutter client build and the Rust binary build independent, and the build
  mirrors what `ci.yml` already runs on all three OSes (so it's low-risk).
- 2026-06-18T23:55-07:00 Web assets are built once by the `publish` job and shared
  to `build-cli` via a `web-assets` artifact, so the released `triaged` embeds the
  same web UI without rebuilding Flutter three times.
- 2026-06-18T23:55-07:00 Asset naming `Triage-cli-<os>-v<version>.{tar.gz,zip}`
  matches the release job's existing `Triage-*` attach glob, so no change to the
  release upload step beyond adding `build-cli` to its `needs`.
- 2026-06-18T23:55-07:00 Ship all three installable binaries (triaged, triage,
  triage-mcp); they share a dep graph, so the marginal build cost is small.

## What Changed

- 2026-06-18T23:55-07:00 `.github/workflows/publish.yml` — added the `build-cli`
  matrix job (Rust nightly + rust-cache + cross-platform `setup-flatc`, downloads
  the `web-assets` artifact into `crates/triaged/dist`, `cargo build --release
  --locked -p triaged -p triage -p triage-mcp`, packages tar.gz/zip, uploads).
  Added a `web-assets` upload step to the `publish` job. Added `build-cli` to the
  `release` job's `needs` and renamed it "clients + CLI binaries".
- 2026-06-18T23:55-07:00 `crates/triaged/README.md` — documented the prebuilt
  `Triage-cli-<os>` release archives under Installation.

## Issues

- 2026-06-18T23:50-07:00 Validation. Can't run the release workflow end-to-end
  (it publishes to crates.io and the binary jobs are gated off in dry-run), so
  validated the pieces locally instead: `cargo build --release --locked -p
  triaged -p triage -p triage-mcp` succeeds on macOS and produces all three
  binaries (triaged 19M, triage 8.2M, triage-mcp 1.1M); the binaries run
  (`triaged service` prints usage); the exact `tar -czf … -C target/release …`
  packaging command produces a valid 10M archive; `actionlint` passes on the
  edited workflow and the job graph parses (`release` needs `build-cli`; matrix
  = macos/windows/linux). The cross-platform build itself is already proven by
  `ci.yml`'s `cargo test --workspace` matrix on the same three runners.

## Next Steps

- Phase 1: surface update status over the session API (`HelloResult` banner).
- Phase 2: in-place upgrade (download prebuilt → spawn `triaged --handover` on
  Unix; `triaged service` restart fallback on Windows), with a handover
  protocol-version check.

## Commits

- HEAD — ci(release): attach prebuilt triaged/triage/triage-mcp binaries to releases
