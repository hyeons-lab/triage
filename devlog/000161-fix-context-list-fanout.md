# 000161: fix/context-list-fanout

## Agent

Muse Code powered by Meta Muse Spark, session fern-metis.

## Intent

`list_session_contexts` fans in to every live session actor with sequential,
unbounded blocking round-trips. Under CPU pressure the rail load degrades to
the SUM of all actor scheduling latencies (measured 2839ms for 68 sessions at
load ~150 vs 98ms unloaded), and one wedged actor would hang the whole batch
forever. Fan the round-trips out concurrently and bound the batch with a
timeout so session loading degrades to the slowest actor instead of stalling.

## What Changed

- `crates/triaged/src/session.rs`: `list_session_contexts` enqueues all
  `ActorCommand::Context` requests in a single pass and collects replies
  against a shared `SESSION_CONTEXT_REQUEST_TIMEOUT` deadline (matching
  `serialize_active_sessions`); a timed-out or dead actor yields `None` context
  like the mid-shutdown case already did.
- `crates/triage-core/src/session.rs`: document `SessionContextRow::context`
  degradation on shutdown or batch timeout.

## Decisions

- Shared batch `Instant` deadline over pre-enqueued actor channels rather than
  spawning one OS thread per live session with `std::thread::scope`: because
  each live session already runs on its own worker thread and all `Context`
  commands are sent before waiting starts, sequential `recv_timeout` against one
  shared deadline still costs `max(latency)` capped at
  `SESSION_CONTEXT_REQUEST_TIMEOUT` without `O(N)` thread-spawn overhead or
  `Scope::spawn` panic risk on `EAGAIN`.
- Timeout via `recv_timeout`, not a change to `recv_actor_result`: other call
  sites (snapshot, attach) intentionally block; only the batch fan-out gets a
  bound, since one slow session must not fail the other 67 rows.

## Issues

- Trigger: sibling Claude Code session's cera `sortformer_parity` test hung at
  ~880% CPU, pushing machine load to ~150. Reniced to +20 (user-approved);
  test keeps running but yields. Sibling session not notified (Claude Code CLI
  harness, not a Muse peer; no triage-mcp tools in this session to send mail).

## Commits

- 9b52d8d: fix(daemon): fan out list_session_contexts actor round-trips with timeout
- 104382a: docs(devlog): record 190 deploy probe results
- HEAD: fix(daemon): collect list_session_contexts against shared deadline without thread fan-out

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
- 2026-10-18T16:04-0700: replaced per-session `std::thread::scope` spawns and
  two-pass `PendingContext` buffering in `list_session_contexts` with a
  single-pass fan-out and shared `Instant` deadline, made
  `list_session_contexts_survives_a_wedged_actor` hermetic with a scratch git
  repo, and covered wedged actors sorting both before and after a healthy
  session.

## Research & Discoveries

- `request_session_context` -> `recv_actor_result` uses unbounded `rx.recv()`;
  the loop in `list_session_contexts` is the only batch-shaped caller, so it is
  the only site that needs the timeout.

## Lessons Learned

- A batch RPC over N actors must cost max(latency), never sum(latency), and
  must bound the batch against a shared deadline, or one wedged actor (cf.
  session-261's blocked writer) wedges every client's rail load.

## Next Steps

- Land behind the 184–189 stack; deploy via reload and re-probe the load path.
