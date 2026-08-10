# 000119 fix/resize-arbitration

**Agent:** Claude (claude-opus-5, 1M context) @ triage branch fix/resize-arbitration

## Intent

Stop several attached clients fighting over the shared PTY's size, which is what
fills the scrollback with the same text at several widths and corrupts the live
frame. Plan: [plans/000119-01-resize-arbitration.md](plans/000119-01-resize-arbitration.md).

## What Changed

2026-08-09T19:49-0700 `flutter/triage_client/lib/main.dart`: adds
`SessionVm.ownFittedCols/Rows`, the size this device fitted to, kept separate
from `lastFittedCols` because that is also written from the host's size
broadcasts and so cannot answer "is the PTY still my size". Adds
`_clientForeground`, driven by `didChangeAppLifecycleState`, and gates the
automatic resize-out on it: the fit is still recorded, it is just not forwarded.
On regaining focus without having been occluded, `_reclaimTerminalSizeIfDrifted`
re-asserts this device's size, but only when the host has actually drifted from
it.

## Decisions

2026-08-09T19:30-0700 Foreground-owns rather than smallest-client-wins.
Reasoning: chosen by the user from three options. tmux's default (min across
attached clients) guarantees every client can render the frame, but it means a
phone left attached in a pocket shrinks a desktop terminal to 28 columns. The
cost of this choice is one repaint per device switch, which no policy avoids
once both devices render at their own width.

2026-08-09T19:33-0700 `inactive` counts as background. Reasoning: Flutter's web
engine maps window `blur` to `inactive` and only tab-hide to `hidden`
(`app_lifecycle_state.dart` in the engine), and a desktop window behind another
reports `inactive` too. Both are cases where the user is looking at a different
device, which is exactly when this client should stop asserting a size. The
existing occlusion handling stays tied to `hidden`/`paused` so reconnect and
refocus behaviour is unchanged.

2026-08-09T19:35-0700 `_clientForeground` defaults to true. Reasoning: a client
that never receives a lifecycle event (the widget tests, and any platform that
does not report one) must behave exactly as it did before this existed. Failing
open here costs the old behaviour; failing closed would silently stop a whole
platform from ever sizing its PTY.

2026-08-09T19:37-0700 Reclaim is conditional on drift. Reasoning:
`_refitActiveSession` deliberately jiggles the host (one row shorter, then back)
to force a repaint, which is right after occlusion but would fire on every
alt-tab if reclaim were unconditional. There is an existing test asserting that
a plain focus change does not redraw, and this preserves it.

## Issues

2026-08-09T19:20-0700 The first diagnosis was wrong in an instructive way. I had
assumed a feedback loop: a host size broadcast resizes the client's terminal,
which pushes back. Checking rather than assuming showed clients deliberately
ignore that broadcast for local sizing, so no oscillation exists. The real shape
is discrete: each device switch is one resize, one repaint, one more copy of the
frame in the scrollback.

2026-08-09T19:15-0700 Also had to abandon an earlier confident claim. Before
measuring, this was diagnosed as multi-client width fighting; the first
experiment then showed the *single*-client path works correctly (120 to 137 to
147 columns, verified with `stty size`, with a 127-character line re-wrapping
cleanly). That did not confirm the theory, it removed the simplest alternative
to it. The user's four-widths paste is what actually carried it, because a
28-column block cannot come from a desktop window.

2026-08-09T19:45-0700 Not covered by the test suite, and worth being explicit
about. The widget harness renders a fallback view under `FLUTTER_TEST` that
never fits a real terminal, so `onViewFit` never fires, `ownFittedCols` stays
null and the reclaim path declines by design. A test written for it passed for
the wrong reason and was removed rather than kept. This needs verifying on a
real device with two clients attached.

2026-08-09T20:20-0700 Reported while this branch was building: after a resize
the terminal does not take the keyboard back, and the session has to be switched
away from and back before it accepts typing. That is a pre-existing bug, but it
lands on this change too: the occlusion path pairs `_refitActiveSession` with
`_refocusActiveSession`, and the reclaim added here refitted without refocusing,
so it would have reproduced it. Now paired. The pre-existing path that loses
focus on an ordinary resize is untouched and still needs its own fix.

## Verification

- `flutter analyze lib/`: no new issues (3 pre-existing, in untouched files).
- `flutter test`: 284 passing, including the existing test that a plain focus
  change must not redraw the active session, which this preserves.
- Verified end to end against a live daemon, with a phone and a desktop browser
  attached to one session and the PTY's every resize logged. Before, one device
  switch produced four resizes, including an 80-column intermediate from
  `_estimatedTerminalRestoreSize`'s clamp, and the cycle
  `98x34 -> 80x47 -> 47x19` repeated about every 35 seconds:

  ```
  03:22:03   96x31 -> 89x35
  03:22:04   89x35 -> 98x34
  03:22:08   98x34 -> 80x47
  03:22:09   80x47 -> 47x19
  ```

  After, a switch is one width change straight between the two real widths,
  followed by a rows settle, and the repeating cycle is gone:

  ```
  03:32:02   95x34 -> 47x18     to the phone
  03:32:03   47x18 -> 47x19
  03:32:06   47x19 -> 95x33     back to the desktop
  03:32:07   95x33 -> 95x34
  ```

  One repaint per switch is the floor for a policy that lets each device render
  at its own width, so this is as good as the chosen design allows.

## Next Steps

- The attach path (`_client.resizeSession` during attach/replay) still asserts a
  size regardless of foreground. It fires once per attach rather than
  continuously, so it is a much smaller contributor, but a background client
  reattaching after a reconnect can still take the size. Worth a follow-up.
- Two smaller sources of churn the same trace exposed, neither causing the
  duplication this fixes: rows drifting one at a time across separate resize
  calls with cols stable (`95x32 -> 95x33 -> 95x34`), and an occasional two-step
  width settle (`36x37 -> 86x35 -> 95x34`).
- The focus-loss-on-resize reported above, which this branch does not fix.
- `_estimatedTerminalRestoreSize` is desktop-shaped on every platform: it
  subtracts a sidebar that is an overlay on mobile, assumes 44px of padding
  where mobile uses 16, and clamps cols to a minimum of 80 on a display that
  fits about 40. That clamp is the 80-column intermediate visible in the trace
  above. Untouched here.

## Commits

- HEAD: fix(triage_client): let only the focused client size the shared PTY
