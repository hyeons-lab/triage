# 000161 — fix/context-list-fanout

## Agent

Muse Code powered by Meta Muse Spark, session fern-metis.

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

## Decisions

- `std::thread::scope` fan-out, not async: the actor round-trip is blocking
  std-mpsc `recv`, and the `SessionApi` surface is sync. Scoped threads keep
  the change local to the one batch call site.
- Timeout via `recv_timeout`, not a change to `recv_actor_result`: other call
  sites (snapshot, attach) intentionally block; only the batch fan-out gets a
  bound, since one slow session must not fail the other 67 rows.

## Issues

- Trigger: sibling Claude Code session's cera `sortformer_parity` test hung at
  ~880% CPU, pushing machine load to ~150. Reniced to +20 (user-approved);
  test keeps running but yields. Sibling session not notified (Claude Code CLI
  harness, not a Muse peer; no triage-mcp tools in this session to send mail).

## Commits

- HEAD — fix(daemon): fan out list_session_contexts actor round-trips with timeout

## Progress

- 2026-10-04T07:59-0700: diagnosed (pair 80ms, hello 6ms, list 1ms, contexts
  2839ms @ load 150 → 98ms after renice); branch cut from stack top.
- 2026-10-04T08:21-0700: implemented scoped-thread collect + 5s per-leg
  timeout. New test hangs pre-fix (killed at 90s, zero output) and passes in
  ~6s with the fix; existing order test green; fmt + clippy clean.

## Research & Discoveries

- `request_session_context` → `recv_actor_result` uses unbounded `rx.recv()`;
  the sequential loop in `list_session_contexts` is the only batch-shaped
  caller, so it is the only site that needs the timeout.

## Lessons Learned

- A batch RPC over N actors must cost max(latency), never sum(latency) — and
  must bound each leg, or one wedged actor (cf. session-261's blocked writer)
  wedges every client's rail load.

## Next Steps

- Land behind the 184–189 stack; deploy via reload and re-probe the load path.
