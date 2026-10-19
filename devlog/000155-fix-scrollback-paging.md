# 000155 fix/scrollback-paging

## Agent

- Muse Code (muse-spark) @ triage branch fix/scrollback-paging (2026-10-06T06:30-0700)
- Antigravity @ triage branch fix/scrollback-paging (2026-10-18T18:47-0700)

## Intent

Scrollback paging is stuck on both the browser web client and the Pixel
app: scrolling to the top of the first 64 KiB window loads nothing more.
Diagnose against the live daemon, fix at the root cause, and stack the
fix PR on top of #192.

## What Changed

- `flutter/triage_client/lib/terminal/terminal_store.dart`:
  - P1: replay-trim budgets now scale with the served history window
    (`historyTrimBudgetsForWindow`; native lines 1000 -> 2000 -> 4000
    across the 64/128/256 KiB pages, floored at `platformLines` for
    sub-64 KiB windows, web unchanged at the 50k cap).
  - `trimHistoryTailWithOffset` returns `({List<int> bytes, int droppedBytes})`
    and `_reduceHistory` records `_appliedHistoryStart = rawStart + trimmed.droppedBytes`
    so a `raw_output_start == 0` snapshot whose older prefix was dropped by
    line-budget trimming does not prematurely mark the log start as reached.
- `flutter/triage_client/lib/main.dart`:
  - `windowBytes` threads through `applyHistory` -> `_PendingHistory` ->
    `HistoryBytes` -> `_reduceHistory`; `_PendingHistory.effectiveStart`
    accounts for `trimmed.droppedBytes`.
  - Consolidated `_canPageHistory` and `_pageHistoryUp` onto `_nextHistoryPage`.
  - When a paged snapshot returns empty or non-progressing `effectiveStart`,
    `_pageHistoryUp` advances `session.historyWindowBytes` and notifies
    `notifyHistoryPageStarted()` and `notifyHistoryReplayed()` so barren-page
    continuation and exhaustion feedback run instead of silently dropping the
    trigger.
- `flutter/triage_client/lib/widgets/terminal_pane.dart`, `terminal_pane_stub.dart`, `terminal_pane_web.dart`:
  - P2: `onNearTop` returns whether a page launched; both panes auto-continue
    past a barren page (no new buffer lines, still near the top) and raise a
    shared transient `NoOlderScrollbackPill` ("No older scrollback in reach")
    when no deeper window is available.
  - Web `_restorePagedScrollPosition` measures `wasNearTop` from the pre-replay
    anchor (`anchorY <= 5`) and restores `scrollToLine(target)` before invoking
    `_continuePastBarrenPage()`, avoiding false non-near-top reads after
    `onClear()`/`term.write()` resets `active.viewportY` to `baseY`.
  - Added `_dismissNoOlderScrollback()` on clears, session/controller swaps,
    non-paged replays, and fruitful paged replays (`addedLines > 0`), and
    guarded `_continuePastBarrenPage` microtasks against controller/terminal/generation
    changes.
- `flutter/triage_client/test/`:
  - Added `history paging` widget tests (1,200 -> 2,000 line scaling growth,
    end-to-end barren auto-continuation + `NoOlderScrollbackPill` + 3s auto-hide,
    and standalone pane barren/fruitful tests), `session_history_window_test.dart`,
    `terminal_store_test.dart` (`raw_output_start == 0` with dropped prefix lines),
    and env-guarded `live_history_paging_test.dart` (`TRIAGE_LIVE_WS` /
    `TRIAGE_LIVE_SESSION`).

## Decisions

- Reproduce with a live-daemon Dart probe (`flutter test` against the
  real client transport + store) rather than Playwright: no browser
  toolchain is installed here, and the probe exercises the real FBS
  decode, paging, and replay code.
- P1 fix: scale the replay-trim budgets with the served window
  (native lines 1000 -> 2000 -> 4000 across the 64/128/256 KiB pages;
  web unchanged in practice since the 50k cap binds immediately) and
  offset `_appliedHistoryStart` by `trimmed.droppedBytes`.
- P2 fix: panes auto-continue paging when a page yields no new lines
  (still near the top, deeper window available), so one gesture
  skips a barren desert; when exhausted, the session raises a
  transient "no older scrollback" chip instead of silent inertness.
  No daemon or protocol change: barrenness is measured from the
  replay result, which covers region-eaten output that a newline
  count would miss.
- Out of scope: reaching scrollback buried under gigabytes of TUI
  redraws needs scrollback extraction or a raw-log viewer, which is a
  separate feature (`feat/scrollback-index` and `feat/scrollback-serve`).

## Issues

- Daemon serves correct windowed tails over JSON and FBS (live Dart
  probe: 64/128/256 KiB windows exact with correct older starts), so
  the transport is healthy.
- P1 (Pixel, dense-scrollback sessions): the native replay trim keeps
  the last 1000 lines, but the first 64 KiB window already holds more
  (session-255: 1625 newlines). Every page trims to the same last-1000
  suffix of the same log end, so each replay is byte-identical and the
  buffer never grows. Proven by probe2: 839 buffer lines after both
  the 64 KiB and the 128 KiB replay.
- P2 (both clients, session-245 class): the reachable windows hold no
  scrollback at all. The TUI updates a scroll region in place (~1976
  save/set-region/reset cycles per MiB); region scrolls never enter
  the scrollback buffer. Headless xterm.js replays the 1 MiB tail to
  24 lines (6 non-empty). Correct emulation: paging cannot help
  because older windows are the same redraws. The 2.24 GB log floods
  at ~4.5 KiB/s, so the desert exceeds any sane window.

## Commits

- e9ced49: fix(client): unstick scrollback paging on barren and dense histories
- HEAD: fix(client): track effective trimmed history start and fix barren page continuation

## Progress

- 2026-10-06T06:30-0700: worktree created from `origin/feat/host-stats`
  (79938ac); daemon JSON tails verified healthy.
- 2026-10-06T08:24-0700: diagnosis complete. FBS round trip exact
  (live Dart probe); native trim-stuck proven (probe2: 839 lines
  after both 64/128 KiB replays); session-245 TUI saturation proven
  (headless xterm.js: 1 MiB tail -> 24 lines; ~1976 scroll-region
  cycles/MiB); user located on session-245 via last_input_ms.
  P1 + P2 implemented test-first.
- 2026-10-06T08:46-0700: deployed. Daemon rebuilt, installed, and
  handed over cleanly; release APK rebuilt and installed on Pixel.
- 2026-10-18T18:47-0700: Round 1 review fixes applied: floored
  `historyTrimBudgetsForWindow` at `platformLines`, added
  `trimHistoryTailWithOffset` so `_appliedHistoryStart` and
  `_PendingHistory.effectiveStart` include `droppedBytes`, notified
  barren-page listeners on non-progressing snapshots in `_pageHistoryUp`,
  fixed web `_restorePagedScrollPosition` near-top check and scroll
  restoration, wired `_dismissNoOlderScrollback`, and expanded unit and
  widget test coverage.
