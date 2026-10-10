# 000161: fix/context-list-fanout

## Agent

2026-10-04T07:59-0700.

## Intent

`list_session_contexts` fans in to every live session actor with sequential,
unbounded blocking round-trips. Under CPU pressure the rail load degrades to
the SUM of all actor scheduling latencies (measured 2839ms for 68 sessions at
load ~150 vs 98ms unloaded), and one wedged actor would hang the whole batch
forever. Fan the round-trips out concurrently and bound each with a timeout so
session loading degrades to the slowest actor instead of stalling.

## What Changed

- `crates/triaged/src/session.rs`: `list_session_contexts` resolves live
  actors across scoped threads with a per-actor receive timeout; a timed-out
  or dead actor yields `None` context like the mid-shutdown case already did.
- `crates/triaged/src/session.rs`: audited `list_session_contexts` fan-out pipeline;
  streamlined sources collection into rows directly, eliminating the intermediate
  `pending` vector and enum; wrapped receivers in mutex slots so legs falling back
  on thread allocation error under load can reclaim the receiver for synchronous
  receive with timeout; added structured `tracing::warn!` diagnostics on actor send
  failures, actor errors, timeouts, and channel disconnections; updated
  `list_session_contexts_survives_a_wedged_actor` unit test to use hermetic git
  repository fixtures, named the wedged actor `session-0` to verify head-of-line
  non-blocking, and asserted lower elapsed duration bounds.

## Decisions

- `std::thread::scope` fan-out, not async: the actor round-trip is blocking
  std-mpsc `recv`, and the `SessionApi` surface is sync. Scoped threads keep
  the change local to the one batch call site.
- Timeout via `recv_timeout`, not a change to `recv_actor_result`: other call
  sites (snapshot, attach) intentionally block; only the batch fan-out gets a
  bound, since one slow session must not fail the other 67 rows.

## Issues

- Trigger: sibling session's test hung at ~880% CPU, pushing machine load
  to ~150. Reniced to +20 (user-approved); test keeps running but yields.

## Commits

- 6208f56: fix(daemon): fan out list_session_contexts actor round-trips with timeout
- d91caa4: docs(devlog): record 190 deploy probe results
- HEAD: fix(daemon): review findings from context-list-fanout audit

## Progress

- 2026-10-04T07:59-0700: diagnosed (pair 80ms, hello 6ms, list 1ms, contexts
  2839ms @ load 150 -> 98ms after renice); branch cut from stack top.
- 2026-10-04T08:21-0700: implemented scoped-thread collect + 5s per-leg
  timeout. New test hangs pre-fix (killed at 90s, zero output) and passes in
  ~6s with the fix; existing order test green; fmt + clippy clean.
- 2026-10-04T08:52-0700: PR 190 open (stack 6/6), CI green. Release-built with
  Flutter bundle, installed, reloaded: 68 sessions preserved, CTX_MS 67 at
  load ~150 (was 2839 pre-fix), served bundle md5 matches fresh build, no
  panics. PR 189 CI also green.
- 2026-10-09T21:58-0700: completed review fix loop (2 rounds, clean confirmation
  round across all 8 pillars); resolved thread spawn exhaustion fallback,
  structured diagnostics, and test hermeticity; cargo fmt, clippy, check, and
  test all passing.

## Research & Discoveries

- `request_session_context` -> `recv_actor_result` uses unbounded `rx.recv()`;
  the sequential loop in `list_session_contexts` is the only batch-shaped
  caller, so it is the only site that needs the timeout.

## Lessons Learned

- A batch RPC over N actors must cost max(latency), never sum(latency), and
  must bound each leg, or one wedged actor (cf. session-261's blocked writer)
  wedges every client's rail load.

## Next Steps

- Land behind the 184-189 stack; deploy via reload and re-probe the load path.
