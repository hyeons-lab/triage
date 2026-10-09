# 000159: perf/lazy-history

## Agent

2026-10-03T22:02-0700.

## Intent

Page terminal scrollback on demand instead of shipping up to 1 MiB of raw
history on every attach. Attach carries a small first page (fast first
paint, cheap on slow links); scrolling near the top fetches the previous
page and re-emulates from the oldest loaded byte. Stacked on
`perf/load-quick-wins` (PR 186).

## What Changed

- Daemon: `AttachSessionRequest.history_bytes` cap threaded through
  attach -> actor `SnapshotWithHistory` -> overlay (0/None = legacy 1 MiB;
  resync keeps the full cap). Test: capped tail serves the newest bytes.
- Wire: `history_bytes` on the FBS attach table (0 = legacy), JSON +
  FlatBuffers, Dart bindings regenerated with the pinned flatc.
- Client: first-page 64 KiB attach on load/create; refresh/revive keep
  the held window; lease-only attaches probe 1 KiB (their snapshot was
  discarded after a 1 MiB transfer).
- Client paging: near-top triggers in both panes -> `_pageHistoryUp`
  re-attaches with a doubling window (-> 256 KiB native / 1 MiB web),
  full-replays via an explicit `Attach` reset, and restores the
  anchor-adjusted scroll position (sync on native, settle-polled on
  web). Stops at log start; single-flight coalesced.
- Cancellation and baseline recovery: added `CancelAttach` intent,
  stashing and restoring dedup and byte baselines (`appliedLiveSeq`,
  `appliedLogBytes`, `historyHighWaterSeq`) and draining buffered live
  chunks if attach fails or cancels.
- Web scroll reliability: touch pull-down gesture maintains start
  anchor across continuous vertical swipes, restored scroll target is
  clamped against `baseY`, and premature initial replay `baseY == 0`
  trigger is removed.
- Tests: daemon historical and live attach cap tests, FlatBuffers
  roundtrip and request serialization tests, Dart window-growth, VM
  tracking, and `CancelAttach` recovery tests.

## Decisions

- Byte offsets (`raw_output_start` / `bytes_logged`) are the paging
  coordinate; the fetch response reports the actual start so the client
  can detect trim gaps and stop.
- Backward extension gets a new store intent (clear + re-emit
  concatenated pages), not a re-dispatched `HistoryBytes`: the store's
  same-end branch treats that as a no-op.
- Scroll restore reuses `onHistoryReplayed`; panes adjust the saved
  anchor by the added row count.
- New `SessionApi` method gets a default bail impl (precedent:
  `get_judge_rules`) so the TUI, MCP, and test mocks stay untouched;
  only the WS dispatch wires it.
- REVISED (2026-10-03T22:02-0700): dropped the `fetch_history` RPC and
  prepend-intent design for geometric re-attach paging. The prepend
  needed a forward fill for live bytes applied since attach, and
  correlating the fill with queued live chunks needs byte-offset
  skip-flush machinery in the store's hottest path, which was fragile for a 2x
  byte saving on a rare path. Re-attach with a doubling `history_bytes`
  window (64 KiB -> platform replay budget) reuses the hardened
  attach/replay path, re-anchors trims and live output by
  construction, and costs ~2x bytes only while deep-paging. All
  fetch-path code (RPC, FBS tables, storage range reads, Dart fetch)
  reverted; the attach cap stays.

## Issues

(none yet)

## Commits

- 41302c7: perf(client,daemon): lazy history paging via windowed attach
- 190c76d: fix(daemon): omit null history_bytes from attach JSON
- HEAD: perf(client,daemon): review findings from lazy history confirmation audit

## Progress

- Discovery done: attach/snapshot path, `compressed_bytes` wire gzip,
  storage segments (8 MiB, zstd), store delta-merge branches, both panes'
  scroll + replayed hooks.
- Devlog + plan written.
- Implemented the `fetch_history` RPC end-to-end, then reverted it for
  geometric re-attach paging (see Decisions); all fetch-path code gone,
  verified zero `FetchHistory` references outside history.
- Gates green: fmt, clippy, cargo workspace (1 pre-existing failure),
  flutter analyze, 659 flutter tests.
- Deployed: reload preserved sessions; cap probe exact on legacy
  (100002B log -> 1024B page at logged-1024) and segmented
  (session-166: 65536/1024 windows land exactly) paths; served bundle
  carries the new client code; no panics.
- Confirmation audit round 2 complete across all 8 review pillars.
  Applied all findings, re-verified test suites (368 Rust tests, 661
  Flutter tests, clean analyze and clippy).

## Research & Discoveries

- `raw_output` is already gzip+base64 on the wire (`compressed_bytes` in
  triage-core); the win is attach latency + client re-emulation, not wire
  compression.
- Snapshot also ships full-scrollback `visible_rows` as JSON text.
- Client already trims history to a paint budget locally; the daemon
  ships 1 MiB regardless.

## Lessons Learned

- After `triaged reload`, wait for the adopt log line (not a fixed
  sleep) before probing: the first cap probe raced the handover and
  hit the old daemon, which looked exactly like the cap being ignored.
- A byte-cap that threads through three transports (JSON, FlatBuffers,
  IPC-whole-struct) is best verified live per path: exact-offset
  assertions (`start == logged - cap`) on a fresh session plus a
  segmented giant.

## Next Steps

- Implement per `devlog/plans/000159-01-lazy-history-paging.md`.
- Deploy, re-probe attach, open stacked PR on 186.
