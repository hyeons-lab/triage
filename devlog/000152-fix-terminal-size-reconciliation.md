# 000152 — fix/terminal-size-reconciliation

## Agent

Muse Code (muse-spark) — branch created 2026-09-21T01:00-0700.

## Intent

Fix two terminal-rendering defects diagnosed from user screenshots of
session-229 (photo-search-grounding):

1. **Bug A — web emulator stuck narrow.** The xterm.js grid sits at 46 cols
   while the pane fits ~110 and the PTY is 80; 100-col-era history wraps and
   the user sees it "in the history when I scroll back". The size-sync never
   reconciles: the drift detector compares host-vs-last-*sent*, blind to
   term-vs-pane divergence, and several forward paths drop silently.
2. **F1 — store strands trailing escape carry.** `_reduceHistory` ends with
   `_closeSyncBlockAndFlush()`, which cancels the 50 ms watchdog that would
   flush a trailing partial escape held in `_escapeCarry`. With no live chunk
   following, those bytes never reach the sink (proven by a throwaway fuzz
   test against true session-log bytes; the probe is deleted).

Out of scope: screenshot-1's SGR-params-as-text leak (Bug B). Every span of
that path verified clean (14.2M SGR runs across session-229's 50 segments,
store fuzz at all split points, both emulators' SGR parsing); frontrunner is
a stale client (`/Applications/Triage.app` predates #169–#175). Revisit only
if it recurs on a fresh client.

## What Changed

- `terminal_store.dart`: `_reduceHistory` re-arms the sync watchdog when a
  replay ends with `_escapeCarry` held (F1). First attempted a synchronous
  flush; the existing boundary-strip test caught it breaking the `CSI >`
  join, so the fix keeps the hold-and-release shape and only restores the
  cancelled timer.
- `terminal_store_test.dart`: regression test pinning F1 (mid-escape replay
  tail + no live → watchdog releases it; verified failing pre-fix).
- `terminal_pane_web.dart`: `_reconcileGridWithPixels` (proposal-vs-grid
  check via `FitAddon.proposeDimensions`, wired into `_onHistoryReplayed`
  before scroll restore); debounced resize-out is flushed with its exact
  pending size in `dispose` instead of dropped (pending-size fields tracked
  alongside the timer).
- `main.dart`: `_reclaimTerminalSizeIfDrifted` also fires when the cached
  web term grid disagrees with the host (new `_selectedSessionGridDriftedFromHost`,
  web-only; native auto-fit unaffected).
- New `terminal/size_drift.dart` (`liveGridDriftedFromHost` pure predicate)
  + `test/terminal/size_drift_test.dart` pinning match/mismatch/unknown.
- Plan item 3b (font-ready refit) found already implemented in
  `_initTerminal`; dropped from scope, no change needed.

## Decisions

- Reconcile event-driven (replay/select/foreground/font-ready), not polling.
  A timer would fight the existing debounce/retry ladders and risk resize
  churn on shared PTYs.
- Reuse the existing `_onRefit` force-send machinery where a forced send is
  needed; add a light grid-vs-proposal check where a plain fit suffices.
- F1 fix flushes the stranded carry synchronously at end of replay through
  the same path the watchdog uses (`_processSynchronizedOutput`), via a
  shared helper — no behavior change when the carry is empty.
- T2 (platform-view stuck narrow) deliberately not chased in this branch: it
  needs live-browser evidence the author cannot gather here. Asking the user
  two questions (refit-button effect? window-resize effect?) to resolve it.

## Issues

## Commits

- HEAD — fix(client): reconcile stuck-narrow web terminal grid and release stranded escape carry

## Progress

- 2026-09-21T01:00-0700: worktree + branch created from origin/main (bf4fa52);
  devlog + plan 000152-01 written. No code yet.
- 2026-09-21T01:17-0700: implemented F1 + Bug A per plan (minus 3b, already
  present). Gates green: `flutter analyze` clean, full `flutter test` 533
  pass, `cargo fmt --check` clean. Committed, pushed, PR opened.

## Research & Discoveries

- Full diagnosis lives in the parent session, not here; key numbers: term 46
  (four independent wrap counts), app print width 100 (measured space-padding
  in segment-000042), PTY 80 (sessions.json), pane ~110.
- `hostSizeDriftedFromOwnFit` (main.dart) compares host vs last sent size, so
  term=46/PTY=80/own=80 reads as healthy and `_reclaimTerminalSizeIfDrifted`
  never fires.
- `getCachedTerminalSize` already exposes the web term's live grid; the
  reclaim path can consult it without new plumbing.

## Lessons Learned

## Next Steps

- Implement per plan 000152-01; validate with `flutter test`, `flutter
  analyze`, `dart format`; commit, push, open PR.
- Ask the user: (1) does the header refit button heal a stuck-narrow
  session? (2) does resizing the browser window heal it? Answers decide
  whether the T2 follow-up is needed.
