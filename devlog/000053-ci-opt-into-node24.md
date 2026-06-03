# ci/opt-into-node24

## Agent
- 2026-06-02T22:22-0700 — Claude Code (claude-opus-4-8) @ triage branch ci/opt-into-node24 — Cleared the Node 20 deprecation warnings by replacing the only node20 action (`Nugine/setup-flatc`) with a local composite action.

## Intent
- Remove the "Node.js 20 actions are deprecated" warnings shown on every CI job.

## What Changed
- 2026-06-02T22:40-0700 `.github/actions/setup-flatc/action.yml` (new) — Local **composite** action that downloads the pinned `flatc` (default 25.2.10) for the runner OS via a single cross-platform `pwsh` step (download + `Expand-Archive`) and adds it to `PATH`. Composite actions have no Node runtime, so they don't trigger the Node 20 deprecation warning.
- 2026-06-02T22:40-0700 `.github/workflows/ci.yml` and `.github/workflows/publish.yml` — Replaced all three `uses: Nugine/setup-flatc@v1` steps with `uses: ./.github/actions/setup-flatc` (each job already checks out the repo before this step).

## Decisions
- 2026-06-02T22:40-0700 The only flagged action was `Nugine/setup-flatc@v1`. Its latest release (`v1.2.4`) still declares `using: "node20"` (no Node 24 version to bump to), and `crates/triage-core/build.rs` needs `flatc` on PATH at build time, so the action can't be dropped. Replaced it with a local composite action so the node20 dependency is gone entirely (the durable fix), rather than masking the warning.
- 2026-06-02T22:40-0700 Implemented the install in a single `pwsh` step rather than per-OS `bash`: PowerShell Core ships on every GitHub-hosted runner and `Invoke-WebRequest` + `Expand-Archive` work identically on Linux/macOS/Windows, avoiding a `unzip`-availability problem in Git-bash on Windows.

## Issues
- 2026-06-02T22:30-0700 First attempt set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"` in both workflows. CI confirmed it changed the runtime (the warning became "actions target Node.js 20 but are being forced to run on Node.js 24"), but the warning was NOT removed — GitHub still flags any action whose manifest declares `using: node20`. Reverted the env var and replaced the action instead.

## Research & Discoveries
- 2026-06-02T22:22-0700 `setup-flatc` `@v1` resolves to `v1.2.4`; both declare `using: "node20"`. The other workflow actions (checkout, rust-cache, rust-toolchain, flutter-action, upload/download-artifact, action-gh-release) were never flagged as node20.
- 2026-06-02T22:22-0700 flatbuffers v25.2.10 release assets: `Linux.flatc.binary.clang++-18.zip`, `Mac.flatc.binary.zip` (Apple Silicon), `Windows.flatc.binary.zip`. `triage-core/build.rs` only needs `flatc`/`flatc.exe` on PATH (not a strict version).
- 2026-06-02T22:22-0700 A separate informational NOTICE ("windows-latest redirected to windows-2025-vs2026 by 2026-06-15") is not actionable — the runner label auto-redirects.

## Commits
- HEAD — ci: replace node20 setup-flatc action with a local composite action
