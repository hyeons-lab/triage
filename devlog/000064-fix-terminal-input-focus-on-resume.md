# fix/terminal-input-focus-on-resume

**Agent:** Claude Code (claude-opus-4-8) @ triage branch fix/terminal-input-focus-on-resume

## Intent

Fix a bug where the active terminal session silently stops accepting keyboard input after
the machine resumes (e.g. from display/system sleep). The only workaround was to switch to
another session and back.

## What Changed

- 2026-06-10T12:06-0700 `flutter/triage_client/lib/main.dart` — Added
  `_refocusActiveSessionOnResume()` to `_TriageHomeState` and called it from both resume
  sites (the `AppLifecycleState.resumed` branch and the wall-clock wake watchdog), right
  after `_redrawActiveSessionOnResume()`. It bumps the active session's
  `focusCursorRevision` inside `setState`, which drives the terminal pane to re-request
  keyboard focus on its next rebuild — the same channel a session switch uses, honored by
  both the native and web panes.
- 2026-06-10T12:06-0700 `flutter/triage_client/test/widget_test.dart` — Added
  "refocuses the active session when resuming after occlusion": asserts the active
  `TerminalPane.focusCursorRevision` is unchanged by a bare inactive→resumed cycle but
  increments after a full occlusion (hidden) → resume.

## Decisions

- 2026-06-10T12:06-0700 Reuse the existing `focusCursorRevision` mechanism instead of
  reaching for the pane's `FocusNode` directly — `main.dart` has no handle to it, and the
  revision channel is already the proven path that the session switch (the user's
  workaround) uses. Bonus: both the native and web panes honor it, so the single change
  covers both clients.
- 2026-06-10T12:06-0700 Keep refocus separate from `_redrawActiveSessionOnResume()` rather
  than folding it in — the resize-heal early-returns for non-remote / not-attached
  sessions, but focus should be restored for the active session regardless.
- 2026-06-10T12:06-0700 Gate refocus on genuine occlusion (the same `_wasOccluded` /
  watchdog-gap gates as the resize-heal) so a bare desktop focus change
  (`inactive`→`resumed`, no occlusion) does not steal focus back.

## Issues

- 2026-06-10T12:06-0700 First attempt asserted on `focusManager.primaryFocus` /
  `FocusNode.hasFocus`. It failed: under `FLUTTER_TEST` the stub pane renders a plain
  fallback `Container` (see `terminal_pane_stub.dart` build), so the xterm `TerminalView`
  and its real `FocusNode` are never in the tree — `find.byType(TerminalView)` returns 0
  and `primaryFocus` is the Navigator/Modal scope, not the terminal. Real focus state is
  therefore not observable in widget tests. Rewrote the test to assert on the
  `TerminalPane.focusCursorRevision` prop instead, which is the fix's actual contract and
  is present in the tree.

## Research & Discoveries

- 2026-06-10T12:06-0700 `SessionVm.focusCursorOnNextDisplay()` (bumps `focusCursorRevision`)
  was called from exactly one place: `_selectSession`. Both pane implementations re-request
  focus in `didUpdateWidget` when that revision changes. The resume path healed layout via
  a PTY resize jiggle but never touched focus — hence input dying until a session switch.

## Commits

- HEAD — fix(client): restore terminal input focus after resume from sleep
