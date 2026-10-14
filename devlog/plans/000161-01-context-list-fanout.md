# 000161-01 — Fan out `list_session_contexts` actor round-trips

## Thinking

The load-path probe isolated the slowness to one RPC: `list_session_contexts`
took 2839ms at load ~150 while pair/hello/list/layout stayed under 120ms
(and contexts dropped to 98ms once the hog was reniced). Reading the handler
shows why: it clones each live session's actor channel, then walks the 68
sources sequentially, each doing a blocking std-mpsc request/response
(`ActorCommand::Context` + unbounded `recv`). Cost is the sum of 68 scheduling
latencies, and any actor that never answers (wedged child, blocked writer)
hangs the entire rail load with no bound.

The fix has two independent halves, both local to this call site:

1. Concurrency: resolve the live legs with `std::thread::scope`, one thread
   per live actor. Threads fit because the legs are blocking `recv`s and the
   surrounding API is sync; scoped threads avoid lifetime plumbing.
2. Bound: add a `recv_timeout` variant used only here (5s — ~100x the ~40ms
   per-leg cost measured under extreme load). Timeout, disconnect, and actor
   error all collapse to `None` context, matching the existing mid-shutdown
   behavior, so the row still renders with a fallback title.

No protocol change: response shape is identical, rows just arrive faster and
incomplete rather than never.

## Plan

1. Add `SESSION_CONTEXT_REQUEST_TIMEOUT` const and a timeout-bounded
   `request_session_context` variant in `crates/triaged/src/session.rs`.
2. Rewrite the `sources` collection loop in `list_session_contexts` to fan
   live legs out over `std::thread::scope`, preserving creation-order output.
3. Add a regression test: a live session whose actor never answers still
   yields a row (context `None`) within the bound while other rows resolve.
4. Gates: `cargo fmt`, `cargo clippy -p triaged --all-targets -- -D warnings`,
   focused `cargo test -p triaged` session tests.
5. Commit, push with explicit refspec, open PR stacked on #189, extend the
   gh-stack tracking.
6. Release-build, install, `triaged reload`, re-probe `CTX_MS` plus an
   attach to confirm no regression.
