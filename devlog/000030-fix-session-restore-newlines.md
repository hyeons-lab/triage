# fix/session-restore-newlines

## Agent

- Antigravity, 2026-05-24T14:10-0700

## Intent

- Correct styling and formatting of restored terminal sessions by converting bare newlines to carriage return + line feed, preventing layout stair-casing in the daemon's internal emulator.

## What Changed

- **Stateless Newline Translation:** Refactored `translate_newlines` in `crates/triaged/src/session.rs` to operate in a robust stateless manner. This eliminates chunk-boundary race conditions and pre-wrapping carriage return bugs introduced by stateful boundary-byte tracking.
- **Zero-Allocation & Zero-Reallocation Fast Path:** Optimized the stateless helper using `std::borrow::Cow` to scan the byte slice. If no bare newlines are present, it returns `Cow::Borrowed` with zero allocations. When translation is required, it pre-counts bare line feeds to allocate the exact capacity for `Vec::with_capacity`, preventing any dynamic reallocations.
- **PTY Ingestion Integration:** Integrated the translation in `OutputState::ingest` to prevent stair-casing on live session streaming.
- **Log Replay Integration:** Integrated the translation in `OutputState::replay` to ensure restored/historical logs render without alignment offsets.
- **Log Integrity Maintained:** Retained raw authentic bytes on disk since only the `wezterm_term` feed path is translated.
- **Updated Test Suite:** Renamed the unit test to `visible_rows_align_raw_bare_line_feed_to_column_0` to reflect actual column-0 alignment.
- **Updated Multi-Chunk Test:** Renamed and simplified `translate_newlines_across_chunk_boundaries` to verify boundary handling without stateful cross-chunk leakage.

## Decisions

- Retain the authentic raw log bytes on disk by performing the newline translation only immediately prior to feeding the bytes to the `wezterm_term::Terminal` instance.
- Avoid carrying boundary state across chunks to remain fully resilient against ConPTY pre-wrapping carriage returns and asynchronous shell echo races.
- Update the existing test suite to reflect correct newline layout formatting behavior rather than expecting stair-casing.

## Commits

- HEAD — fix: optimize newline translation and ensure robust stateless chunk boundary alignment
- a54d088 — perf: use Cow for zero-allocation fast path in newline translation
- 3ed1111 — fix: resolve stair-casing layout formatting on bare newlines

## Progress

- 2026-05-24T14:10-0700 — Created fix worktree and set up the branch plan.
- 2026-05-24T14:13-0700 — Implemented translation helper, integrated it into the PTY stream ingestion and replay logic, and updated the test suite. All tests are passing.
- 2026-05-24T15:21-0700 — Addressed PR feedback by refactoring newline translation to be stateful, tracking chunk-boundary bytes, renaming the test case, and adding multi-chunk boundary unit tests. All tests passing.
- 2026-05-24T15:45-0700 — Resolved layout alignment bugs on wrapping commands (such as the Antigravity CLI welcome banner) by removing cross-chunk state tracking, ensuring stateless boundary safety while retaining the zero-reallocation allocation capacity optimization.
