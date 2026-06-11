# Plan: restore terminal input focus after resume from sleep

## Thinking

Symptom: after the machine resumes (e.g. from display/system sleep), the active terminal
session silently ignores keyboard input. The only known workaround is to switch to another
session and back.

That workaround is the tell. In `main.dart`, the only path that re-requests keyboard focus
for a session's terminal is `SessionVm.focusCursorOnNextDisplay()`, which bumps an integer
`focusCursorRevision`. The pane widgets (`terminal_pane_stub.dart` native and
`terminal_pane_web.dart` web) both watch that field in `didUpdateWidget` and call
`_scrollToCursor(requestFocus: true)` → `_focusNode.requestFocus()` when it changes.
`focusCursorOnNextDisplay()` is called from exactly one place: `_selectSession` (the
session switch). So switching sessions and back re-focuses the terminal — the workaround.

On resume, the app runs `_redrawActiveSessionOnResume()` (from both the
`AppLifecycleState.resumed` branch and the wall-clock wake watchdog). That heals *layout*
by jiggling the host PTY size, but never re-requests focus. During occlusion the OS/Flutter
engine drops the terminal's keyboard focus, and nothing restores it — so input goes
nowhere until a session switch.

Fix: on resume, re-request focus for the active session via the existing revision channel —
the same mechanism the session switch uses, so it's already proven and works for both panes.
Bump `focusCursorOnNextDisplay()` on the selected session inside `setState` so the pane
rebuilds, sees the changed revision, and re-focuses. Keep this independent of the
resize-heal guards (which only apply to remote/attached sessions) so a local or
not-yet-attached active session is refocused too.

## Plan

1. Add `_refocusActiveSessionOnResume()` to `_TriageHomeState`: guard on
   `_disposed`/`mounted` and a valid `_selectedIndex`, then `setState` →
   `_selectedSession.focusCursorOnNextDisplay()`.
2. Call it from both resume sites, right after `_redrawActiveSessionOnResume()`:
   the wake watchdog tick (large gap) and the `AppLifecycleState.resumed` branch.
3. Verify: `flutter analyze` clean; `flutter test` passes.
4. Commit devlog + plan + code; open PR.
