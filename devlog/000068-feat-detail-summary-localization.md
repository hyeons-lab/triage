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

## Commits

- HEAD — feat(triaged): localize side-rail detail summary with repo/branch/worktree
