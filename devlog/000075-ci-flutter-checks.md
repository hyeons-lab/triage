# 000075 — ci/flutter-checks

**Agent:** Claude (claude-opus-4-8) @ triage branch ci/flutter-checks

## Intent

PR CI only built/tested the Rust workspace; the Flutter client had no CI. This
let a broken widget test (`closes a session ...`) ship on `main` via #77 (which
added a confirm-close dialog but never updated the test). Add a Flutter job to
`ci.yml` so client regressions are caught on every PR.

## What Changed

2026-06-17T21:47-0700 .github/workflows/ci.yml — new `flutter` job
(ubuntu-latest, parallel to the Rust `check`/`test` jobs): `subosito/flutter-action@v2`
(version 3.44.0, stable, cached — matching publish.yml), `flutter pub get`,
`flutter analyze --no-fatal-infos --no-fatal-warnings`, `flutter test`.

## Decisions

2026-06-17T21:47-0700 Analyze gates on **error severity only**
(`--no-fatal-infos --no-fatal-warnings`). The client carries a large
pre-existing analyzer backlog (215 issues: 0 errors, 72 warnings, 143 infos —
mostly the generated FlatBuffers bindings), so a blanket `flutter analyze` would
red-fail immediately. Errors-only still catches genuine breakage (undefined
names, type errors) today; tightening it (exclude generated files, clear the
backlog, make warnings fatal) is a follow-up.

2026-06-17T21:47-0700 Used `subosito/flutter-action@v2` (moving tag) to match
the existing Flutter usage in publish.yml, rather than SHA-pinning as the Rust
steps do — kept consistent with the repo's established Flutter action reference.

## Issues

2026-06-17T21:47-0700 MERGE ORDER: `flutter test` is currently red on `main` —
the #77 leftover test is fixed in PR #83, not yet merged. This job is verified
correct (analyze exit 0; `flutter test` green on the #83 branch — 96 passed), but
its `flutter test` step will fail on a main-based run until #83 lands. **Merge
#83 first, then this**; the branch rebases onto the fixed main and goes green.

## Verification

2026-06-17T21:47-0700 `python3 -c "import yaml"` parses ci.yml (jobs: check,
test, flutter). `flutter analyze --no-fatal-infos --no-fatal-warnings` exits 0
locally; `flutter test` is green on the #83 branch (96 passed) and red on main
(the test #83 fixes), confirming the dependency.

## Commits

HEAD — ci: add Flutter analyze + test job to PR CI
