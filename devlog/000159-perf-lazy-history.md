# 000159: perf/lazy-history

## Agent

Muse Code (muse-spark), 2026-10-03T22:02-0700.

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
- Tests: daemon cap test, Dart window-growth + VM tracking tests (6 new,
  all pass; full suites green except one pre-existing triage-hook
  failure untouched by this stack).
- 2026-10-18T14:03-0700 Round 1 review fixes:
  - `TerminalStore`: raised `kHistoryReplayMaxLines` to `10000` so native
    xterm buffers do not discard lines across `256 KiB` paged windows, and
    recorded `appliedHistoryStart` only on full history replay (cleared on
    `Attach` / `Clear`) so delta-merge snapshots and empty metadata
    refreshes cannot overwrite `SessionVm.historyStart`.
  - `main.dart`: guarded `_pageHistoryUp` against removed sessions, empty
    or non-progressing responses, and `bytes_logged` growth between attach
    and page; gated `_rawOutputFromSnapshot` decompression on
    `replayHistory || !session.loaded`; passed `kHistoryLeaseProbeBytes`
    when `_refreshSessionSnapshot` does not need history; marked newly
    created sessions `loaded: true`.
  - `terminal_pane_stub.dart` & `terminal_pane_web.dart`: gated `onNearTop`
    on `position.pixels < position.maxScrollExtent - 0.5` (native) and
    `!isAtBottom && baseY > 0` (web) so short viewports at the bottom do
    not trigger paging; re-applied native paged `jumpTo` post-layout;
    cleared pending bottom-snap state during paged scroll restoration; and
    reset `_pageAnchor*` on terminal/controller rebind.
  - `crates/triaged/src/session.rs` & `crates/triage-transport-ws/src/lib.rs`:
    extracted `effective_attach_history_cap` and expanded unit and wire
    round-trip coverage across JSON and FlatBuffers.
- 2026-10-18T14:39-0700 Round 2 review fixes:
  - `TerminalStore` & `TerminalIntent`: added `beginHistoryPaging()` /
    `endHistoryPaging()` and `Attach(preservePendingLive: true)` so live
    `Output` chunks arriving while `_pageHistoryUp`'s `attachSession` RPC is
    in flight are shadow-buffered in `_pendingLive` and replayed in sequence
    order after the widened history snapshot.
  - `main.dart`: re-checked `session.historyStart` after `await _client.attachSession`
    in `_pageHistoryUp` so a concurrent `ResyncRequired` or `Clear` is not
    clobbered by a narrower page, and preserved `session.isExited` across
    the page replay.
  - `terminal_pane_stub.dart` & `terminal_pane_web.dart`: extracted
    `_clearPageAnchor()`, guarded the post-frame `applyPagedJump` callback
    with `_pageJumpGeneration`, and cancelled `_pageRestoreTimer` on clear
    and non-paged replay.
- 2026-10-18T15:13-0700 Round 3 review fixes:
  - `terminal_store.dart` & `terminal_store_test.dart`: exposed
    `isPagingHistory`, guarded `_flushPendingLive` in `_reduceResize` with
    `!_pagingHistory` so a viewport resize mid-page does not drain the shadow
    buffer early, and disarmed `_pagingHistory` on non-preserving `Attach`,
    `Detach`, `Clear`, and `_reduceHistory`.
  - `main.dart`: checked `session.store.isPagingHistory` after
    `await _client.attachSession` in `_pageHistoryUp` so an intervening
    delta-merged `ResyncRequired` or reset aborts the stale page, and gated
    `session.hasInputLease` on `!session.isExited && !session.store.state.exited`.
  - `triage_websocket_client.dart`: inlined `historyBytesFromField` into
    `rawOutputFromSnapshot` and removed the unused helper.
  - `widget_test.dart`: fixed the rail re-select tap in `Lazy history attach & paging`
    to target `'experiment/flutter-spike'`.
- 2026-10-18T15:24-0700 Round 4 review fix:
  - `terminal_store_test.dart`: followed the `endHistoryPaging()` bail-out leg
    with a preserving `Attach(preservePendingLive: true)` and `HistoryBytes` at
    `throughOutputSeq: 12` so removing `_clearPendingLive()` from
    `endHistoryPaging()` fails the assertion.
- 2026-10-19T06:57-0700 (agent-review-check-ci): in `attach_history_cap_limits_the_served_tail` (`crates/triaged/src/session.rs`), assert that the 6-byte capped live/historical attach equals the `[start..start + 6]` slice of the `Some(0)` full-tail attach on all platforms while gating the exact `b"abcdef"` suffix check on `#[cfg(not(windows))]` (since Windows ConPTY appends VT cursor-visibility sequences after the child's `printf` output).

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
  skip-flush machinery in the store's hottest path, which is fragile for
  a 2x byte saving on a rare path. Re-attach with a doubling
  `history_bytes` window (64 KiB -> platform replay budget) reuses the
  hardened attach/replay path, re-anchors trims and live output by
  construction, and costs ~2x bytes only while deep-paging. All
  fetch-path code (RPC, FBS tables, storage range reads, Dart fetch)
  reverted; the attach cap stays.

## Issues

(none yet)

## Commits

- b9d1070: perf(client,daemon): lazy history paging via windowed attach
- f5c6e29: fix(daemon): omit null history_bytes from attach JSON
- 14b6ff6: fix(client,daemon): harden lazy history paging watermarks, line cap, and shadow live buffer
- HEAD: test(triaged): make attach history cap test ConPTY-tolerant on Windows

## Progress

- Discovery done: attach/snapshot path, `compressed_bytes` wire gzip,
  storage segments (8 MiB, zstd), store delta-merge branches, both panes'
  scroll + replayed hooks.
- Devlog + plan written.
- Implemented the `fetch_history` RPC end-to-end, then reverted it for
  geometric re-attach paging (see Decisions); all fetch-path code gone,
  verified zero `FetchHistory` references outside history.
- Gates green: fmt, clippy, cargo workspace (1 pre-existing failure),
  flutter analyze, flutter tests.
- Deployed: reload preserved sessions; cap probe exact on legacy
  (100002B log -> 1024B page at logged-1024) and segmented
  (session-166: 65536/1024 windows land exactly) paths; served bundle
  carries the new client code; no panics.

## Research & Discoveries

- `raw_output` is already gzip+base64 on the wire (`compressed_bytes` in
  triage-core); the win is attach latency + client re-emulation, not wire
  compression.
- Snapshot also ships full-scrollback `visible_rows` as JSON text.
- Client already trims history to a paint budget locally; the daemon
  ships 1 MiB regardless.

## Lessons Learned

- After `triaged reload`, wait for the adopt log line, not a fixed
  sleep, before probing: the first cap probe raced the handover and
  hit the old daemon, which looked like the cap was being ignored.
- A byte-cap that threads through three transports (JSON, FlatBuffers,
  IPC-whole-struct) is best verified live per path: exact-offset
  assertions (`start == logged - cap`) on a fresh session plus a
  segmented giant.
