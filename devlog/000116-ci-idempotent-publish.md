# 000116 ci/idempotent-publish

**Agent:** Claude (claude-opus-5, 1M context) @ triage branch ci/idempotent-publish

## Intent

Make the crate publish step re-runnable, so a release that fails after the
crates are uploaded can be finished by re-running it instead of being stuck.
Plan: [plans/000116-01-idempotent-publish.md](plans/000116-01-idempotent-publish.md).

## What Changed

2026-08-06T21:36-0700 `.github/workflows/publish.yml`: the non-dry-run half of
the `Publish Crates` step. Five unrolled `cargo publish` calls become a loop
over the same topological order, guarded by two checks. `crate_version_published`
asks crates.io whether the version already exists and skips the upload when it
does; `publish_crate` additionally reads cargo's own "already exists" rejection
as success, so an unreachable or wrong check degrades into a retry rather than a
hard failure. The step gains `VERSION` in its `env` (from the existing
`steps.version.outputs.version`) since both checks need it. Index-propagation
waits now happen only after an upload that actually occurred, and not after the
last crate.

## Decisions

2026-08-06T21:38-0700 Two independent mechanisms rather than one. Reasoning: the
crates.io query alone fails open if the API is unreachable, returns 5xx, or the
version lands between check and upload, and each of those would resurrect the
exact failure this change exists to remove. Trusting cargo's duplicate error
alone would work, but it means every re-run re-uploads and parses an error to
decide it was fine. The query handles the normal case cleanly, the error branch
catches what the query misses.

2026-08-06T21:39-0700 The crates.io request sets a User-Agent. Reasoning:
crates.io answers 403 without one. A 403 is not 200, so the version would read
as absent and the step would attempt an upload that can only fail, which is the
opposite of the intent. This bit us before when checking published versions by
hand.

2026-08-06T21:41-0700 Waits are conditional on an actual upload. Reasoning: the
wait exists so the next crate can resolve the dependency just published. A
skipped crate published nothing, so there is nothing to propagate; a full re-run
of an already-published version now costs five HTTP requests instead of 80
seconds of sleeping. The last crate has nothing after it, so it never waits,
which matches the original.

2026-08-06T21:42-0700 Left the dry-run path alone. Reasoning: it runs
`cargo package`, never uploads, and its per-crate `--config patch.crates-io...`
overrides exist because downstream crates reference internal versions that may
not be on crates.io yet. Nothing there is non-idempotent.

2026-08-06T21:43-0700 Did not touch the tag/release job. Reasoning: re-running
against an existing tag is a real adjacent question, but it is a separate
failure with a separate fix, and bundling it would make this harder to review.

## Issues

2026-08-06T21:35-0700 The 0.2.1 release is what surfaced this. During the
GitHub Actions outage the publish job uploaded all five crates and succeeded,
then `Build CLI binaries (linux)` was cancelled; the release job needs every CLI
build, so it was skipped. crates.io had 0.2.1 with no `v0.2.1` tag and no GitHub
release, and the workflow could not be re-run to finish the job because the
publish step would fail on the already-uploaded crates. Recovery was blocked on
a stuck run rather than on anything fixable in the repo.

2026-08-06T21:52-0700 First draft called `crate_version_published` twice per
crate, once to decide whether to skip and again to decide whether to wait. Two
HTTP requests per crate for one answer, and the skip logic lived in two places
that could disagree. Replaced with `UPLOADED`, set by `publish_crate` and read
by the loop. The same pass replaced a hardcoded `!= "triage"` end-of-list test
with `LAST_CRATE="${CRATES##* }"`, so reordering or extending `CRATES` cannot
silently leave a stray wait.

## Verification

- `actionlint .github/workflows/publish.yml`: clean (it runs shellcheck over the
  `run:` blocks).
- Behaviour tested by extracting the step's script from the YAML and running it
  with `cargo` and `sleep` stubbed, against live crates.io where possible:
  - version 0.2.1, all five genuinely published: every crate skipped, no waits,
    exit 0. This is the case that was previously unrecoverable.
  - version 9.9.9, none published: all five published in order, four waits, none
    after the last crate.
  - query says absent but cargo reports a duplicate: tolerated, run continues,
    exit 0.
  - cargo fails for any other reason: aborts, exit 1.
  - partial resume (two of five already published, via a stubbed query): the two
    skip, the remaining three publish.
  - dry run: output identical to before, and it never calls crates.io.
- `git diff` confirms no `cargo package` line changed.

## Next Steps

- Once merged, a fresh dispatch of the workflow for 0.2.1 will skip all five
  crates, rebuild the clients and CLI binaries, and create the `v0.2.1` tag and
  release that the outage left unfinished.
- Consider the same treatment for the release job, which would fail against a
  tag that already exists.

## Commits

- HEAD: ci(publish): make crate publishing re-runnable
