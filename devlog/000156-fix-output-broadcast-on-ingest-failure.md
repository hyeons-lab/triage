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
- 2026-10-14T12:29-0700 (agent-review-loop round 1, 9 findings): snapshot
  sequence no longer overclaims unlogged bytes (new `logged_output_seq`
  stamped by history-bearing snapshots); per-chunk failure warnings latched
  per episode with unlogged-byte accounting and a recovery `info!`; counter
  reconcile extracted as `reconcile_log_counters` (credits persisted
  prefixes, rebases both counters down on shrink, warns on stat failure at
  recovery); failure path runs trim/rotation bound enforcement (rotation
  defers while writes fail); log cache re-seeded on recovery when the log
  fits the cache budget; `note_persisted` extracted for the paired counters.
  Tests: reconcile prefix/cap/shrink and segmented-baseline tables,
  segmented failed-ingest counters, history-snapshot sequence pinning, and a
  Linux-only actor-level broadcast test against /dev/full (verified locally
  with a healthy sink; macOS has no /dev/full). Mutant check: forcing the
  cumulative baseline for segmented logs fails the two new segmented tests.
  Full lib suite: 338 passed, 8 pairing failures byte-identical to the
  untouched PR head; one handover test failed once on the base run and
  passes standalone (flaky, unrelated).
- 2026-10-14T13:10-0700 (agent-review-loop round 2, 12 findings): the
  snapshot pairing is now byte-exact — a new `logged_tail_bytes` watermark
  (end of the last fully persisted chunk) bounds the served tail, and both
  tail readers honor the end offset (`take()` on the single-file read; new
  `storage::read_multi_segment_range` across segments) instead of reading
  to EOF. The logged stamp advances only when the counters were actually
  credited (stat-failure recovery no longer stamps). Handover carries both
  watermarks (`ExtractedHandover` + serde-defaulted `HandoverSession`
  accessors with live-counter fallback for pre-field blobs; adoption
  re-stamps them after tail replay, pinned by the adopted-runtime test).
  Bound enforcement is episode-aware: rotation attempted once as an episode
  opens, trim deferred to recovery, trim latch re-armed on recovery,
  `enforce_log_bounds` extracted. Unrecovered loss is warned at output end,
  shutdown, and handover. Cache reseed retries while pending (segmented and
  over-budget skips pinned); one `LOG_CACHE_MAX_BYTES` constant. Tests added:
  partial-persist tail serving + unlogged subtraction, deferred trim,
  rotate-once-per-episode, reseed skips; unbounded-read mutant fails the
  partial-persist test. Known residual (documented on `SessionSnapshot`):
  after recovery the stamp covers the tail end while a chunk dropped
  mid-episode remains absent from the stream's middle — indistinguishable
  from a truncation to re-emulation; a wire-level gap signal is follow-up
  work for the client stack, not this PR. Suite: 342 passed, same 8
  pre-existing pairing failures.
- 2026-10-14T13:54-0700 (agent-review-loop round 3, 16 findings): the new
  segment range reader gained the raw→compressed fallback its siblings have
  (a snapshot racing compression no longer serves empty history); tail reads
  now distinguish failure from emptiness (`Option`), and a failed read stamps
  no coverage instead of pairing seq with an empty tail. Bounds wait for
  credited counters (stat-failed recovery no longer trims mid-episode).
  Unrecovered-loss reporting consumes its count (exactly-once across output
  end / shutdown / actor stop) and fires at the actor's terminal point rather
  than at handover extraction. Cache re-seed is tri-state with a 3-attempt
  bound; the watermark pair is one `mark_fully_persisted` helper;
  `read_multi_segment_tail` is now a wrapper over the range walk, which also
  reports the actual first-byte offset. A cfg(test) thread-local metadata
  seam pins the stat-failure gate. Tests: storage range/fallback/compressed
  slicing, segmented snapshot pairing, stat-failed recovery (stamp + trim),
  re-seed refusal/retry, trim re-arm, shrink watermark clamps, legacy-blob
  fallback, loss-report consumption. Deferred as a nitpick: the range walk
  is O(segment count) per snapshot where the old tail walk was O(tail).
  Suite: 353 passed, same 8 pre-existing pairing failures.
- 2026-10-14T14:05-0700 (agent-review-loop round 4, 8 findings, none above
  quality): unrecovered-loss reporting for handovers moved to the commit
  point — `ExtractedHandover`/`serialize_active_sessions` carry the counts
  and the handover handler warns synchronously after the commit byte lands,
  before detach and `process::exit`; aborted handovers report nothing. The
  failed-tail snapshot pin is no longer vacuous (pre-claimed snapshot is
  zeroed observably); the re-seed bound is a named constant with a give-up
  warning, attempts only on credited counters, and per-episode reset, all
  pinned; `replay_tail`'s watermark re-stamp is asserted in both legs; a
  short (non-erroring) tail read now also claims no coverage (clamped read +
  overlay short-tail arm); the compressed clamp-and-slice is one helper.
  Suite: 354 passed, same 8 pre-existing pairing failures.
