# 000101-01 — handover session logging

## Thinking

The 2026-07-21 cera deploy left an unanswered question: did a handover lose
session shells? It could not be answered from `~/.local/state/triage/triaged.log`
because the log records only `Adopting N inherited live sessions` — a count. No
session id, no PID, and nothing at all when a child dies or when a dead `Live`
session is demoted to `Historical` (`demote_dead_live_session` logs only a
`warn!` on a failed reap, never on success).

So the log cannot distinguish three very different outcomes:

1. a session adopted and still running,
2. a session adopted whose shell was already dead before the swap,
3. a session whose shell died *because of* the swap.

Only (3) would be a handover bug, and it is the one the log is blindest to.

The fix is small and belongs in three places, each the single funnel for its
event:

- `adopt_sessions` — per-session line with `session_id`, `pid`, `command`, so
  adoption is attributable instead of aggregate.
- `broadcast_completed` — the one place every exit path converges, so one line
  covers all of them.
- `demote_dead_live_session` — the moment a shell is provably gone and the
  session is made restorable.

This is observability, not behaviour: no control flow changes, so the risk is
confined to log volume. Volume is bounded by session count (~13 per handover),
and these are one-shot lifecycle events rather than per-output logging, so
`INFO` is the right level.

## Plan

1. Branch `fix/handover-session-logging` from `chore/cera-0-3-1` rather than
   `main`, so the test binary keeps cera 0.3.1 and installing it does not
   downgrade the live daemon. Rebase onto `main` once #118 merges.
2. Add the three `tracing::info!` calls described above, each with a comment
   explaining what question it exists to answer.
3. Build release, install by replacing the inode (`rm` then `cp` — `cp` over a
   running binary invalidates its signature cache and gets it SIGKILLed), and
   verify `--version`.
4. Capture the pre-state: the daemon PID, its children with `pid,command`, and
   the current log length.
5. Run one `triaged --handover`. Expect **two** handovers, not one: the
   LaunchAgent is `KeepAlive`, so launchd respawns the job the handover tears
   down and the respawned daemon hands over again. Do not try to suppress it by
   booting out the agent — that would SIGTERM the live daemon and destroy the
   sessions being measured. The per-session logging makes both adoptions
   individually attributable, which is sufficient.
6. Analyse: for every adopted `(session_id, pid)`, check whether the PID is
   still alive and what its parent is; correlate against `session child exited`
   and demotion lines.
7. Run the full CI gate set locally before committing.
