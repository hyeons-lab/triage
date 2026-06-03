## Thinking

The `Publish to crates.io` workflow (`.github/workflows/publish.yml`) is a manual
`workflow_dispatch` with a `dry_run` boolean. On a real run it builds the Flutter web
client, stages it into `crates/triaged/dist`, and publishes the five crates in
topological order. It does nothing on GitHub afterward.

Goal: on a real publish, tag the repo with the version, create a GitHub release, and
attach the macOS `Triage.app` Flutter desktop client.

Design choices:
- Version: derived once in the `publish` job via `cargo metadata` (the triaged package
  version == the workspace version) and exposed as a job output.
- The `Triage.app` build needs a macOS runner, so it lives in a new `release` job on
  `macos-latest` that `needs: publish` — this both serializes it after a successful
  crate publish and gives it the version output. It is gated `if: dry_run == 'false'`,
  so dry runs neither build the app nor cut a release. Because the job depends on
  `publish` (no `always()`), a failed publish skips the release entirely — no tag/release
  is created if crates didn't publish.
- A `.app` is a bundle (directory), so it is zipped with `ditto -c -k --keepParent`
  (preserves bundle structure / macOS metadata) before attaching.
- `softprops/action-gh-release@v2` creates the `v<version>` tag + release and uploads
  the asset; this needs top-level `permissions: contents: write`.
- The app is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), so the CI build needs no signing
  secrets.

## Plan

1. `permissions: contents: read` -> `write`.
2. Add a `version` output + `cargo metadata` step to the `publish` job.
3. Add a `release` job (macos-latest, needs publish, if dry_run==false) that builds
   `Triage.app`, zips it, and creates the `v<version>` tag + GitHub release with the zip
   attached.
4. Validate YAML; commit devlog + plan + workflow; push; open PR.