- 2026-10-19T06:17-0700 (agent-review-check-ci): gate `SerializedHandover` in `crates/triaged/src/session.rs` and its import in `crates/triaged/src/ipc.rs` with `#[cfg(unix)]` so Windows builds (`Test (windows-latest)`) do not fail with `E0433: cannot find unix in os` on `std::os::unix::io::RawFd` or emit an unused-import warning on `SerializedHandover`.

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
- Round 1 refinement of the sequence decision: `output_seq` still bumps on
  failed chunks (live dedup needs it), but history-bearing snapshots stamp
  `logged_output_seq` — the last fully persisted chunk — because client
  dedup treats the snapshot sequence as "covered by the tail" and would
  drop queued live copies of unlogged chunks. The write itself is still
  attempted per chunk (fails fast, doubles as the recovery probe); only the
  warning latches per episode. The `Result` return on `ingest` is retained
  deliberately (noted at the fn) rather than churned across every caller.

## Issues

- Full `cargo test -p triaged --lib`: 8 pairing-test failures reproduce on
  the untouched base (stashed run) — pre-existing, unrelated to ingest.

## Commits

- a469c91: fix(daemon): keep broadcasting PTY output when the log write fails
- eb56815: fix(triaged): review findings from ingest failure audit
- ab9cdc0: fix(triaged): complete ingest-failure review hardening
- a4498b7: docs(devlog): record ingest-failure review rounds 2-8
- HEAD: fix(triaged): gate SerializedHandover behind cfg(unix) for Windows builds

## Progress

- 2026-10-02T18:41-0700: worktree + branch created, plan written (000156-01).
- 2026-10-02T21:41-0700: implemented inside ingest, test red-then-green,
  fmt + clippy clean, full lib suite green except 8 pre-existing pairing
  failures. Branch moved to post-#181 main (42a634e).
- 2026-10-14T19:41-0700: review loop rounds 1-5 (agent-review-loop, high).
  Round 5: replaced the extraction-copied handover loss list with a
  `TakeUnrecoveredLoss` actor command the handler sends after the commit
  byte; `SerializedHandover` became a named struct; short-tail overlay arm
  and take-consumption tests added; `read_multi_segment_range` narrowed to
  `pub(crate)`. Gates: fmt clean, clippy clean, 355 lib tests passing with
  the same 8 pre-existing pairing failures. Round 6 review pending.
- 2026-10-14T20:47-0700: review round 6 (3 quality, 5 nitpick). Fixes:
  `take_unrecovered_losses` now snapshots actor senders under the lock and
  waits off-lock, logs timeout/disconnect/send-failure distinctly instead
  of swallowing non-answers, takes only the transferred session set
  (threaded from the handler's serialized state), and is `pub(crate)`;
  `HANDOVER_EXTRACT_BUDGET` renamed `HANDOVER_ACTOR_BUDGET` and documented
  as shared by both handover fan-outs; the overlay's short-read and
  failed-read arms merged. New manager-level Linux test pins the fan-out
  (degraded vs healthy, transferred-set restriction, consume-once), and
  the actor take test's exited leg now asserts a post-exit take answers
  zero on the still-open channel — the old probe leg used the consuming
  command itself to detect worker exit and would never have terminated
  against a worker that keeps serving commands after exit. Gates: fmt
  clean, clippy clean, workspace check clean, docs clean, 355 lib tests
  passing with the same 8 pre-existing pairing failures (one flaky
  handover recovery test failed once in a filtered run and passed 5/5
  standalone reruns; also recorded failing once on the untouched base).
  The two `/dev/full` tests are Linux-gated and unverified on this macOS
  host; they run in Ubuntu CI. Round 7 review pending.
- 2026-10-14T20:52-0700: review round 7 clean at quality — 3 nitpicks
  remained. Addressed all three: transferred-set membership now uses a
  `HashSet`; the shared-budget comment now states the two distinct
  successor waits (Phase-1 transfer read for the extract, Phase-3
  teardown for the take) with a compile-time assert against each; and
  the shutdown/terminal loss-report call sites now carry review-only
  notes explaining why their consumption cannot be observed by a test
  (the output-end site is pinned by the post-exit take leg). Gates: fmt
  clean, clippy clean, workspace check clean, docs clean, 355 lib tests
  passing with the failure set byte-identical to the pre-existing
  pairing baseline. Round 8 confirmation review pending.
- 2026-10-14T21:10-0700: review round 8 (confirmation) returned zero
  findings across all four lenses; the agent-review-loop for this PR is
  complete. The two Linux-gated `/dev/full` tests remain
  execution-unconfirmed on macOS and rely on Ubuntu CI.

## Research & Discoveries

- ENOSPC bursts align with complaint windows: 19k failures in the hour of
  Oct 2 5pm PDT, 5.4k at 11am, 4k Oct 1 2pm. Disk has 46G free now; last
  failure ~80 min before the hunt.

## Lessons Learned

- Exactly-once diagnostics need ownership transfer at the commit point, not
  a copy at extraction: a copied count is reported again by the producer's
  exit backstop whenever teardown races `process::exit`.
- Pin the carriage through the production entry point, not only the
  consuming helper — a helper-only test stays green when its call site is
  deleted.

## Next Steps

- Input-reliability branch: preserve leases across handover, lightweight
  re-acquire, attached indicator from socket + lease, client heartbeat.
- Investigate session-261's blocked writer (child not draining stdin).
