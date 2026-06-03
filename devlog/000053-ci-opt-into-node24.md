# ci/opt-into-node24

## Agent
- 2026-06-02T22:22-0700 — Claude Code (claude-opus-4-8) @ triage branch ci/opt-into-node24 — Silenced the Node 20 deprecation warnings by opting JS actions into Node 24.

## Intent
- Remove the "Node.js 20 actions are deprecated" warnings shown on every CI job.

## What Changed
- 2026-06-02T22:22-0700 `.github/workflows/ci.yml` and `.github/workflows/publish.yml` — Added `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"` to the workflow-level `env`, so all JavaScript actions run on Node 24.

## Decisions
- 2026-06-02T22:22-0700 The only flagged action was `Nugine/setup-flatc@v1`. Its latest release (`v1.2.4`) still declares `using: "node20"`, so there is no version to bump to. `crates/triage-core/build.rs` requires `flatc` on PATH at build time, so the action can't be dropped, and replacing it with a per-OS binary install across the ubuntu/macOS/Windows matrix (~5 call sites) would be verbose and fragile. The warning itself recommends `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`; GitHub force-migrates Node 20 actions to Node 24 on 2026-06-16 regardless, so opting in now is the inevitable change, two weeks early, and future-proofs every JS action.

## Research & Discoveries
- 2026-06-02T22:22-0700 `setup-flatc` `@v1` resolves to `v1.2.4`; both `v1` and `v1.2.4` declare `using: "node20"` (no Node 24 release). The other workflow actions (checkout, rust-cache, rust-toolchain, flutter-action, upload/download-artifact, action-gh-release) already support Node 24.
- 2026-06-02T22:22-0700 A separate informational NOTICE ("windows-latest redirected to windows-2025-vs2026 by 2026-06-15") is not actionable — the runner label auto-redirects.

## Commits
- HEAD — ci: opt JavaScript actions into Node 24 to clear Node 20 deprecation warnings
