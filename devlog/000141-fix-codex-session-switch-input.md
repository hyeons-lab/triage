# 000141: fix/codex-session-switch-input

**Agent:** Antigravity (gemini-3.8-flash) @ triage branch fix/codex-session-switch-input

## Intent

Fix terminal input failing when switching sessions (such as to Codex or between existing sessions) in the Flutter web client until the terminal view is manually clicked with the mouse.

## What Changed

- 2026-09-06T21:43-0700 `devlog/plans/000141-01-codex-session-switch-input.md`: created plan documenting root cause in `_eventTargetsTerminal`, focus lifecycle on session switch, and actionable fixes.
- 2026-09-06T22:01-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
  - Fixed `_eventTargetsTerminal` to check `_containerEventOwners` identity and return `true` when focus is outside the terminal unless `activeElement` is an external input, textarea, or contentEditable element.
  - Added `_focusNode.requestFocus()` inside `_activateTerminal()` when mounted.
  - Added delayed focus retries (50ms and 150ms) in post-frame callback on cached container mount to ensure the textarea receives focus after platform view layout settles.
- 2026-09-06T22:58-0700 `devlog/plans/000141-02-address-pr-comments.md`: created plan to address review feedback from Copilot and Antigravity Code Review.
- 2026-09-06T22:58-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
  - Replaced `Future.delayed` calls with tracked `_focusRetryTimers` list and cancelled them on `dispose()`.
  - Restricted post-frame focus retries strictly to cached container mounts.
  - Added route liveness guard in `_activateTerminal()` to prevent focus-stealing after route transitions.
  - Added ambient keystroke yield to external Flutter widgets holding primary focus and excluded Tab/Escape keys.
  - Maintained `_currentMountedPane` tracking across `initState`, `didUpdateWidget`, and `dispose()`.

## Decisions

- 2026-09-06T21:43-0700 Intercept window keydown events when focus is outside the terminal container unless activeElement is an external input or editable field: when switching sessions, focus defaults to `<body>` or `<flt-glass-pane>` outside `_container`. The fallback in `_windowKeyDownListener` was intended to capture this first keystroke, send it, and focus the xterm textarea. Returning false in `_eventTargetsTerminal` when focus was on `<body>` completely disabled this fallback.
- 2026-09-06T22:01-0700 Added `_containerEventOwners` identity guard in `_eventTargetsTerminal`: ensures only the active pane owning the session container receives window keydown events during widget tree transitions.
- 2026-09-06T22:58-0700 Track focus retry timers explicitly on state: raw closures in `Future.delayed` keep state references alive in the event loop during rapid session switching. Explicit timers stored in `_focusRetryTimers` ensure clean disposal.
- 2026-09-06T22:58-0700 Guard `_activateTerminal()` with route liveness check: delayed callbacks could run after the user navigates to another screen or modal dialog. Checking `_currentRoute?.isCurrent` avoids stealing focus from active routes.
- 2026-09-06T22:58-0700 Yield ambient window keydown events when primaryFocus is held or navigation keys are pressed: prevents terminal input from intercepting Tab/Escape or keystrokes meant for other Flutter controls.

## Commits

- 3faa329: fix(triage_client): restore web terminal input after switching sessions
- HEAD: fix(triage_client): address PR comments on focus lifecycle and ambient input
