# 000116-01 idempotent crate publishing

## Thinking

The 0.2.1 release exposed the gap. During the GitHub Actions outage on
2026-08-06 the publish run got as far as uploading all five crates, then lost
`Build CLI binaries (linux)` to a cancellation. The release job needs every CLI
build, so it was skipped: crates.io had 0.2.1 but there was no `v0.2.1` tag and
no GitHub release.

The obvious recovery is to re-run the workflow, and that is exactly what the
publish step forbids. Its first action is `cargo publish -p triage-core`, which
fails with "already uploaded" the moment the version exists, so the job dies
before reaching anything that still needs doing. A release interrupted anywhere
after the first upload cannot be finished by re-running it, which is the one
thing you want from a release pipeline that just half-failed.

So the publish step should treat "this version is already on crates.io" as
success rather than failure. Two independent mechanisms, because they fail in
different directions:

1. Ask crates.io before uploading. `GET /api/v1/crates/{crate}/{version}` is 200
   when the version exists and 404 when it does not. It rejects a request with
   no User-Agent with 403, and a 403 read as "absent" would cause a pointless
   upload attempt, so the request sets one.
2. Tolerate cargo's own "already exists" error. If the check is wrong (network
   blip, crates.io 5xx, or a version uploaded between the check and the upload)
   the attempt still happens, and cargo's rejection of a duplicate is then read
   as the state we wanted. This is what makes an unreachable API degrade into a
   retry rather than a hard failure.

Together they mean the step is safe to re-run in any state: nothing published
yet, some crates published, or all five.

The index-propagation waits stay, but only after an upload that actually
happened. Their purpose is to let the next crate resolve the dependency just
published; a crate that was skipped published nothing, so there is nothing to
wait for. The wait is also skipped after the final crate, which nothing follows.

The real publish path passes identical arguments for every crate
(`cargo publish -p <crate> --allow-dirty`), so the five unrolled invocations
collapse into a loop over the topological order. The dry-run path is untouched:
its `cargo package` calls take per-crate `--config patch.crates-io...` overrides
because downstream crates reference internal versions that may not exist on
crates.io yet, and it never uploads, so it has nothing to be idempotent about.

Scope stays on the publish step. The tag/release job has a related question (a
re-run against an existing tag), but it is a distinct failure with a distinct
fix, and folding it in would make this change harder to review than it needs to
be.

## Plan

1. Worktree `ci/idempotent-publish` from `origin/main`, upstream cleared.
2. Rewrite the non-dry-run half of the `Publish Crates` step:
   - `crate_version_published`: query crates.io with a User-Agent, 200 means
     published.
   - `publish_crate`: skip when already published; otherwise upload, treating
     cargo's "already exists" as success; wait only after a real upload and only
     when another crate follows.
   - Loop over `triage-core triage-transport-ws triaged triage-mcp triage`.
3. Leave the dry-run branch, the other jobs, and the release job alone.
4. Validate: parse the YAML, and shellcheck the extracted script.
5. Devlog, then commit and push once, and open the PR.
