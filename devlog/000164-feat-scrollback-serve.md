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

- HEAD — fix(client): take over touch scroll from pointer events when xterm's touch stream dies

## Progress

- 2026-10-10T14:13-0700 Unit + glue implemented; `flutter analyze` clean,
  focused suite 10/10, full client suite 711 pass + 2 pre-existing skips.
- Pending: commit, push, daemon rebuild (embeds the web bundle), install,
  zero-downtime reload, CDP end-to-end drag verification, user retest on
  the phone.

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
