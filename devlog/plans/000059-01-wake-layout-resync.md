# Plan: re-sync terminal width on app resume (wake-from-sleep layout fix)

## Thinking

Symptom (screenshot, `devlog/000059`): after the macOS client has been idle a long
time / the machine has slept, the active terminal renders with wrap fragmentation —
words split mid-token ("files" → "fi"+"les"), large gaps, lines re-wrapped at a
narrower width than the content was authored at. Manually resizing the window fixes
it instantly.

Root cause is the known view-width vs host-PTY-width mismatch (same family as the
first-load fix in #63). The history/live bytes in the xterm buffer are wrapped/
positioned for the host PTY width; when that differs from the client view width the
frame fragments. The cure is the resize round-trip in
`_refreshSessionSnapshot(includeHistory: true)`: it resizes the host to our current
fitted width, re-fetches the raw-output tail, and re-emulates at our width — exactly
what a manual resize triggers via the resize-out → host-resize → program-redraw path.

That reconciliation runs only on (a) first view-fit (`_onSessionViewFit`, gated by
`!hasFitted`), (b) session select (`_selectSession`), and (c) host `ResyncRequired`.
None of these reliably fires on wake-from-sleep:

- If the WebSocket stayed connected, `hasFitted` is already true and the window size
  is unchanged, so no fit callback and no resync happen — the stale-width buffer
  persists until a manual resize.
- If it reconnected (`_loadDaemonSessions` rebuilds sessions with `hasFitted=false`),
  the terminal is swapped under a reused `_TerminalPaneState`; on an unchanged window
  the view may not emit a fresh fit, so the one-shot first-fit reconcile is missed.

There is currently no app-lifecycle hook at all (`_TriageHomeState` does not implement
`WidgetsBindingObserver`). So nothing re-reconciles width when the app resumes.

Fix: implement `WidgetsBindingObserver` on `_TriageHomeState` and, when the app
returns to `resumed` after having been `hidden`/`paused`, force the active remote
session through `_refreshSessionSnapshot(includeHistory: true)` — the same proven
round-trip a manual resize uses. This covers both the stayed-connected and
reconnected cases without needing to know which one occurred.

Why gate on `hidden`/`paused` (not `inactive`): on desktop `inactive` fires on every
focus loss (menu open, click-away, Mission Control); resyncing on each would be far
too aggressive (a re-attach + replay per blur). `hidden`/`paused` indicate the app
was actually not visible / backgrounded — the closest signal to display-sleep — so we
only pay the resync when returning from genuine occlusion. The resync itself is
idempotent (identical to what `_selectSession` already does on every switch).

Verification limit: this cannot be exercised headless — app-lifecycle delivery on
macOS display-sleep/wake varies. Ship it, test on a real build by sleeping/waking. If
`resumed` does not fire on the user's wake path, the fallback is to also reconcile on
`didChangeMetrics` (window/DPR change) or to re-run the first-fit reconcile after a
reconnect explicitly.

## Plan

1. `flutter/triage_client/lib/main.dart`:
   - `class _TriageHomeState extends State<TriageHome> with WidgetsBindingObserver`.
   - `initState`: `WidgetsBinding.instance.addObserver(this);`.
   - `dispose`: `WidgetsBinding.instance.removeObserver(this);`.
   - Add `bool _wasOccluded = false;`.
   - `didChangeAppLifecycleState`: set `_wasOccluded = true` on `hidden`/`paused`;
     on `resumed`, if `_wasOccluded`, clear it and call `_resyncActiveSessionOnResume()`.
   - `_resyncActiveSessionOnResume()`: bail unless connected, `_sessions` non-empty,
     `_selectedIndex` in range, and the selected session is remote with a session id;
     then `unawaited(_refreshSessionSnapshot(session, includeHistory: true))`.
2. `flutter analyze` clean; existing tests still pass (no behavior change to the
   reducer or the headless test fallback — the new observer is inert under
   `flutter test`).
