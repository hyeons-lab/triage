# 000155 fix/scrollback-paging

## Agent

Muse Code (muse-spark) — 2026-10-06T06:30-0700.

## Intent

Scrollback paging is stuck on both the browser web client and the Pixel
app: scrolling to the top of the first 64 KiB window loads nothing more.
Diagnose against the live daemon, fix at the root cause, and stack the
fix PR on top of #192.

## What Changed

- P1: replay-trim budgets now scale with the served history window
  (`historyTrimBudgetsForWindow` in `terminal_store.dart`; native
  lines 1000 → 2000 → 4000 across the 64/128/256 KiB pages, web
  unchanged at the 50k cap). `windowBytes` threads through
  `applyHistory` → `_PendingHistory` → `HistoryBytes` →
  `_reduceHistory`; all four windowed attach sites pass their
  requested window, unwindowed seeds keep the platform budgets.
- P2: `onNearTop` returns whether a page launched
  (`_canPageHistory` holds the gates as the single source of truth);
  both panes auto-continue past a barren page (no new buffer lines,
  still near the top) and raise a shared transient
  `NoOlderScrollbackPill` ("No older scrollback in reach") when no
  deeper window is available.
- Tests: `history paging` widget group (trigger→page wiring, barren
  auto-continue + pill, fruitful quiet), trim-budget units, store
  scaled-replay, Vm buffer-growth regression, and an env-guarded
  live-daemon round-trip test (`TRIAGE_LIVE_WS`, skipped in CI).

## Decisions

- Reproduce with a live-daemon Dart probe (`flutter test` against the
  real client transport + store) rather than Playwright: no browser
  toolchain is installed here, and the probe exercises the real FBS
  decode, paging, and replay code.
- P1 fix: scale the replay-trim budgets with the served window
  (native lines 1000 → 2000 → 4000 across the 64/128/256 KiB pages;
  web unchanged in practice since the 50k cap binds immediately).
  First paint keeps today's budgets.
- P2 fix: panes auto-continue paging when a page yields no new lines
  (still near the top, deeper window available), so one gesture
  skips a barren desert; when exhausted, the session raises a
  transient "no older scrollback" chip instead of silent inertness.
  No daemon or protocol change: barrenness is measured from the
  replay result, which covers region-eaten output that a newline
  count would miss.
- Out of scope: reaching scrollback buried under gigabytes of TUI
  redraws needs scrollback extraction or a raw-log viewer — a
  product decision for a follow-up, not this fix.

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
  24 lines (6 non-empty). Correct emulation — paging cannot help
  because older windows are the same redraws. The 2.24 GB log floods
  at ~4.5 KiB/s, so the desert exceeds any sane window.
- The user is actively typing in session-245 (last_input 11 s before
  the probe), which is why both clients look inert: thin or no
  scrollbar, trigger unreachable, every page barren.

## Commits

- HEAD — fix(client): unstick scrollback paging on barren and dense histories

## Progress

- 2026-10-06T06:30-0700: worktree created from `origin/feat/host-stats`
  (79938ac); daemon JSON tails verified healthy.
- 2026-10-06T08:24-0700: diagnosis complete. FBS round trip exact
  (live Dart probe); native trim-stuck proven (probe2: 839 lines
  after both 64/128 KiB replays); session-245 TUI saturation proven
  (headless xterm.js: 1 MiB tail → 24 lines; ~1976 scroll-region
  cycles/MiB); user located on session-245 via last_input_ms.
  P1 + P2 implemented test-first (barren test failed
  `Expected <2> Actual <1>` before the handler logic).
  `flutter analyze` clean; full suite 685 passed + 2 live-skipped;
  live test green against the daemon. No Rust changes.
- 2026-10-06T08:46-0700: deployed. Daemon rebuilt (bundle 297e62d0,
  pill string present), installed, handover clean with 65 sessions
  preserved; served main.dart.js matches the fresh build. Release APK
  rebuilt (57.1MB) but not installed — Pixel 10 Pro Fold not on adb
  (only a Samsung S25 Ultra visible); needs Pixel wireless debugging
  reconnected. Web override dir (~/.local/share/triage/web) absent:
  nothing shadowing the embedded bundle. PR 193 CI green.

## Research & Discoveries

(none yet)

## Lessons Learned

(none yet)

## Next Steps

- Run the live FBS paging probe; fix what it finds.
