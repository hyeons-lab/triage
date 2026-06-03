# ci/publish-github-release

## Agent
- 2026-06-02T18:59-0700 — Claude Code (claude-opus-4-8) @ triage branch ci/publish-github-release — Extended the crates.io publish workflow to tag, release, and attach the macOS Triage.app.

## Intent
- On a real crates.io publish, automatically create a git tag and GitHub release for the version and attach the macOS `Triage.app` Flutter client.

## What Changed
- 2026-06-02T18:59-0700 `.github/workflows/publish.yml` —
  - Raised `permissions` to `contents: write` (needed to create tags/releases).
  - Added a `version` output to the `publish` job, derived via `cargo metadata` (triaged package == workspace version).
  - Added a `release` job on `macos-latest` that `needs: publish` and runs only when `dry_run == 'false'`: builds `flutter build macos --release`, zips `Triage.app` with `ditto`, and uses `softprops/action-gh-release@v2` to create the `v<version>` tag + GitHub release with the zip attached.

## Decisions
- 2026-06-02T18:59-0700 Put the macOS app build in a separate `macos-latest` job that depends on `publish`, rather than a third runner/artifact round trip — it serializes the release after a successful crate publish, inherits the version output, and (no `always()`) is skipped if the publish job fails, so a tag/release is never created without a successful publish.
- 2026-06-02T18:59-0700 Zip the `.app` bundle with `ditto -c -k --keepParent` (a `.app` is a directory and can't be attached raw; ditto preserves bundle structure and macOS metadata).
- 2026-06-02T18:59-0700 No signing secrets required — the macOS client is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), consistent with the local release builds.

## Research & Discoveries
- 2026-06-02T18:59-0700 `workflow_dispatch` boolean inputs surface as the strings `'true'`/`'false'` in `if:` expressions, so the gate is `github.event.inputs.dry_run == 'false'` — matching the existing publish step's `= "true"` check.

## Commits
- HEAD — ci(publish): tag, release, and attach macOS Triage.app on publish
