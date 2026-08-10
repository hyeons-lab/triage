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

2026-08-09T23:30-0700 `flutter/triage_client/lib/main.dart`: the drift
comparison moves onto `SessionVm` as `hostSizeDriftedFromOwnFit`, and the
lifecycle-to-foreground mapping becomes the top-level `foregroundForLifecycle`.
Both were previously spelled out inline and so were unreachable from a test.
Behaviour is unchanged; the lifecycle switch now assigns from the predicate once
instead of in four branches, which also collapses the `inactive`/`detached`
cases.

2026-08-09T23:30-0700 `flutter/triage_client/test/terminal/terminal_size_arbitration_test.dart`
(new): nine cases over those two, covering the reclaim decision this branch
turns on.

2026-08-10T00:04-0700 `flutter/triage_client/lib/main.dart`: the attach refresh
now tracks the size it actually drove the host to (`drivenSize`) instead of
passing the size it wanted, and the lazy-load attach resize is gated on
foreground like the other two resize-out paths.

2026-08-10T00:04-0700 `flutter/triage_client/test/widget_test.dart`: three cases
driving the arbitration end to end (the foreground gate, the reclaim, and the
replay size), plus an optional `size` on the fake's `emitSnapshot` so a host
resize broadcast can be simulated at all.

2026-08-10T00:40-0700 `flutter/triage_client/lib/main.dart`:
`_currentReplayTerminalSize` prefers this device's own fit over `lastFitted*`,
which the host's broadcast overwrites with another device's size.

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

