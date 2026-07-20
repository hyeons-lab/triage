# Plan: fix the handover Phase-2 adoption timeout

## Thinking

A routine "rebuild + handover" of the daemon failed with:

```
Error: writing adoption sync byte (0x01) to old daemon
Caused by: Broken pipe (os error 32)
```

Tracing the protocol:

- `ipc.rs:773` (old daemon) — after shipping state + FDs in Phase 1, the old
  daemon sets a **5s read timeout** waiting for the successor's `0x01` adoption
  byte, then `bail!`s on timeout, which drops the socket.
- `handover.rs:251` (new daemon) — the successor writes `0x01` in
  `complete_handover_adoption()`. By then the old daemon has already gone, so
  the write hits a closed socket → `EPIPE`.

So the successor is simply slower to reach Phase 2 than the old daemon is
willing to wait. The old daemon survives (good — no session loss), but the
swap never happens and the only way to land new code is a hard
`launchctl kickstart -k`, which kills every live PTY session. That is exactly
what handover exists to avoid.

Why the 5s deadline is wrong in principle, independent of which startup step is
slow: a successor that **dies** closes its socket, and the old daemon's
`read_exact` then returns EOF *immediately*. Death is already signalled by EOF.
The timeout therefore only ever fires for a successor that is alive but slow —
and for that case aborting is the worst response, because it strands the
handover and forces the destructive restart. The correct behaviour is to wait.

The deadline still has a job: a successor that is alive but wedged (deadlocked
before Phase 2) must not pin the old daemon forever. So keep a timeout, but set
it generously enough to cover real successor startup rather than tuned to a
guess.

Initial suspicion was that the summarizer's LLM model load blocked startup, but
`Summarizer::spawn` (summarizer.rs:95) only spawns a worker thread — the model
loads off the main path. `start_update_poller` and `start_cwd_persistence`
likewise document themselves as non-blocking. So the real cost between Phase 1
(main.rs:218) and Phase 2 (main.rs:333) is not yet established, and the daemon
runs without `RUST_LOG`, so nothing was captured from the failure.

Rather than guess, instrument the gap and measure it. The timing log is worth
keeping permanently: it is the one number that decides whether a handover will
succeed, and without it the next failure is just as opaque as this one.

Note the bootstrap constraint: the 5s deadline is baked into the *currently
running* daemon, so this fix cannot rescue the current swap. It lands via one
hard restart; every handover after that benefits.

## Plan

1. Add timing instrumentation to the successor: record the instant Phase 1
   completes and log the elapsed time when `complete_handover_adoption()` sends
   `0x01`. Keep it as permanent tracing, not scaffolding.
2. Raise the old daemon's Phase-2 read timeout (`ipc.rs:773`) from 5s to a
   generous bound, and comment *why* it is generous — EOF covers successor
   death, so the timeout only guards a wedged successor.
3. Build and re-run the handover against the live daemon. It is expected to
   fail again (the running daemon still enforces 5s), but the successor's new
   timing log reveals the actual Phase-1 → Phase-2 gap. Confirmed safe to
   retry: the failed attempt left the old daemon healthy with all sessions.
4. Use the measured gap to sanity-check the new bound. If the gap is
   pathological (tens of seconds) rather than merely over 5s, treat that as a
   separate startup bug and reconsider before settling.
5. Validate: `cargo fmt --check`, `clippy -D warnings`, `RUSTDOCFLAGS="-D warnings" cargo doc`, `cargo test`.
6. Run `/review-fix-loop max` until clean.
7. Land via one `launchctl kickstart -k`, then verify the new daemon is serving.
