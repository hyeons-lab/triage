# 000096 — fix/handover-adoption-timeout

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch fix/handover-adoption-timeout

## Intent

A routine "rebuild the daemon and restart it via handover" failed:

```
Error: writing adoption sync byte (0x01) to old daemon
Caused by: Broken pipe (os error 32)
```

Make handover actually work instead of falling back to `launchctl kickstart -k`,
which kills every live PTY session — the exact outcome handover exists to avoid.

## What Changed

- 2026-07-19T18:30-0700 `crates/triaged/src/handover.rs` — named the three
  handover deadlines (`HANDOVER_TRANSFER_TIMEOUT` 10s Phase 1,
  `HANDOVER_ADOPTION_TIMEOUT` 60s Phase 2 (was 5s), `HANDOVER_TEARDOWN_TIMEOUT`
  10s Phase 3 (was 5s)), so the protocol's whole timing contract reads from one
  place. Added `PHASE1_COMPLETED_AT` + a `gap_ms` field on the Phase-2 log line:
  that gap is what decides whether a handover succeeds, and nothing was
  recording it.
- 2026-07-19T18:30-0700 `crates/triaged/src/ipc.rs` — Phase-2 wait uses the
  shared 60s constant.
- 2026-07-19T18:52-0700 `crates/triaged/src/ipc.rs` — added
  `HandoverInFlightGuard`, a single-flight guard around `handle_handover_server`.
- 2026-07-19T18:57-0700 `crates/triaged/src/ipc.rs` — the Phase-3 `0x02` write is
  now best-effort (warn, still `process::exit(0)`) instead of `?`.
- 2026-07-19T19:00-0700 `crates/triaged/src/main.rs` — comment only, recording
  why `SessionManager::default()` must stay *above* the Phase-2 sync.

## Decisions

- 2026-07-19T18:20-0700 Raise the Phase-2 bound rather than tune it — a
  successor that *dies* closes the socket and the outgoing daemon's read returns
  EOF immediately, so the deadline only ever fires for a successor that is alive
  but slow. Aborting that handover is strictly worse than waiting. The bound
  survives only to stop a wedged successor pinning the outgoing daemon forever.
- 2026-07-19T18:35-0700 Instrument before choosing a value. `Summarizer::spawn`
  and `spawn_poller` only spawn threads, so the initial "the LLM model load
  blocks startup" hypothesis was wrong; measuring beat guessing.
- 2026-07-19T18:52-0700 Refuse concurrent handovers rather than queue them. A
  refused successor falls back to a fresh start and then fails to bind, which is
  loud and harmless; queueing would mean two successors holding dups of the same
  masters.
- 2026-07-19T18:57-0700 Past `detach_all_live_sessions()` the daemon must exit
  unconditionally. The sessions are already gone from the process, so failing to
  deliver `0x02` must not abort the exit.
- 2026-07-19T19:01-0700 On a Phase-3 EOF the successor adopts rather than
  refuses. EOF cannot distinguish "aborted before detaching" (adopting adds a
  second destructive reader) from "detached, `0x02` lost" (refusing strands every
  session). Resolved toward adopting: the first is corruption on a daemon that
  can be restarted, the second is unrecoverable loss.

## Issues

- **The 5s Phase-2 deadline was never adequate.** `ipc.rs` gave the successor 5s
  to send `0x01`; measured gap was 22.6s, consistent across three attempts. Log
  archaeology found a June 28 handover at 8.9s — also over budget. It had been
  passing on luck.
- **The daemon logs nothing by default.** `RUST_LOG` is unset under launchd and
  `~/Library/Logs/triage/*.log` was stale since June; the real JSON log is
  `~/.local/state/triage/triaged.log`. The first two diagnosis attempts produced
  no telemetry at all.
- **Bootstrap constraint.** The 5s is compiled into the *running* daemon, so this
  fix cannot rescue the current swap — it lands via one hard restart and every
  handover after that benefits.
- **Reordered startup, then reverted it.** Review argued the timeout was a
  bandaid and that `SessionManager::default()` (the 22.6s) should move below the
  Phase-2 sync, since `restore_sessions` swallows its errors and cannot abort
  startup. Implemented it, then a follow-up review showed it was a net
  regression, which independent tracing of the startup order confirmed. Until
  the adoption byte goes out the outgoing daemon is **still fully serving**, so
  that 22.6s is warm-up, not downtime. Below the sync the same work becomes: no
  reader on the adopted masters (children block on a full PTY buffer and sessions
  freeze), no process answering clients, and a panic in log replay stranding
  every session with no daemon left. Reverted; kept the reasoning as a comment at
  the call site so it is not re-attempted.
- **Two safe changes that were unsafe together.** Making the `0x02` write
  non-fatal and making a Phase-3 EOF fatal are each defensible, but combined they
  lose every session when a daemon detaches and its `0x02` does not arrive. Only
  the pairing was wrong, which is why it survived review of each change alone.

## Research & Discoveries

- The handover protocol is a two-phase commit. `0x01` is the point of no return:
  before it the outgoing daemon bails, skips teardown and keeps serving; after it
  there is no rollback. Everything that can abort the successor's launch must
  therefore stay above the sync.
- The 22.6s is `SessionManager::default()` → `restore_sessions` → per **historical**
  session: full log read, replay through the terminal emulator, and three
  blocking `git` subprocesses. These are dead sessions the handover does not even
  transfer.
- It grew ~9s (June) → 22.6s (July) because it scales with accumulated session
  logs. 60s buys headroom, not a permanent fix.
- Smart-start means *any* `triaged` invocation attempts a handover against the
  live daemon — including the `launchctl kickstart -k` an operator runs when a
  swap looks stuck. That is what makes the concurrent-handover race reachable
  rather than theoretical.

## Next Steps

- Make the historical-session restore lazy or cheaper. It is the actual root
  cause; the gap grows on the same trajectory that breached 5s, and `gap_ms` now
  makes that trend visible.
- Consider a distinct "committed to teardown" signal so a Phase-3 EOF can be
  disambiguated, which would let the successor refuse safely in the
  aborted-before-detach case.

## Commits

- HEAD — fix(triaged): stop the 5s adoption deadline from aborting valid handovers