2026-08-09T21:00-0700 Review loop, and the finding that mattered: two reviewers
independently showed the drift comparison defeated itself. `_onSessionViewFit`
writes `lastFittedCols` as well as `ownFittedCols`, so any fit arriving while
backgrounded (a window moved behind another, a DPI change, a rebuild) reset the
baseline to this device's own size and erased the evidence that another device
had taken the PTY. On refocus the check then saw no drift and declined to
reclaim, leaving the client stuck at the wrong size: precisely the state this
branch exists to prevent. Fixed by adding `hostSizeCols/Rows`, written only
where the daemon reports the size (its resize broadcast, and the attach
snapshot's own `size` rather than the render-preferring `fittedCols`), and
comparing against that instead.

2026-08-09T21:02-0700 Review loop: the reclaim called `_refitActiveSession` and
`_refocusActiveSession` directly, duplicating `_refitAndFocusActiveSession` and
dropping its `isMobilePlatform()` carve-out. That carve-out exists because the
refocus raises the soft keyboard, which insets the Scaffold, shrinks the
viewport and fires another fit at the smaller size; on this path that shrunken
size would then be pushed onto the shared PTY. Mobile reaches `inactive` then
`resumed` for transient system UI (notification shade, incoming call), so this
was reachable and would have added churn to the exact path being quieted. Now
routed through the shared helper. Note this was introduced while fixing the
focus-loss report above, which is a reminder that a fix aimed at one platform
needs checking on the other.

2026-08-09T23:30-0700 Closed the "not covered by the test suite" gap from 19:45.
The reviewers' suggestion was to extract the comparison as a pure predicate over
four integers, which would not have caught the bug they found: that bug was not
a wrong comparison, it was the right comparison against the wrong field. A
predicate taking `hostCols` as a parameter is correct whatever the caller hands
it. So the predicate hangs off `SessionVm` and reads the fields itself, which
puts the field choice inside the tested unit.

Checked that by mutation rather than by assertion: reverting the getter to read
`lastFittedCols`/`lastFittedRows` makes the case written for exactly this
scenario fail (a local fit arriving while backgrounded must still leave the
drift visible).

2026-08-10T00:04-0700 Two corrections to the entry above, both from the review
loop. First, the mutation evidence was overstated: three of nine failed, but two
of those only because they left `lastFitted*` null, a state production never
reaches, so they failed on the null guard rather than on the field choice. Those
two now set `lastFitted*` to what a host broadcast would really leave there,
which makes them honest behaviour tests and leaves exactly one case carrying the
mutation evidence. Second, and more usefully, the claim that the end-to-end path
"cannot be driven" under `FLUTTER_TEST` was simply wrong. `onViewFit` is a
public field on `TerminalPane`, so a widget test can call it directly, and the
existing harness already drives lifecycle transitions and counts
`resizeSession` calls. Widget tests now cover the whole chain: fit through
`onViewFit`, another device's size through a real Snapshot broadcast, then blur
and refocus. All are mutation-checked. Being wrong about that was worth more
than the unit tests it was used to justify.

2026-08-10T00:40-0700 Round 2 sharpened those two tests, both of which were
weaker than they read. The "must not answer back" assertion could not fail,
because nothing in the harness answers a broadcast with a resize; it now drives
`controller.sendResizeOut` directly, which is the gated path, so removing the
gate fails it. And the reclaim assertion only counted calls, so a reclaim to the
wrong size still passed; it now asserts the exact jiggle. Worth noting what that
exposed: the jiggle is at 80x24, not the 95x34 fitted, because `onViewFit` does
not resize the Dart-side terminal that `_refitActiveSession` reads. That is a
harness artefact rather than a product bug, but it is why the assertion names
80x24.

2026-08-10T00:04-0700 Review loop, and the finding that mattered this round:
the foreground gate added at 21:00 created a fresh way to hide drift. The attach
refresh skips its resize when backgrounded, but went on passing the size it
*wanted* to `_applySnapshotToSession` as `renderSize`, which records it as the
host's size. So the client wrote "the host is at my size" immediately after
deciding not to put it there, and the refocus reclaim then saw no drift. Same
failure as the `lastFittedCols` bug from 21:00, reached through a different
door, and introduced by the fix for it. Replaced `replayTargetSize` with a
`drivenSize` that is set only where the host was actually moved: a successful
restore, a successful resize, or a snapshot that already matches. Otherwise it
stays null and the snapshot's own size is used, which is the host's real size.

Worth naming the pattern, since this is twice now: both bugs came from recording
an intention as an observation. The fields are named for what they are (`own`
fit, `host` size) but the assignments kept being made from whatever value was in
scope.

2026-08-10T00:04-0700 Review loop: gated the lazy-load attach resize in
`_loadDaemonSession`, previously listed below as a follow-up. It was the weakest
of the three resize-out paths, since it asserts `_estimatedTerminalRestoreSize`,
a MediaQuery guess this client has not fitted to and which clamps cols to 80.
A backgrounded reconnect could therefore move the shared PTY to a width nobody
was rendering at. Skipping costs nothing because the view's first fit resizes
once the client is visible.

2026-08-10T00:04-0700 Left the sleep-wake watchdog's `_refitActiveSession`
ungated on purpose, against a reviewer suggestion. The watchdog exists precisely
because macOS may deliver no lifecycle event across sleep/wake; in that case
`_clientForeground` is whatever it was before the machine slept, so gating on it
would suppress the heal in exactly the case the watchdog is there for. Trading a
rare unwanted resize for a reliable heal is the better side of that, but it is a
judgement call and is recorded as one.

2026-08-10T00:40-0700 Correction to the entry above, from round 2: the exemption
is native-only. On web `_refitActiveSession` is entirely
`terminalController.refit()`, which lands in the resize-out listener and is
therefore already dropped when `_clientForeground` is false. Only the native
`_client.resizeSession` jiggle is genuinely ungated. A reviewer also noted that
the dropped web send still advances `_lastRefitCols/_lastRefitRows` in
`terminal_pane_web.dart` before sending, so a suppressed refit poisons that
retry ladder's dedupe. Pre-existing and outside this branch, but it belongs with
the follow-ups below.

2026-08-10T00:40-0700 Round 2, and the same bug a third time: `_currentReplayTerminalSize`
picked the replay size from `lastFittedCols`, which the host's Snapshot
broadcast overwrites with whichever device last resized. So a foreground refresh
could compute the *other* device's width as its replay target, find that the
snapshot already matched it, and settle there with nothing left to correct it.
Now prefers `ownFittedCols`, falling back to `lastFitted*` only when this device
has never fitted, where the host's size is the better guess. Caught by a widget
test that fits to 95x34, lets a broadcast claim 47x19, and re-selects: with the
old field the client replays at 47x19.

Three instances now, all the same shape: a size that was wanted, or that
belonged to another device, recorded where a size the host actually has was
meant. The fields were split to make that distinction, and the assignments kept
reaching for whatever was nearest in scope.

## Verification

- `flutter analyze lib/`: no new issues (3 pre-existing, in untouched files).
- `flutter test`: 296 passing (284 before this round's tests: 9 unit cases on the
  two extracted decisions, 3 widget cases on the end-to-end paths), including
  the existing test that a plain focus change must not redraw the active
  session, which this preserves.
- Each new behaviour was mutation-checked rather than assumed: removing the
  foreground gate, reclaiming unconditionally, never reclaiming, and reverting
  either field choice each fail at least one test.
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

- ~~The attach path still asserts a size regardless of foreground.~~ Done
  2026-08-10T00:04-0700; see the Issues entry above.
- Two smaller sources of churn the same trace exposed, neither causing the
  duplication this fixes: rows drifting one at a time across separate resize
  calls with cols stable (`95x32 -> 95x33 -> 95x34`), and an occasional two-step
  width settle (`36x37 -> 86x35 -> 95x34`).
- The focus-loss-on-resize reported above, which this branch does not fix.
- `terminal_pane_web.dart` advances `_lastRefitCols/_lastRefitRows` before
  sending, so a refit the foreground gate drops still counts as sent and the
  retry ladder dedupes against a size the host never received.
- `_refreshSessionSnapshot`'s `includeHistory: false` default is unreachable:
  all three call sites pass true, so the `_savedOrEstimatedTerminalRestoreSize`
  fallback and the `replayTargetSize == null` guard are dead.
- `onViewFit` resolves `_selectedSession` when the deferred callback runs, not
  when the fit was measured, so a session switch inside that window can write
  `ownFitted*` onto the wrong session. A very tight window, but that field now
  decides whether to reclaim rather than only recording bookkeeping.
- `_estimatedTerminalRestoreSize` is desktop-shaped on every platform: it
  subtracts a sidebar that is an overlay on mobile, assumes 44px of padding
  where mobile uses 16, and clamps cols to a minimum of 80 on a display that
  fits about 40. That clamp is the 80-column intermediate visible in the trace
  above. Untouched here.

## Commits

- 6161cbd: fix(triage_client): let only the focused client size the shared PTY
- e4d765b: fix(triage_client): compare drift against the host's size, not our own
- 149c7e7: fix(triage_client): stop manufacturing drift on the re-attach path
- HEAD: test(triage_client): cover the resize arbitration decisions
