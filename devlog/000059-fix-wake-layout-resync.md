# fix/wake-layout-resync

**Agent:** Claude Code (claude-opus-4-8) @ triage branch fix/wake-layout-resync

## Intent

Fix the terminal layout corruption the macOS client shows after waking from sleep /
returning after a long idle: the active session renders with wrap fragmentation
(words split mid-token, lines re-wrapped at a narrower width than the content was
authored at). A manual window resize fixes it instantly. Screenshot in the originating
request ("the layout is wrong when I come back to the flutter client after a really
long time… it's correct if I resize it").

## Research & Discoveries

- Root cause is the known view-width vs host-PTY-width mismatch (same family as the
  first-load fix in #63). The bytes in the xterm buffer are wrapped/positioned for the
  host PTY width; when that drifts from the client view width the frame fragments. The
  cure is the resize round-trip in `_refreshSessionSnapshot(includeHistory: true)` —
  resize the host to our fitted width, re-fetch the raw-output tail, re-emulate at our
  width — which is exactly what a manual resize triggers (resize-out → host-resize →
  program-redraw over the live stream).
- That reconciliation only runs on (a) first view-fit (`_onSessionViewFit`, gated by
  `!hasFitted`), (b) session select (`_selectSession`), and (c) host `ResyncRequired`.
  None fires reliably on wake: if the WebSocket stayed connected, `hasFitted` is already
  true and the window size is unchanged → no fit, no resync; if it reconnected
  (`_loadDaemonSessions` rebuilds sessions with `hasFitted=false`), the terminal is
  swapped under a reused `_TerminalPaneState` and an unchanged window may not emit a
  fresh fit, so the one-shot reconcile is missed.
- `_TriageHomeState` had no app-lifecycle hook at all, so nothing reconciled width on
  resume.

## What Changed

- 2026-06-05T20:05-0700 `flutter/triage_client/lib/main.dart` — `_TriageHomeState` now
  `with WidgetsBindingObserver`; registers/unregisters in `initState`/`dispose`. Added
  `didChangeAppLifecycleState`: marks `_wasOccluded` on `hidden`/`paused`, and on
  `resumed`-after-occlusion calls `_redrawActiveSessionOnResume`. That method JIGGLES the
  host PTY size for the active attached remote session (resize to `rows-1` then back to
  the real `rows` at our current `cols`), forcing the program to SIGWINCH-repaint over
  the live byte stream at our width. It does NOT replay history. Gated on `hidden`/
  `paused` (not `inactive`) so we don't jiggle on every desktop focus change.
- 2026-06-05T20:05-0700 `flutter/triage_client/test/widget_test.dart` — added
  "redraws the active session when resuming after occlusion": asserts an inactive→
  resumed focus cycle issues NO resize, while inactive→hidden→inactive→resumed
  (genuine occlusion) issues exactly two (the jiggle down and back). Uses
  framework-valid lifecycle transitions.

## Decisions

- 2026-06-05T20:05-0700 REVISED from the first approach (replay via
  `_refreshSessionSnapshot`) to a redraw jiggle. User reported the layout renders
  *correctly and then switches to incorrect* on wake — i.e. a history REPLAY is
  clobbering an already-correct live frame with a width-mismatched/truncated one. A
  manual resize fixes it precisely because it does NOT replay: it changes the PTY size,
  the program repaints over the live stream at the new width. So the fix must provoke a
  redraw, not a replay.
- 2026-06-05T20:05-0700 Jiggle (rows-1 then rows) rather than re-send the current size
  once: a same-size resize sends no SIGWINCH, so a single re-send heals nothing when the
  host already believes it is at our size. Jiggle height (not width) to avoid a visible
  wrap-fragmentation flicker during the intermediate step; SIGWINCH fires on any
  dimension change, so a height jiggle still forces a full repaint, and both resizes send
  our real `cols`, so the host also lands at the correct width.
- 2026-06-05T20:05-0700 Base the size on `_currentReplayTerminalSize(session, null)`
  (real last fit when known, estimate otherwise) so it works headless and matches the
  client view width.
- 2026-06-05T20:05-0700 Gate on `hidden`/`paused`, not `inactive`. On desktop `inactive`
  fires on every focus loss (menu, click-away, Mission Control); jiggling on each would
  thrash the PTY. `hidden`/`paused` are the closest signal to display sleep /
  backgrounding.

## Issues

- 2026-06-05T20:35-0700 BOTH the replay approach and the redraw-jiggle approach failed
  on a real device — layout still fragments after wake (user screenshots). Leading
  hypothesis: on macOS the app is NOT backgrounded on display/system sleep, so
  `didChangeAppLifecycleState(resumed)` never fires and neither fix ever ran.
  Mitigations added this round:
  - Wall-clock SLEEP WATCHDOG: a 4s `Timer.periodic` whose tick gap exceeds 30s implies
    the process was frozen (system sleep) → triggers the same redraw jiggle. Independent
    of Flutter lifecycle delivery.
  - `[WAKEDBG]` diagnostics (const-gated `_wakeDebug`) across the lifecycle handler,
    watchdog, redraw (entry/sizes/bail/jiggle-sent), `_onSessionViewFit` (real fitted
    size vs `lastFittedCols`, to detect a stale-wide value driving the jiggle to the
    wrong width), `_onWebSocketClosed`, and `_loadDaemonSessions` (reconnect→replay).
  Next: read the device logs across a sleep/wake to learn which trigger fires and whether
  the jiggle targets the correct width, then converge on the real fix and strip the
  diagnostics.
- 2026-06-05T19:45-0700 The test framework validates lifecycle transitions
  (`AppLifecycleListener`): direct `resumed→hidden` or `resumed→resumed` jumps throw
  "Invalid state transition". Fixed by driving the desktop-realistic path through
  `inactive` both ways. Turned this into a stronger assertion that `inactive` alone does
  not trigger a resync.

## Verification

- `flutter test` — 71 passed (70 prior + the new resume redraw test).
- `flutter analyze lib/main.dart` — clean except two pre-existing issues (now lines 1827,
  2424) unrelated to this change.
- LIMITATION: cannot be exercised headless on a real sleep/wake — app-lifecycle delivery
  on macOS display-sleep varies. Needs a device test (build, sleep, wake, observe the
  active terminal repaints to the correct layout without a manual resize, and does NOT
  flash correct-then-incorrect). If `resumed` does not fire on the user's wake path,
  fallbacks are to reconcile on `didChangeMetrics` or to drive the jiggle from a wake
  heartbeat. If it still flickers, the live stream itself is suspect and needs
  instrumentation.

## Commits

- 9771fcf — fix(client): redraw active terminal on app resume after occlusion
- HEAD — fix(client): add sleep watchdog + wake diagnostics for layout heal
