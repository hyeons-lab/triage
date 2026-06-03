# ci/multiplatform-release-clients

## Agent
- 2026-06-02T19:57-0700 — Claude Code (claude-opus-4-8) @ triage branch ci/multiplatform-release-clients — Extended the publish workflow to build and attach Windows and Linux Flutter clients in addition to macOS.

## Intent
- On a real crates.io publish, build the Windows and Linux Flutter desktop clients (alongside macOS) and attach all three to the GitHub release.

## What Changed
- 2026-06-02T19:57-0700 `.github/workflows/publish.yml` — Replaced the single macOS `release` job with three per-platform build jobs plus a combined release job:
  - `build-macos` (macos-latest): `flutter build macos --release`, ditto-zip `Triage.app` → `Triage-macos-v<version>.zip` artifact.
  - `build-windows` (windows-latest): `flutter build windows --release`, `Compress-Archive` the `build/windows/x64/runner/Release/` output → `Triage-windows-v<version>.zip` artifact.
  - `build-linux` (ubuntu-latest): apt-install the desktop toolchain + `libsecret-1-dev`/`libjsoncpp-dev` (for `flutter_secure_storage_linux`), `flutter build linux --release`, tar `build/linux/x64/release/bundle/` → `Triage-linux-v<version>.tar.gz` artifact.
  - `release` (ubuntu-latest): `needs: [publish, build-macos, build-windows, build-linux]`, downloads all artifacts and creates the `v<version>` tag + GitHub release with all three attached via `softprops/action-gh-release@v2`. Keeps `contents: write` scoped to this job only.

## Decisions
- 2026-06-02T19:57-0700 Build each client on its native runner and assemble in a separate `release` job (artifact upload/download) rather than appending to the release from each runner — avoids concurrent-append races and keeps the tag/release creation in one place with the single write-scoped job.
- 2026-06-02T19:57-0700 Linux build installs `libsecret-1-dev` + `libjsoncpp-dev` because `flutter_secure_storage_linux` links libsecret and jsoncpp; without them the Linux desktop build fails at the plugin's CMake configure.
- 2026-06-02T19:57-0700 The `release` job requires all three client builds. A single flaky client build blocks the release, but the recovery path is GitHub's "Re-run failed jobs": the already-succeeded `publish` job is not re-run (no duplicate `cargo publish`), only the failed build + `release`.

## Research & Discoveries
- 2026-06-02T19:57-0700 Flutter 3.44 desktop build output paths: macOS `build/macos/Build/Products/Release/Triage.app`; Windows `build/windows/x64/runner/Release/`; Linux `build/linux/x64/release/bundle/`.

## Commits
- HEAD — ci(publish): build and attach Windows and Linux clients to the release
