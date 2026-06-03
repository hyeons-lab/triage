## Thinking

CI is green but every job that uses `Nugine/setup-flatc@v1` emits a Node 20
deprecation warning ("Node.js 20 actions are deprecated ... forced to run with
Node.js 24 by default starting June 16th, 2026"). It is the only action flagged.

Investigation:
- `setup-flatc` `@v1` floats to `v1.2.4` (latest); both declare `using: "node20"`,
  so there is no newer version to bump to — a version bump does not fix the warning.
- `crates/triage-core/build.rs` needs `flatc` on PATH at build time (it generates
  Rust from `schema/triage.fbs`), so the action can't simply be dropped.
- A direct per-OS binary install is possible (flatbuffers ships `Linux/Mac/Windows.flatc.binary.zip`)
  but would replace the action at ~5 call sites across the ubuntu/macOS/Windows matrix
  with verbose OS-conditional shell — a lot of fragile YAML.

The warning itself recommends the fix: set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`
to opt JS actions into Node 24 now. The action is force-migrated to Node 24 on
2026-06-16 anyway, so this just does the inevitable a couple weeks early, and it
future-proofs every JS action in the workflow. All other actions in use
(checkout, rust-cache, rust-toolchain, flutter-action, upload/download-artifact,
action-gh-release) already support Node 24.

## Plan

1. Add `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"` to the workflow-level `env`
   of `.github/workflows/ci.yml` and `.github/workflows/publish.yml`.
2. Validate YAML; commit devlog + plan + workflows; push; open PR. CI on the PR
   confirms the warning is gone and the build still passes.

## Revision (2026-06-02T22:40-0700)

Plan step 1 (`FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`) was tried and verified on CI: it
switched setup-flatc to run on Node 24 but did NOT clear the warning — GitHub still
flags any action whose manifest declares `using: node20` ("…being forced to run on
Node.js 24"). Pivoted to the durable fix:

1. Add a local composite action `.github/actions/setup-flatc/action.yml` (single
   cross-platform `pwsh` step: download the pinned flatc for the runner OS, extract,
   add to PATH). Composite actions have no Node runtime, so no deprecation warning.
2. Replace the three `uses: Nugine/setup-flatc@v1` steps with `uses: ./.github/actions/setup-flatc`.
3. Remove the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` env (no node20 actions remain).
