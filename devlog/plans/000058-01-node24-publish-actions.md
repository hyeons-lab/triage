# Plan: bump publish.yml actions off Node 20

## Thinking

The publish workflow run for 0.1.4 emitted the Node 20 deprecation warning naming
`actions/checkout@v4` (GitHub force-migrates Node 20 JS actions to Node 24 on
2026-06-16 and removes the Node 20 runtime on 2026-09-16). PR #60 already cleared the
warning on `ci.yml` (replaced the only flagged action, `Nugine/setup-flatc`, with a
composite action) and established the durable approach: eliminate Node 20 actions rather
than mask the warning with `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` (which #60 verified does
not remove the warning).

`ci.yml`'s checkout is already SHA-pinned to v5 (Node 24), so it is clean. The remaining
Node 20 actions all live in `publish.yml`:

- `actions/checkout@v4` (Node 20) → `@v5` (Node 24). v5 is what ci.yml already runs.
- `actions/upload-artifact@v4` (Node 20) → `@v6` (Node 24). v5 is still Node 20; v6 is the
  first Node 24 major. Inputs (`name`/`path`/`if-no-files-found`) unchanged.
- `actions/download-artifact@v4` (Node 20) → `@v8` (Node 24). v6 is still Node 20; v8 is the
  first Node 24 major. The no-`name` download-all-into-subdirectories layout (consumed by
  the release glob `release-assets/**/Triage-*`) is unchanged.
- `softprops/action-gh-release@v2` (Node 20) → `@v3` (Node 24). v3.0.0 is explicitly a
  runtime-only bump (Node 20 → Node 24) with no functional changes per its release notes.

Verified each target version's `runs.using` is `node24` via the action manifests. The
publish workflow only runs on manual publish, so it can't be exercised in PR CI; the bumps
were chosen to be input-compatible drop-ins.

## Plan

1. In `.github/workflows/publish.yml`, bump: `checkout@v4`→`@v5` (4×),
   `upload-artifact@v4`→`@v6` (3×), `download-artifact@v4`→`@v8` (1×),
   `action-gh-release@v2`→`@v3` (1×).
2. Leave `ci.yml` untouched (checkout already SHA-pinned to v5; rust-cache@v2 is Node 24;
   setup-flatc and flutter-action are composite — no Node runtime).
3. Confirm no Node 20 action references remain and the YAML still parses.
