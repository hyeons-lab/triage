# 000158: perf/load-quick-wins

## Agent

Muse Code (muse-spark), 2026-10-03.
Antigravity @ triage branch perf/load-quick-wins, 2026-10-18T13:10-0700.

## Intent

Session loading is slow on the user's connection. Measured the load
path against the live daemon (66 sessions): `list_session_contexts`
373ms (66 sequential actor round-trips), attach 53ms locally but
282KB-1MB+ uncompressed over the wire, everything else ≤16ms. WS
permessage-deflate is unavailable (tungstenite 0.24 has no compression
API), whois is already cached, and startup awaits are already parallel,
so the quick wins are: fan out the contexts round-trips, and stretch
the whois TTL so reconnects stop paying 308ms cold. Stacked on
`fix/input-reliability` (PR 185) so deploys stay coherent. Lazy history
paging follows as the transfer fix on its own branch.

## What Changed

- `list_session_contexts` sends all actor `Context` commands before
  collecting any reply (was: 66 sequential round-trips).
- `WHOIS_CACHE_TTL` 10s → 300s so reconnect pairs stop paying the
  ~300ms subprocess.
- Batch-shape guard test: one row per session in sort-key order, each
  carrying its own resolved git branch context.

## Decisions

- Fan-out keeps the exact failure semantics (mid-shutdown actor yields
  `None`, batch never fails) and the sorted collection order; the only
  observable change is latency.
- Negative whois TTL stays 1s: only the success path gets cheaper.
- No WS compression in this branch: tungstenite 0.24 has no
  permessage-deflate API. An upgrade or hand-rolled negotiation is a
  bigger, riskier change than the transfer problem needs: lazy history
  (next branch) removes the bytes instead of squeezing them.

## Issues

- Full lib suite: same 8 pre-existing pairing failures as the base.

## Commits

- 76fe279: perf(daemon): fan out session contexts, stretch whois TTL
- HEAD: test(triaged): verify per-session context pairing in fan-out test

## Progress

- 2026-10-03T21:44-0700: worktree + branch created from 68f1800
  (stacked on PR 185), measured, plan written (000158-01).
- 2026-10-03T21:52-0700: implemented; 13 contexts + 18 tailscale tests
  green, fmt + clippy clean, full suite green except the 8 pre-existing
  pairing failures. Baseline `list_contexts` 373ms captured for the
  post-deploy comparison.
- 2026-10-18T13:10-0700: cascaded onto PR #185 (`ebfe15b`) and ran stack
  review loop Round 1 (1 quality finding from Reviewer 4; Reviewers 1, 2,
  and 3 returned NO FINDINGS). Updated
  `list_session_contexts_returns_every_session_in_order` to initialize a
  distinct git branch per session and assert `(session_id, branch)` pairs
  in sort-key order so swapped or dropped `ActorCommand::Context` replies
  cannot pass silently. Round 2 narrowed review (Reviewer 4) pending.
- 2026-10-18T13:17-0700: review round 2 narrowed (Reviewer 4) and round 3
  confirmation (all 4 lenses) both completed with NO FINDINGS across all
  8 pillars.

## Research & Discoveries

- Attach dominates slow-link loads: 282KB for medium session-245, up to
  the 1MiB tail cap, with no WS compression negotiated.
- `ws.rs` handles requests inline and serially per connection: every
  millisecond of contexts/attach latency delays everything behind it.
- Session logs total 1.1GB on disk (largest 16MB); the 1MiB served tail
  cap is what bounds attach, not the log size.

## Lessons Learned

- A fan-out ordering test that spawns identical targets and only asserts
  pre-sorted keys passes even when actor replies are swapped or dropped;
  seed each target with distinct state and assert `(key, value)` pairs.

## Next Steps

- Cascade to PR #187 (`perf/lazy-history`) and continue the stack review loop.
