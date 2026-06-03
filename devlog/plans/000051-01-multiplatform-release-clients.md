## Thinking

PR #57 added a single macOS `release` job that built `Triage.app` and created the
GitHub release. We now also want the Windows and Linux Flutter desktop clients built
and attached to the same release.

Design: split the work into one build job per platform on its native runner, each
uploading a packaged artifact, then a single `release` job that downloads all three
and attaches them to one release.

- `build-macos` (macos-latest): `flutter build macos --release`, zip `Triage.app` with
  `ditto`. Ad-hoc signed, no secrets.
- `build-windows` (windows-latest): `flutter build windows --release`, `Compress-Archive`
  the `build/windows/x64/runner/Release/` output.
- `build-linux` (ubuntu-latest): install desktop toolchain + plugin deps
  (`flutter_secure_storage_linux` needs `libsecret-1-dev` + `libjsoncpp-dev`),
  `flutter build linux --release`, tar the `build/linux/x64/release/bundle/` directory.
- `release` (ubuntu-latest): `needs: [publish, build-macos, build-windows, build-linux]`,
  downloads all artifacts and uses `softprops/action-gh-release@v2` to create the
  `v<version>` tag + release with all three attached. Only this job has
  `contents: write` (least privilege).

All build jobs `needs: publish` and gate on `dry_run == 'false'`, so nothing is built
and no release is cut unless the crate publish succeeded.

Recovery: because `release` requires all three builds, a single flaky client build
blocks the release. The recovery path is GitHub's "Re-run failed jobs" — the already-
succeeded `publish` job is not re-run (so no duplicate `cargo publish`), only the failed
build job and `release` re-run.

## Plan

1. Replace the macOS-only `release` job with `build-macos` / `build-windows` /
   `build-linux` (each uploads an artifact) + a combined `release` job that downloads
   them and attaches all three.
2. Keep workflow permissions read-only; `contents: write` only on `release`.
3. Validate YAML; commit devlog + plan + workflow; push; open PR.
