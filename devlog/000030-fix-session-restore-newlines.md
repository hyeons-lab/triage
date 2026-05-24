# fix/session-restore-newlines

## Agent

- Antigravity, 2026-05-24T14:10-0700

## Intent

- Correct styling and formatting of restored terminal sessions by converting bare newlines to carriage return + line feed, preventing layout stair-casing in the daemon's internal emulator.

## What Changed

- **Newline Translation Helper:** Added `translate_newlines` in `crates/triaged/src/session.rs` to convert any bare `\n` (not preceded by `\r`) to `\r\n` before feeding it to `wezterm_term::Terminal`.
- **PTY Ingestion Integration:** Integrated the translation in `OutputState::ingest` to prevent stair-casing on live session streaming.
- **Log Replay Integration:** Integrated the translation in `OutputState::replay` to ensure restored/historical logs render without alignment offsets.
- **Log Integrity Maintained:** Retained raw authentic bytes on disk since only the `wezterm_term` feed path is translated.
- **Updated Test Suite:** Updated `visible_rows_preserve_raw_bare_line_feed_columns` test case to assert aligned formatting instead of stair-casing.

## Decisions

- Retain the authentic raw log bytes on disk by performing the newline translation only immediately prior to feeding the bytes to the `wezterm_term::Terminal` instance.
- Update the existing test suite to reflect correct newline layout formatting behavior rather than expecting stair-casing.

## Commits

- HEAD — fix: resolve stair-casing layout formatting on bare newlines

## Progress

- 2026-05-24T14:10-0700 — Created fix worktree and set up the branch plan.
- 2026-05-24T14:13-0700 — Implemented translation helper, integrated it into the PTY stream ingestion and replay logic, and updated the test suite. All tests are passing.
