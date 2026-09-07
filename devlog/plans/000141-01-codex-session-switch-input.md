# Plan: Fix Codex Session Switch Input Loss

## Thinking

When switching sessions in the Triage web client (e.g. from session A to Codex session B, or between any sessions) and attempting to type into the terminal, input is not accepted until the user explicitly clicks the terminal grid.

### Root Cause Analysis

1. Event targeting bug in `_eventTargetsTerminal`:
   - In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`, `_windowKeyDownListener` intercepts key events on `window` and filters them with `_eventTargetsTerminal(event)`.
   - When switching sessions via the sidebar rail or session tabs, browser focus leaves the terminal and rests on `<body>` or `<flt-glass-pane>`. As a result, `_focusNode.hasFocus` is false and `event.target` is outside `_container`.
   - `_eventTargetsTerminal` checks whether focus is on an external HTML `<input>` or `<textarea>` (such as a modal search box or pairing input), intending to ignore keys only if another input control is active.
   - However, after checking `active is html.InputElement || (active is html.TextAreaElement && !_container.contains(active))`, the method fell through to `return false;` instead of `return true;`.
   - Consequently, when focus was on `<body>` or the Flutter UI container, `_eventTargetsTerminal` returned `false`, dropping all window keydown events.
   - The fallback mechanism in `_windowKeyDownListener` (lines 448-456), which was specifically designed to catch the first keystroke when `_isActiveElementInTerminal()` is false, send it to the session, and refocus the xterm textarea, was completely bypassed.

2. Focus activation on mount and session re-selection:
   - When returning to a cached session, `_activateTerminal()` in `initState` attempts to focus the xterm helper textarea via `textarea.focus([opts])`.
   - In Flutter Web, platform views (`HtmlElementView`) undergo DOM attachment and style reconciliation across frames. Calling `textarea.focus()` once during initial frame callback may be dropped if the DOM view is not yet fully settled or if Flutter resets focus to its glass pane.
   - Additionally, `_activateTerminal()` did not request focus on `_focusNode`, leaving Flutter's focus tree unaware that the terminal pane should hold focus.

3. Fix approach:
   - Correct `_eventTargetsTerminal`: if the event target is not within `_container` and `_focusNode.hasFocus` is false, but focus is also not on an external input, textarea, or contentEditable element, return `true` so the active terminal pane receives the keydown event.
   - Guard against stale panes during transitions by verifying that `_containerEventOwners[_sanitizedId]` matches `this`.
   - Update `_activateTerminal()` to ensure `_focusNode.requestFocus()` is called when mounted, and both `textarea.focus([opts])` and `_term.focus()` are invoked to keep xterm's internal state synchronized.
   - Add delayed retry focus activations on cached container mount to ensure the textarea receives browser focus even after platform view layout transitions settle.

## Plan

1. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Update `_eventTargetsTerminal` to return `true` when focus is not on an external input or editable element, and ensure owner identity check.
   - Update `_activateTerminal` to request `_focusNode` focus and call `_term.focus()`.
   - In `initState`, add short delay retries to `_activateTerminal()` post-frame callbacks for cached session adoption.
2. Validate with `flutter analyze` and `flutter test`.
3. Test against live triage daemon and codex session if possible.
4. Record findings and changes in `devlog/000141-fix-codex-session-switch-input.md`.
5. Build and verify formatting.
