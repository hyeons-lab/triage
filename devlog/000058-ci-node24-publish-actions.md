# ci/node24-publish-actions

**Agent:** Claude Code (claude-opus-4-8) @ triage branch ci/node24-publish-actions

## Intent

Clear the "Node.js 20 actions are deprecated" warning (it named `actions/checkout@v4`)
emitted by the publish workflow, by bumping the Node 20 JS actions in `publish.yml` to
their first Node 24 majors. GitHub force-migrates Node 20 actions to Node 24 on
2026-06-16 and removes the Node 20 runtime on 2026-09-16. Continues PR #60's durable
approach (eliminate Node 20 actions, not mask with `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`).

## What Changed

- 2026-06-05T07:24-0700 `.github/workflows/publish.yml` — Bumped the Node 20 actions to
  their first Node 24 majors: `actions/checkout@v4`→`@v5` (4×),
  `actions/upload-artifact@v4`→`@v6` (3×), `actions/download-artifact@v4`→`@v8` (1×),
  `softprops/action-gh-release@v2`→`@v3` (1×). Inputs are unchanged drop-ins.
- 2026-06-05T07:45-0700 `.github/workflows/publish.yml` — SHA-pinned all four bumped
  actions to the commit each Node 24 major resolves to, with a `# owner/action@vMAJOR`
  comment above (matching `ci.yml`'s convention): checkout
  `93cb6efe18208431cddfb8368fd83d5badbf9bfd`, upload-artifact
  `b7c566a772e6b6bfb58ed0dc250532a479d7789f`, download-artifact
  `3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c`, action-gh-release
  `b4309332981a82ec1c5618f44dd2e27cc8bfbfda`. Addresses Copilot's supply-chain pinning
  comments on PR #65; checkout's SHA is identical to the one `ci.yml` already pins.

## Decisions

- 2026-06-05T07:24-0700 Bump to the *first* Node 24 major of each action, not the latest —
  reasoning: `upload-artifact@v5` and `download-artifact@v5`/`v6` are still Node 20, so the
  Node 24 cutover is `upload-artifact@v6` / `download-artifact@v8`; verified each target's
  `runs.using: node24` via the action manifest. `action-gh-release@v3.0.0` release notes
  confirm it is a runtime-only Node 20→24 bump with no functional changes.
- 2026-06-05T07:24-0700 Left `ci.yml` untouched — its checkout is already SHA-pinned to v5
  (Node 24), `Swatinem/rust-cache@v2` is Node 24, and `setup-flatc`/`flutter-action` are
  composite actions with no Node runtime.

## Issues

- 2026-06-05T07:24-0700 The publish workflow only runs on a manual publish, so these bumps
  can't be exercised by PR CI. Mitigated by choosing input-compatible drop-ins and
  confirming the release glob `release-assets/**/Triage-*` still matches the
  download-artifact layout (no `name` → per-artifact subdirectories; `**` also matches a
  flat layout, so either is fine).

## Next Steps

- Verify at the next publish run (the 0.1.4 release, or the next bump) that the warning
  is gone and the clients still attach to the GitHub release.

## Commits

- a297cc4 — ci(publish): bump Node 20 actions to Node 24 majors
- HEAD — ci(publish): SHA-pin the bumped publish actions (PR #65 review)
