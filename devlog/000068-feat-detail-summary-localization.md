# 000068 — feat/detail-summary-localization

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch feat/detail-summary-localization

## Intent

Make the side-rail hover detail summary self-contained for localization: lead it
with the session's repo / branch / worktree so the user can tell which of many
similar sessions it is, and allow the activity description to run longer than
2–3 sentences. Honour the LeapBundles manifest's sampling params for the detail
pass, while keeping the one-line rail label deterministic (greedy).

## What Changed

- 2026-06-16T16:50-0700 `crates/triaged/src/summarizer.rs` — `SummarizeJob`
  gains `context: Option<SessionContext>`. New `DETAIL_SYSTEM_PROMPT` focuses on
  activity + localization (task, commands/tools, files, current state incl.
  error text), allows up to ~5 sentences, and forbids guessing git repo/branch/
  dir. `generate_detail` now takes the context and prepends a deterministic
  `repo · branch · worktree` header via new `context_header`/`leaf_name` helpers
  (mirrors the client rail meta line: omits absent parts, hides worktree leaf
  when it's the repo root or echoes the branch). New `sampling_opts` applies the
  model's manifest `sampling_parameters` (temperature/top-p/top-k/repetition-
  penalty) for the detail pass, falling back to greedy temp-0; the one-line pass
  stays explicitly greedy. `MAX_DETAIL_CHARS` 280 → 480 (caps only the model
  portion, never the header). Added `context_header` unit test; extended the
  ignored e2e test to assert the header.
- 2026-06-16T16:50-0700 `crates/triaged/src/session.rs` — `ActorCommand::
  SummaryRows` response carries `Option<SessionContext>` so the existing off-lock
  round-trip also returns context; `summary_rows`/`request_summary_rows` return
  types updated; both summarizer enqueue sites populate `SummarizeJob.context`.
- 2026-06-16T16:50-0700 `crates/triage-core/src/config.rs` — `detail_max_tokens`
  110 → 180 to fit the longer summary.

## Decisions

- 2026-06-16T16:50-0700 Deterministic header, not model-generated — a 1.2B
  local model would hallucinate branch names; the daemon already holds the exact
  `SessionContext`, so the header is built in Rust and the prompt tells the model
  not to guess git fields.
- 2026-06-16T16:50-0700 Manifest sampling for detail only; one-line stays
  temp-0 — per user request, so the terse rail label is stable across
  regenerations while the detail pass uses the model's recommended params.
- 2026-06-16T16:50-0700 Reuse the `SummaryRows` round-trip to carry context
  rather than adding a second actor command — no extra latency on the summarizer
  hot path.

## Issues

- 2026-06-16T17:05-0700 First CI run failed Format and Lint: I'd skipped
  `cargo fmt`, and clippy (`-D warnings`) flagged two issues in the new code —
  `type_complexity` on the `(Vec<String>, u64, Option<SessionContext>)` tuple and
  a `collapsible_if` in `context_header`. Fixed by adding a `SummaryRowsResponse`
  type alias and collapsing the `if let … && …` (let-chains, already used
  elsewhere in this file). `cargo fmt --check` + `cargo clippy --workspace
  --all-targets --all-features --locked -- -D warnings` now clean; amended.
- 2026-06-16T21:46-0700 PR #78 review (Copilot) fixes: updated the
  `ActorCommand::SummaryRows` doc comment to describe the new
  `(rows, output_seq, context)` return shape (the optional `SessionContext` is
  repo/worktree root + branch, used to localize the summary); normalized this
  file's timestamps from `-07:00` to the repo-standard `-0700` offset form.
- 2026-06-16T21:48-0700 `crates/triaged/src/summarizer.rs` — `sampling_opts`
  now maps the full manifest sampling set. cera 0.1.1 added a `min_p` field to
  both `GenerateOpts` and `GenerationDefaults::Text`; the old destructure used
  `..` and silently dropped it, so a model recommending min-p wasn't honored.
  Now we map all five (`temperature`/`min_p`/`top_p`/`top_k`/
  `repetition_penalty`) and made the `Text` destructure exhaustive (no `..`) so
  a future cera param fails the build instead of being dropped. Each param is
  still applied only when the manifest sets it, so partial blocks keep cera's
  defaults for the rest.
- 2026-06-16T22:06-0700 PR #78 review round 2 (Copilot) fixes on `sampling_opts`
  + a `/code-review` finding:
  - **Greedy baseline bug**: `sampling_opts` initialized `temperature: 0.0`
    unconditionally, so a manifest recommending `top_p`/`top_k` *without* a
    temperature was forced to greedy (the recommended params then did nothing),
    and the "starts from cera's defaults" doc was false for temperature. Fixed
    by starting from `GenerateOpts::default()` (cera's real defaults) and
    applying manifest params only when the `Text` block carries at least one
    (`has_sampling_params` guard); a `Text` block with every field unset — or a
    non-`Text` manifest — falls back to explicit greedy (`temperature = 0.0`).
    So: params present → sample (unset fields keep cera defaults, incl.
    temperature); no guidance → deterministic greedy. Addresses both inline
    comments (`:325` greedy-baseline, `:350` missing explicit fallback).
  - Extracted the engine-free core `sampling_opts_from_defaults(&defaults,
    max_tokens)` so the mapping is unit-testable, and added four tests:
    top-p/top-k-without-temperature stays stochastic at cera's default temp;
    all-`None` `Text` → greedy; non-`Text` (`Audio`) → greedy; explicit params
    applied verbatim.
  - `/code-review` finding: `SnippetResult.detail` doc said `None` means "model
    produced nothing", but a header-only detail is now returned when git context
    exists with empty model output — corrected the doc to "`None` only when
    neither the model nor the git context produced anything usable".

## Commits

- HEAD — feat(triaged): localize side-rail detail summary with repo/branch/worktree
