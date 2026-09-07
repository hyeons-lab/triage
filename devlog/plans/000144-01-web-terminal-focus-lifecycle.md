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

## Section 2: Restoring Input After Session Switching

### Thinking

After testing the initial focus lifecycle adjustments, a critical regression scenario remained when switching away from an active session (such as Codex) and then switching back:

1. Inactive session textarea activeElement lockout:
   - When switching from Session 2 back to Session 1, Session 2's `xterm-helper-textarea` remained as `html.document.activeElement` in the browser DOM.
   - In `_activateTerminal()` and `_eventTargetsTerminal()`, the check `(active is html.TextAreaElement && !_container.contains(active))` evaluated to true because Session 2's textarea was not inside Session 1's container.
   - Consequently, `_activateTerminal()` exited prematurely without requesting Flutter focus or focusing Session 1's textarea, and `_eventTargetsTerminal()` returned false on ambient keystrokes.
   - Fix: define `_isExternalInput(html.Element? element)` that exempts any `xterm-helper-textarea` or elements within any session container (`_sessionContainers.values`), ensuring dormant terminal textareas do not block the active pane from claiming focus.

2. `primaryFocus` rejection on rail interaction:
   - Clicking a rail tile (`SessionListTile` / `InkWell`) sets Flutter's `primaryFocus` to the tile's `FocusNode`.
   - Because `InkWell` is not a `FocusScopeNode` and has a valid `BuildContext`, the previous check `primaryFocus != null && primaryFocus != _focusNode && primaryFocus is! FocusScopeNode` rejected ambient keystrokes.
   - Ambient keystrokes should only be yielded if the focused widget is an editable text field (`EditableText`).
   - Fix: check `isEditable` via `ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null`.

3. Rail tile focus isolation:
   - Set `canRequestFocus: false` on `SessionListTile`'s `InkWell`.
   - Call `FocusManager.instance.primaryFocus?.unfocus();` in `_selectSession` so switching sessions immediately clears stale focus.

4. Unmounted pane blur cleanup:
   - In `_TerminalPaneState.dispose()`, if the pane's helper textarea or terminal had DOM focus, explicitly invoke `blur()` to prevent zombie active elements.

5. DOM attachment synchronization:
   - Check `_container.isConnected` before focusing the textarea in `_activateTerminal()`. If not yet attached, schedule a retry on `requestAnimationFrame`.

### Plan

1. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Implement `_clearFocusRetryTimers()` helper and clean up timers when fired or disposed.
   - Implement `_isExternalInput(html.Element? element)` helper.
   - Update `_activateTerminal()` to check `_isExternalInput`, update `_currentMountedPane` after the guard, request Flutter focus, check `_container.isConnected`, and focus xterm.
   - Update `_eventTargetsTerminal()` to check `isEditable` and `_isExternalInput`.
   - In `dispose()`, blur active textarea and `_term`, and clear timers.
2. In `flutter/triage_client/lib/main.dart`:
   - Call `FocusManager.instance.primaryFocus?.unfocus()` in `_selectSession`.
   - Set `canRequestFocus: false` on `SessionListTile` `InkWell`.
3. Validate with `flutter analyze`, `flutter test`, `cargo fmt`, `cargo clippy`, and `cargo test`.

## Section 3: Shadow DOM Focus Traversal and Idle Host Guard Refinement

### Thinking

In Flutter Web, platform views (`HtmlElementView`) are mounted inside shadow roots within `<flt-platform-view>`. Under the DOM specification, querying `document.activeElement` retargets active elements inside shadow roots to their containing host element (`<flt-platform-view>` or `<flt-glass-pane>`).

Consequently:
1. `_isActiveElementInTerminal()` checked `_container.contains(html.document.activeElement)`. Because `_container` is a descendant of the shadow host rather than an ancestor, this check constantly evaluated to false even when xterm's textarea possessed DOM focus.
2. Because `_isActiveElementInTerminal()` evaluated to false, `_windowKeyDownListener` intercepted every key event during the capture phase, called `event.preventDefault()` and `event.stopPropagation()`, and prevented native browser dispatch to xterm's textarea.
3. In addition, Flutter Web retains idle hidden input elements (`flt-text-editing-host`). In `_isExternalInput()`, encountering these idle elements without an active `EditableText` falsely flagged external input locks and aborted `_activateTerminal()`.

### Plan

1. Implement `_deepActiveElement()` helper that traverses shadow roots (`active.shadowRoot?.activeElement`) until reaching the focused leaf element.
2. Update `_isActiveElementInTerminal()`, `_activateTerminal()`, `_eventTargetsTerminal()`, and `dispose()` to inspect `_deepActiveElement()`.
3. In `_isExternalInput()`, exempt Flutter Web engine internal text editing elements (`flt-text-editing`) unless Flutter's `primaryFocus` is an active `EditableText`.
4. Introduce `_activeTextarea` getter to ensure `_cachedTextarea` is re-queried if detached during platform view reparenting.
5. Verify analysis, test suites, and formatting.
