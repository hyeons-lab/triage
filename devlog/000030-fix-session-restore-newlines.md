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
- **Client-Side Live Stream Newline Translation:** Added bare newline translation in `flutter/triage_client/lib/main.dart` inside the live PTY WebSocket broadcast event output handler, converting bare `\n` to `\r\n` before feeding raw data to xterm.js to permanently prevent client-side layout stair-casing.
- **Removed Temporary Debug Test:** Deleted `test_debug_session_12` from `crates/triaged/src/session.rs`.
- **Added Direct Byte-Level Unit Test:** Added `test_translate_newlines_direct` to test byte-level correctness of the stateless translation logic on empty inputs, standard text, bare newlines, and mixed CRLF streams.

## Decisions

- Retain the authentic raw log bytes on disk by performing the newline translation only immediately prior to feeding the bytes to the `wezterm_term::Terminal` instance.
- Avoid carrying boundary state across chunks to remain fully resilient against ConPTY pre-wrapping carriage returns and asynchronous shell echo races.
- Update the existing test suite to reflect correct newline layout formatting behavior rather than expecting stair-casing.
- Perform stateless, high-performance two-step string replacement (\r\n -> \n -> \r\n) directly in the Flutter Web client before writing to xterm.js. This ensures robust cursor positioning and alignment on live streams, bypassing custom terminal emulator options limitations and avoiding any RegExp lookbehind compatibility issues on older JS engines (e.g. older iOS Safari).

## Commits

- HEAD — fix(client): translate bare newlines in live stream to prevent client-side stair-casing
- 7a70674 — fix: optimize newline translation and ensure robust stateless chunk boundary alignment
- a54d088 — perf: use Cow for zero-allocation fast path in newline translation
- 3ed1111 — fix: resolve stair-casing layout formatting on bare newlines

## Progress

- 2026-05-24T14:10-0700 — Created fix worktree and set up the branch plan.
- 2026-05-24T14:13-0700 — Implemented translation helper, integrated it into the PTY stream ingestion and replay logic, and updated the test suite. All tests are passing.
- 2026-05-24T15:21-0700 — Addressed PR feedback by refactoring newline translation to be stateful, tracking chunk-boundary bytes, renaming the test case, and adding multi-chunk boundary unit tests. All tests passing.
- 2026-05-24T15:45-0700 — Resolved layout alignment bugs on wrapping commands (such as the Antigravity CLI welcome banner) by removing cross-chunk state tracking, ensuring stateless boundary safety while retaining the zero-reallocation allocation capacity optimization.
- 2026-05-24T16:16-0700 — Solved browser alignment stair-casing on live streams by translating bare newlines to \r\n in main.dart prior to feeding xterm.js, deleted the temporary debug test, verified all tests/fmt/clippy checks pass, and restarted the daemon.
- 2026-05-24T17:20-0700 — Critically reviewed changes and optimized the client EOL translation to a highly compatible two-step string replacement. Added direct byte-level testing for translate_newlines in session.rs to fully address PR review comments, verified all tests/fmt/clippy checks pass, amended the commit, and force-pushed.
