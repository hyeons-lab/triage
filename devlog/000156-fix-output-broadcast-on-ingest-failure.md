# 000156 — fix/output-broadcast-on-ingest-failure

## Agent

Muse Code (muse-spark), 2026-10-02.

## Intent

Typing lag root cause (hunt concluded on the ux-trio worktree): when PTY
output-log writes fail (disk full, 34k ENOSPC failures Sep 26-Oct 2),
`handle_output` drops the client broadcast along with the failed ingest,
freezing every attached terminal. Decouple liveness from persistence: live
output still broadcasts when the log write fails. Follow-ups tracked
separately: client heartbeat + dead-socket teardown, session-261's blocked
writer (child not draining stdin).

## What Changed

- `OutputState::ingest` no longer fails on a log write error: it warns,
  re-syncs byte counters to the on-disk length, drops the log cache, and
  still advances the terminal + output sequence, so every caller's Ok path
  (live broadcast, shutdown drain, `drain_until_exit`) keeps working.
- Regression test `ingest_failure_still_advances_terminal_and_sequence`
  forces EBADF with a read-only log handle; observed red pre-fix, green
  post-fix.
- 2026-10-09T12:10-0700: add log_path diagnostic attribution to PTY
  output log write failure warning and expand regression test to assert
  consecutive failure resilience, on-disk integrity, and write recovery.

## Decisions

- Degrade history, not liveness: unlogged bytes are live-only and vanish
  from served tails on resync. A gap in scrollback beats a frozen terminal.
- Fix inside `ingest` rather than the `handle_output` Err arm: three
  callers share the failure (live path, shutdown drain, sync drain), and
  only ingest can also keep the terminal grid, activity stamp, and
  summarizer tick live. Kept the `Result` return (same as `replay`, which
  is also infallible in practice) for a minimal diff.
- `output_seq` still bumps on failed chunks: it counts broadcast chunks,
  and a stale seq on fresh bytes risks client dedup drops.
- Counters re-sync from `metadata()` on failure because `write_all` may
  persist a prefix first; the baseline is segment-relative for segmented
  logs, where `bytes_logged` is cumulative. Cache is dropped, not patched:
  readers fall back to the file.

## Issues

- Full `cargo test -p triaged --lib`: 8 pairing-test failures reproduce on
  the untouched base (stashed run) — pre-existing, unrelated to ingest.

## Commits

- a469c91 — fix(daemon): keep broadcasting PTY output when the log write fails
- HEAD: fix(triaged): review findings from ingest failure audit

## Progress

- 2026-10-02T18:41-0700: worktree + branch created, plan written (000156-01).
- 2026-10-02T21:41-0700: implemented inside ingest, test red-then-green,
  fmt + clippy clean, full lib suite green except 8 pre-existing pairing
  failures. Branch moved to post-#181 main (42a634e).

## Research & Discoveries

- ENOSPC bursts align with complaint windows: 19k failures in the hour of
  Oct 2 5pm PDT, 5.4k at 11am, 4k Oct 1 2pm. Disk has 46G free now; last
  failure ~80 min before the hunt.

## Lessons Learned

- None yet.

## Next Steps

- Input-reliability branch: preserve leases across handover, lightweight
  re-acquire, attached indicator from socket + lease, client heartbeat.
- Investigate session-261's blocked writer (child not draining stdin).
