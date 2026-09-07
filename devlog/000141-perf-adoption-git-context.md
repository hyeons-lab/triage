# 000141: perf/adoption-git-context

## Agent

Claude Opus 5, 2026-09-05T22:09-0700.

## Intent

Remove the per-session `git` subprocess cost from handover adoption, which is the daemon's
stop-the-world window and the cause of the freezes observed during normal use.

## Research & Discoveries

Analysis of 148,989 lines of `~/.local/state/triage/triaged.log` (2026-06-21 to 2026-09-06):

- Adoption is linear at ~285ms/session, stable across every session-count bucket from 3 to
  33 (270–330ms/session). Handover duration: median 3.4s, p90 16.6s, max 298s.
- 826 handovers logged; 80% follow another within 60s and 516 within 10s, alongside 478
  `Refused a concurrent handover` and 419 `serving another handover; retrying`. Total
  stop-the-world adoption time in the log: 19.6 minutes across 327 windows.
- The tool-call judge is *not* implicated: Metal is linked in the running binary and only
  2.7% of 121,995 judged calls reached the model (113,077 hit `allow_rule`).
- Actor round-trips are already correctly performed off-lock via the `Resolved` enum, so
  steady-state request handling is not the problem; the daemon answered HTTP in 1–20ms
  while holding 32 live sessions.
- The live manifest has 32 sessions across only 14 distinct cwds, so per-session git
  resolution is largely redundant work.

Separately observed, not addressed here:

- 22.7% of judged tool calls (27,681 of 121,995) are duplicates (same session, tool and
  command within 200ms.
- 123 open ptmx descriptors for ~32 sessions (~3.7/session), which is the territory of the
  in-flight `000122-fix-handover-owned-fds` work.

## What Changed

- `resolve_session_context` is memoized by directory behind a 500ms window
  (`SESSION_CONTEXT_TTL`). Git branch is a property of the worktree, not the session, so
  coalescing sessions that share a directory is exact. The window stays under
  `CWD_POLL_INTERVAL` (750ms) so branch-switch detection keeps its existing granularity, and
  it expires rather than persisting so the cache self-heals when a directory becomes or
  stops being a repository.
- Handover adoption no longer resolves git context while holding the session-manager lock.
  `adopt_one_session` installs each actor with no context and returns a
  `PendingSessionContext`; once the guard is dropped, `resolve_adopted_contexts` resolves
  them on its own thread and delivers each through a new fire-and-forget
  `ActorCommand::SetContext`. Clients receive them through the same broadcast a branch
  switch uses.
- Added a debug-level per-handover line reporting how long the locked install phase took and
  its per-session cost, so the remaining window is measurable rather than inferred.

## Decisions

Rejected restructuring `adopt_sessions` into off-lock prepare / on-lock install phases. The
conflict-rename decision must happen under the lock before `spawn_adopted_pty_runtime` opens
the renamed log, so the split needs three phases and opens a window where another thread can
claim a session id between the rename and the insert. Not worth it for the git work alone:
but see Next Steps, because the measurement changed what is at stake.

## Progress

Measured against the live session distribution (32 sessions across 14 distinct cwds):

- Git work for one adoption, warm and idle: 1.33s uncached -> 0.55s cached (2.4x).
- Locked adoption window, release build, real multi-MB session logs: **215ms/session**,
  against a production baseline of 285ms/session. 32 sessions: ~9.1s -> ~6.9s.

`cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings` and
`cargo test --workspace -- --test-threads=1` all clean (0 failures).

## Issues

- 2026-09-06T17:00-0700 Review on #164 found that `session_context_reuses_recent_resolution` put a `git checkout` subprocess between the cache write and the staleness assertion, so a slow or contended runner could expire the 500ms window and flip the result. The staleness assertion is now made only when the window is measurably still open; the expiry half stays unconditional, so the miss path is still covered on every run.
- 2026-09-06T12:20-0700 Review on #164 flagged `Instant::duration_since`, which panics when the earlier instant is later than `self`. `Instant` is monotonic under normal OS conditions but not across VM migration, hypervisor suspend, or container wake, so both cache-window comparisons now use `saturating_duration_since`. Also documented that `clear_session_context_cache` mutates process-wide state and depends on the suite running single-threaded.
- 2026-09-06T10:11-0700 Rebased onto `origin/main` at 892c91e and renumbered from 000137 to 000141, since main had since taken 000137 (session tab scroll cache) and 000140 is claimed by the open PR #161. One conflict, in `adopt_one_session`: main had added session-id canonicalization that resolves the active segment for a recovered id, which #158's segmented storage needs, while this branch changed the signature to return `PendingSessionContext`. Both were kept, the canonicalization ahead of the conflict check.
- 2026-09-06T10:11-0700 Verified the change is still needed rather than superseded. Main's `adopt_sessions` still takes the session-manager lock once and calls `resolve_session_context` per session inside `adopt_one_session`, and no `SetContext` command, directory cache, or install-phase timing exists there. `REPLAY_TAIL_CAP` is still `MAX_SESSION_LOG_BYTES` at 16 MiB on main, so #158's 8 MiB figure is the segment size and does not shrink the replay tail this measured.

## Commits

- f2dbacb: perf(daemon): take git context resolution off the adoption lock
- eec1ad3: fix(daemon): use saturating_duration_since for the context cache window
- HEAD: test(daemon): stop the cache test depending on how fast git checkout runs

## Lessons Learned

The git subprocesses were the visible cost but not the dominant one. Removing them entirely
only accounts for ~70ms of the 285ms/session; the remaining ~215ms is
`spawn_adopted_pty_runtime` reading and VT-parsing each session's replay tail, bounded by
`REPLAY_TAIL_CAP`, which is `MAX_SESSION_LOG_BYTES`, i.e. **up to 16MB per session, parsed
serially while the global session-manager lock is held**. Attributing the freeze to the git
forks alone would have been wrong; the per-phase timing added here exists so the next such
question is answered by measurement rather than inference.

## Next Steps

The freeze is only 25% addressed. The remaining 75% is the replay-tail parse under the lock.
The promising fix is to move the replay out of `spawn_adopted_pty_runtime` and into the
session actor's own startup: the worker thread replays its tail as its first action, before
entering its command loop, so commands queue behind it and no client can observe a
pre-replay terminal. That turns 32 serial 215ms parses under one lock into 32 parallel
per-session parses under none: ~6.9s of global freeze becomes ~215ms of per-session
latency. It also subsumes the cwd handling, since `replayed_working_directory` is derived
from that same parse.
