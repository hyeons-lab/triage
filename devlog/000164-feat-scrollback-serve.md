# 000164 — feat/scrollback-serve (mobile touch-scroll follow-up)

**Agent:** Muse Code @ triage branch feat/scrollback-serve

## Intent

Scrollback history serves and scrolls on desktop web, but on mobile browsers
the terminal view does not move at all on touch drags. Diagnose and fix on
this branch, since the scrollback feature is unusable on mobile without it.

## What Changed

2026-10-10T14:13-0700 flutter/triage_client/lib/terminal/touch_scroll_takeover.dart (new) —
DOM-free per-gesture decision unit: tracks the pointer anchor and yields to
xterm.js while its touch path is alive (120ms quiet window), otherwise
converts pointer travel into signed scroll rows with fractional carry.

2026-10-10T14:13-0700 flutter/triage_client/lib/widgets/terminal_pane_web.dart —
binds a `pointermove` listener on the terminal container that drives
`scrollToLine` from the takeover unit for single-touch/pen drags (mouse
excluded so drag-select is untouched); feeds touchmove observations and
pointer/touch-down resets from the existing handlers; unbinds with the rest.

2026-10-10T14:13-0700 flutter/triage_client/test/terminal/touch_scroll_takeover_test.dart (new) —
10 unit tests: direction, sub-row accumulation, yield-while-alive, quiet
takeover with no jump, carry reset, canDrive gating, degenerate row height,
gesture reset.

## Decisions

- 2026-10-10T14:13-0700 Drive the fallback from pointer events rather than
  touch: pointermove re-hit-tests every move and keeps flowing when the
  touch stream dies (verified over CDP: 14/14 pointermoves vs 1–2/14
  touchmoves on affected drags).
- 2026-10-10T14:13-0700 Yield-while-alive instead of replacing xterm's path:
  xterm owns scrolling whenever its touchmoves arrive, so healthy gestures
  behave exactly as before and only dead streams take over.
- 2026-10-10T14:13-0700 Reverted an earlier `touch-action: none` attempt in
  the same session: applied live over CDP it did not restore delivery, so
  it was not the mechanism and was dropped from the diff.

## Issues

- 2026-10-10T14:13-0700 Root cause (browser-side, verified in headless
  Brave over CDP against the live daemon): xterm.js scrolls from its own
  touchmove handler, but the browser silently drops the rest of a touch
  stream — no further moves, end, or cancel — when the touchstart target, a
  DOM-renderer text span, is detached by live-output re-rendering
  mid-gesture. Drags starting on empty row areas usually survive; drags
  starting on text on a streaming session almost always die after ~1 move.
  Desktop wheel is unaffected (per-event hit-testing); taps work (no
  stream to kill).

## Commits

- 92bd309 — fix(client): take over touch scroll from pointer events when xterm's touch stream dies
- HEAD — fix(client): force-drive touch scroll fallback in mouse tracking mode

## Progress

- 2026-10-10T14:13-0700 Unit + glue implemented; `flutter analyze` clean,
  focused suite 10/10, full client suite 711 pass + 2 pre-existing skips.
- Pending: commit, push, daemon rebuild (embeds the web bundle), install,
  zero-downtime reload, CDP end-to-end drag verification, user retest on
  the phone.
- 2026-10-10T16:50-0700 User retest: still painful, several swipes per few
  lines. IPC probe showed session-302 has mouse tracking on
  (`?1000/1002/1003/1006h` near the tail, no disables) with a quiet stream —
  full touch delivery plus an xterm path that ignores touches in mouse mode,
  so the yield vetoed the fallback ~100%. Fix: `forceDrive` bypasses the
  quiet-window yield when `term.modes.mouseTrackingMode != 'none'`
  (proposed API, already enabled). Focused suite 13/13, full client suite
  714 pass + 2 pre-existing skips, analyze clean.
- Pending: rebuild/install/reload the daemon, user retest on the phone
  (shred site data + reload first).
- 2026-10-10T16:53-0700 Daemon rebuilt (bundle 3131364 -> 3131480 bytes),
  installed, re-signed, zero-downtime reloaded: 68 sessions preserved
  (15 live adopted), converged to single PID 48073 serving the new bundle.
- Pending: user retest on the phone (shred site data + reload first),
  then commit + push with the explicit refspec.
- 2026-10-14T09:59-0700 Verified end-to-end over CDP against the live
  daemon on session-302 (mouse tracking on): single-finger drag moved
  21/23 rows smoothly across 14 sampled frames; two-finger drag moved 0
  (gate holds). Event census gave the discriminating signature: healthy
  touch delivery leaves the old logic yielding (~0 rows), while
  forceDrive scrolls from the second move (pointer stream 14/14). A pen
  drag drives the fallback, but real mouse reports still yank to the
  bottom via the onData scrollToBottom — pre-existing, out of scope.
- Committed and pushed the forceDrive fix with the explicit refspec.

## Research & Discoveries

- 2026-10-10T14:13-0700 Attached to live sessions over IPC as observer:
  session-302 serves 32KB raw + 32KB prefix on a 64KB window and
  524KB + 524KB on a 1MB window — the daemon side was exonerated first.
- 2026-10-10T14:13-0700 `window.activeTerm` plus CDP `Input.dispatchTouchEvent`
  reproduces mobile drags deterministically; a stack-spy on the viewport's
  `scrollTop` setter proved xterm's `handleTouchMove` is the sole writer
  (no pane yank-back exists); `DOMDebugger.getEventListeners` proved no JS
  listener swallows the moves.
- 2026-10-10T14:13-0700 A minimal shadow-DOM page with scripted row churn
  reproduces the truncation (3/8 moves), while the static page delivers
  8/8 — churn during the gesture is the trigger.
- 2026-10-10T16:50-0700 xterm.js has exactly two touch listeners
  (touchstart passive, touchmove non-passive), both no-ops in mouse
  tracking mode, and synthesizes no mouse reports from touch — so in mouse
  mode the pane fallback is the sole scroll driver and there is no onData
  yank-back. `term.modes.mouseTrackingMode` (proposed API:
  none/x10/vt200/drag/any) reports the mode without private-API reads.

## Lessons Learned

- 2026-10-10T14:13-0700 A `touch-action` change is not a fix for dead touch
  streams when the page already computes `none` at the body; verify
  delivery live before assuming the CSS owns the behavior.
- 2026-10-10T14:13-0700 CDP synthetic drags need explicit touch-point ids
  and no interleaved evaluates to be trusted; direction mistakes (drag up
  vs down) read exactly like real failures.

## Next Steps

- Commit, push with the explicit `HEAD:refs/heads/feat/scrollback-serve`
  refspec, rebuild/install/reload the daemon, verify a span-start drag
  over CDP, then have the user retest on mobile.
- 2026-10-14T09:59-0700 All of the above are done except the user retest
  on mobile (shred site data + reload, then drag on the snapshot
  session). After that: merge the PR stack.
