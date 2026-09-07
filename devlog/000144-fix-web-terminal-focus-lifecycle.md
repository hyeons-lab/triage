# 000144: fix/web-terminal-focus-lifecycle

**Agent:** Antigravity (gemini-3.8-flash) @ triage branch fix/web-terminal-focus-lifecycle

## Intent

Refine web terminal focus lifecycle, primary focus scope checks, and ambient input routing in `terminal_pane_web.dart` to prevent ambient keystroke drops when no leaf widget holds focus, guard against unmounted DOM invocations, and ensure active pane tracking is preserved across user interactions.

## What Changed

- 2026-09-06T23:05-0700 `devlog/plans/000144-01-web-terminal-focus-lifecycle.md`: Created plan covering `FocusScopeNode` exclusion, `!mounted` guards in `_activateTerminal()`, dynamic `_currentMountedPane` updates, and Escape key matching.
- 2026-09-06T23:06-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
  - Added `primaryFocus is! FocusScopeNode` to ambient keydown filter in `_eventTargetsTerminal()` to avoid false rejections when no leaf widget holds focus.
  - Added matching for `event.key == 'Esc'` and `event.code == 'Escape'` alongside `Tab` and `Escape`.
  - Added early `!mounted` guard at the top of `_activateTerminal()`.
  - Set `_currentMountedPane = this;` inside `_activateTerminal()` to dynamically update pane authority on user interaction.
  - Short-circuited and cancelled remaining `_focusRetryTimers` when focus is already acquired on frame retries.
  - Added `html.SelectElement` to external input exclusion filters in `_activateTerminal()` and `_eventTargetsTerminal()`.
  - Added symmetrical `event.code == 'Tab'` to navigation key filter in `_eventTargetsTerminal()`.

## Decisions

- 2026-09-06T23:05-0700 Exclude `FocusScopeNode` from `primaryFocus` check: In Flutter, when no child widget holds focus, `primaryFocus` defaults to the route `FocusScopeNode` (which retains a non-null context). Exclude `FocusScopeNode` so ambient window keydown events are routed to the active terminal pane when no input field holds focus.
- 2026-09-06T23:05-0700 Guard `_activateTerminal()` on `!mounted`: Abort before inspecting widget properties or DOM elements if the state is unmounted.
- 2026-09-06T23:05-0700 Re-assert `_currentMountedPane` on `_activateTerminal()`: Ensure user interactions (such as clicks, taps, or refits) dynamically establish pane authority for ambient keystroke handling.
- 2026-09-06T23:06-0700 Short-circuit focus retries once verified: Cancel remaining retry timers immediately if `_isActiveElementInTerminal() && _focusNode.hasFocus` is true to avoid unnecessary DOM queries and refocus attempts.
- 2026-09-06T23:13-0700 Guard SelectElement and match event.code Tab: Ensure native dropdowns are not intercepted and Tab navigation is symmetrically bypassed.

## Issues

- None.

## Progress

- [x] Create worktree and branch devlog / plan
- [x] Refine `_eventTargetsTerminal()` in `terminal_pane_web.dart`
- [x] Refine `_activateTerminal()` in `terminal_pane_web.dart`
- [x] Short-circuit retry timers once focus is verified
- [x] Verify formatting, analysis, and test suites
- [x] Run Round 3 review subagent at max effort
- [x] Address Round 3 review suggestions (SelectElement, event.code Tab)

## Commits

- HEAD: fix(triage_client): harden web terminal focus lifecycle and ambient routing

