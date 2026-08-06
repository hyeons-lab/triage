# 000115 chore/bump-0.2.1

**Agent:** Claude (claude-opus-5, 1M context) @ triage branch chore/bump-0.2.1

## Intent

Cut 0.2.1 so the two fixes that landed after `v0.2.0` can be published to
crates.io. Plan: [plans/000115-01-bump-0.2.1.md](plans/000115-01-bump-0.2.1.md).

## What Changed

2026-08-06T11:14-0700 `VERSION`, `Cargo.toml`, `Cargo.lock`,
`flutter/triage_client/pubspec.yaml`: 0.2.0 to 0.2.1, all four written by
`scripts/bump-version.sh 0.2.1` rather than by hand. `Cargo.toml` moves both
`[workspace.package].version` and the three internal path-dep pins
(`triage-core`, `triage-transport-ws`, `triaged`); `pubspec.yaml` becomes
`0.2.1+1`, keeping its build number.

## Decisions

2026-08-06T11:12-0700 Patch rather than minor. Reasoning: `git log v0.2.0..HEAD`
is exactly two commits, #132 (the web terminal paste fix) and #133 (the session
rail group-drag fix). Both are bug fixes to shipped behaviour, neither adds or
changes public API, so the patch component is the only one with a reason to
move.

2026-08-06T11:14-0700 Ran the script rather than editing the four files.
Reasoning: they have to agree, and `--check` is a CI gate, so a hand edit that
missed the path-dep pins or the `+1` build number would fail the build rather
than the review. The script is also the only thing that refreshes `Cargo.lock`'s
workspace entries in the same pass.

2026-08-06T11:16-0700 Did not tag or publish on this branch. Reasoning: the
release pipeline reads the version from `cargo metadata`, so the tag belongs to
the merged commit, not to a branch that may still be rebased. Publishing is a
separate step that needs explicit sign-off.

## Verification

- `scripts/bump-version.sh --check`: all files match VERSION 0.2.1.
- `cargo fmt --all --check`: clean.
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`: clean.
- `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps --locked`: clean.
- `cargo test --workspace`: passing.
- Confirmed against crates.io that 0.2.0 is published for all five crates, so
  0.2.1 is unused. The API returns 403 without a User-Agent, which reads as
  "not published" if the status code is ignored, so the check sets one.

## Next Steps

- Merge, then tag and publish 0.2.1 as a separate confirmed step.

## Commits

- HEAD: chore(release): bump to 0.2.1
