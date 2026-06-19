# 000079 — ci/release-rust-binaries

**Agent:** Claude (claude-opus-4-8) @ triage branch ci/release-rust-binaries

## Intent

Phase 0 of the self-update epic: attach prebuilt `triaged` / `triage` /
`triage-mcp` binaries to every GitHub release, so self-update (and plain
installs) can prefer a download over `cargo install --force`. Today `publish.yml`
publishes the crates to crates.io and builds the three Flutter desktop clients,
but ships no prebuilt Rust binaries.

## Decisions

- 2026-06-18T23:55-0700 New `build-cli` matrix job (macos/windows/ubuntu) rather
  than bolting binary builds onto the existing `build-<os>` client jobs — keeps
  the Flutter client build and the Rust binary build independent, and the build
  mirrors what `ci.yml` already runs on all three OSes (so it's low-risk).
- 2026-06-18T23:55-0700 Web assets are built once by the `publish` job and shared
  to `build-cli` via a `web-assets` artifact, so the released `triaged` embeds the
  same web UI without rebuilding Flutter three times.
- 2026-06-18T23:55-0700 Asset naming `Triage-cli-<os>-v<version>.{tar.gz,zip}`
  matches the release job's existing `Triage-*` attach glob, so no change to the
  release upload step beyond adding `build-cli` to its `needs`.
- 2026-06-18T23:55-0700 Ship all three installable binaries (triaged, triage,
  triage-mcp); they share a dep graph, so the marginal build cost is small.

## What Changed

- 2026-06-18T23:55-0700 `.github/workflows/publish.yml` — added the `build-cli`
  matrix job (Rust nightly + rust-cache + cross-platform `setup-flatc`, downloads
  the `web-assets` artifact into `crates/triaged/dist`, `cargo build --release
  --locked -p triaged -p triage -p triage-mcp`, packages tar.gz/zip, uploads).
  Added a `web-assets` upload step to the `publish` job. Added `build-cli` to the
  `release` job's `needs` and renamed it "clients + CLI binaries".
- 2026-06-18T23:55-0700 `crates/triaged/README.md` — documented the prebuilt
  `Triage-cli-<os>` release archives under Installation.

## Issues

- 2026-06-18T23:50-0700 Validation. Can't run the release workflow end-to-end
  (it publishes to crates.io and the binary jobs are gated off in dry-run), so
  validated the pieces locally instead: `cargo build --release --locked -p
  triaged -p triage -p triage-mcp` succeeds on macOS and produces all three
  binaries (triaged 19M, triage 8.2M, triage-mcp 1.1M); the binaries run
  (`triaged service` prints usage); the exact `tar -czf … -C target/release …`
  packaging command produces a valid 10M archive; `actionlint` passes on the
  edited workflow and the job graph parses (`release` needs `build-cli`; matrix
  = macos/windows/linux). The cross-platform build itself is already proven by
  `ci.yml`'s `cargo test --workspace` matrix on the same three runners.

### PR review comments (Copilot, #90)

- 2026-06-19T08:35-0700 `.github/workflows/publish.yml` — Copilot: the new
  `build-cli` job used floating action tags (`dtolnay/rust-toolchain@nightly`,
  `Swatinem/rust-cache@v2`) while ci.yml SHA-pins them. Pinned both to ci.yml's
  SHAs (`rust-toolchain@e97e2d8…`, `rust-cache@42dc69e…`) and added
  `cache-bin: false` to match. (The pre-existing `publish` job still uses floating
  tags; left as-is — out of this change's scope.)
- 2026-06-19T08:35-0700 devlog — switched timestamp UTC offsets to the AGENTS.md
  `±HHMM` (no-colon) convention.
- 2026-06-19T06:31-0700 Round 2. `crates/triaged/README.md` — Copilot: the
  prebuilt-binary note didn't mention architecture; `macos-latest` is Apple
  Silicon (arm64), so an Intel-Mac user would hit "exec format error". Added an
  Architecture note (macOS = arm64, Linux/Windows = x86-64; use `cargo install`
  elsewhere). `.github/workflows/publish.yml` — Copilot: the release job's
  blanket artifact download also pulled the `web-assets` bundle; added
  `pattern: cl*` so it fetches only `client-*` / `cli-*`.

## Next Steps

- Phase 1: surface update status over the session API (`HelloResult` banner).
- Phase 2: in-place upgrade (download prebuilt → spawn `triaged --handover` on
  Unix; `triaged service` restart fallback on Windows), with a handover
  protocol-version check.

## Commits

- 740c142 — ci(release): attach prebuilt triaged/triage/triage-mcp binaries to releases
- f788341 — ci(release): SHA-pin build-cli actions to match ci.yml
- HEAD — ci(release): note binary arch in README, scope release download to cl*
