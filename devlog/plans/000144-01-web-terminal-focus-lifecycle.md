# Plan: Web Terminal Focus Lifecycle and Ambient Input Refinement

## Thinking

Following PR #166 merging into main at commit e311e2a, a rigorous local review loop (at max effort) identified key edge cases and lifecycle hazards in `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:

1. `primaryFocus` evaluation hazard:
   - When no child widget holds focus in the Flutter app (e.g. after tapping an empty space, switching sessions, or closing a modal), `FocusManager.instance.primaryFocus` evaluates to the current route's `FocusScopeNode`.
   - In Flutter, `FocusScopeNode` extends `FocusNode` and retains a non-null `BuildContext` (`context != null`).
   - Consequently, the previous guard `primaryFocus != null && primaryFocus != _focusNode && primaryFocus.context != null` evaluates to `true`, mistakenly treating the route focus scope as an external widget actively requesting input and discarding ambient keydown events.
   - Fix: check `primaryFocus is! FocusScopeNode` to ensure ambient keystrokes are only ceded when an actual leaf widget holds focus.

2. Unmounted execution hazard in `_activateTerminal()`:
   - `_activateTerminal()` lacked a `!mounted` guard at function entry before accessing widget properties and DOM elements.
   - Fix: add `if (!mounted || !_initialized || widget.isExited) return;`.

3. Re-asserting pane authority on user interaction:
   - When users click, tap, refit, or focus a terminal pane, `_activateTerminal()` is invoked.
   - Updating `_currentMountedPane = this;` inside `_activateTerminal()` dynamically keeps `_currentMountedPane` aligned with user interaction.

4. Defensive Escape key variant matching:
   - Legacy browsers or platform quirks can emit `Esc` or variant codes. Matching `event.key == 'Esc'` and `event.code == 'Escape'` alongside `event.key == 'Escape'` ensures escape navigation is never trapped.

5. Short-circuiting remaining focus retry timers:
   - Once focus is acquired (`_isActiveElementInTerminal() && _focusNode.hasFocus`), remaining retry timers can be cancelled immediately to avoid redundant focus work.

## Plan

1. Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - In `_eventTargetsTerminal()`: add `primaryFocus is! FocusScopeNode` and match `Esc`/`code == 'Escape'`.
   - In `_activateTerminal()`: add early `!mounted` guard and update `_currentMountedPane = this;`.
   - In `addPostFrameCallback`: cancel remaining retry timers if focus is already acquired.
2. Verify local compilation and analysis:
   - Run `flutter analyze` and `flutter test`.
   - Run workspace `cargo check` and tests.
   - Audit for em dashes.
3. Run Round 3 review subagent at max effort to verify all findings are resolved and diff is clean.
