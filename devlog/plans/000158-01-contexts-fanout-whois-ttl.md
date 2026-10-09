# 000158-01: Fan out contexts; stretch whois TTL

## Thinking

`list_session_contexts` sends one actor `Context` command and blocks for
its reply before sending the next: 66 sequential round-trips at ~5.6ms
each is the measured 373ms, and on the daemon's serial per-connection
queue it delays the attach behind it by the same amount. Actors are
independent, so the batch fans out exactly: send all commands, then
collect all replies in session order. Failure semantics stay identical
(a mid-shutdown actor yields `None`, never fails the batch) because the
collect step keeps the same `.ok().flatten()`.

The whois cache TTL is 10s, so any reconnect past that pays a 308ms
subprocess. Tailnet IP→login mappings change only when nodes or users
change (rare), while reconnects (and their storms) are common. 300s
keeps the fail-closed shape (negative TTL untouched at 1s) and makes
reconnect pairs free. Only the ordering assert references the const, so
no test churn.

Not in scope: WS compression (no API in tungstenite 0.24, which would need
an upgrade or hand-rolled extension negotiation), lazy history (own
branch next), per-request server concurrency (reordering + error-path
care; noted as follow-up).

## Plan

1. Restructure `list_session_contexts` into send-all/collect-all,
   preserving order and the `None`-on-shutdown semantics.
2. Bump `WHOIS_CACHE_TTL` 10s → 300s with a rationale comment.
3. Run the contexts/adopt/tailscale tests plus `cargo fmt`, `cargo
   clippy -p triaged --all-targets -- -D warnings`.
4. Baseline is captured (`list_contexts` 373ms, 66 sessions, live
   daemon on the old binary). Re-run `/tmp/perf_probe.mjs` after deploy
   for the after number.
5. Devlog, commit, push with explicit refspec, stacked PR on PR 185.
