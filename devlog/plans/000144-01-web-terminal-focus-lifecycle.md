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

## Section 4: Self-Healing Input Lease Recovery and Gesture-Driven Focus Retries

### Thinking

Investigating the user report where Codex input remained stuck after switching or editing custom labels revealed two interacting failure modes:

1. Session input lease loss followed by permanent client lockout:
   - When a remote session's input lease is released, expired, or contested, the daemon rejects `write_input` with an RPC error.
   - In `flutter/triage_client/lib/main.dart` (`_setupSessionInputListener`), any error from `writeInput` was caught by `.catchError((_) { _markRemoteSessionDisconnected(session); })`.
   - `_markRemoteSessionDisconnected` marked `session.status = 'disconnected'` and set the connection status to 'Connection Closed'.
   - Once marked `disconnected`, subsequent keystrokes were dropped immediately by `if (session.status != 'attached') return;`.
   - Even though the WebSocket connection was completely intact and the process was healthy, the client permanently locked the user out of typing into that session.
   - Solution: In `_setupSessionInputListener`, when `_client.isConnected`, handle lease errors by requesting an `InteractiveController` lease via `_client.attachSession` and retrying the write. If `session.status != 'attached'` but `_client.isConnected` and `session.status != 'exited'`, automatically re-attach and forward input instead of discarding keystrokes. When selecting a session in `_selectSession`, heal any stale `disconnected` status back to `attached`.

2. Direct user gestures and dialog dismissal focus restoration:
   - Clicking, tapping, or touching directly on the terminal container represents unambiguous user intent. In `_bindContainerEvents`, container `onMouseDown`, `onClick`, and `onTouchEnd` listeners must pass `force: true` to `_activateTerminal` and `_scheduleFocusRetries` to break out of any stale focus states.
   - In `TerminalPane.didUpdateWidget`, invoke `_activateTerminal()` and trigger `_scheduleFocusRetries(force: true)` when `focusCursorRevision` or `controller` changes.
   - In `_openCustomLabelDialog` and `_closeSession`, ensure `session.focusCursorOnNextDisplay()` is invoked upon dismissal so terminal focus is restored.

### Plan

1. In `flutter/triage_client/lib/main.dart`:
   - Update `_setupSessionInputListener` to re-acquire the `InteractiveController` lease on demand when connected rather than marking the session disconnected.
   - In `_selectSession`, restore `session.status = 'attached'` and reset `statusColor` if the client is connected.
   - In `_openCustomLabelDialog` and `_closeSession`, call `session.focusCursorOnNextDisplay()` on dismissal.
2. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Pass `force: true` to `_activateTerminal` and `_scheduleFocusRetries` on container mouse, click, and touch events.
   - In `didUpdateWidget`, trigger focus activation and retries on controller and revision changes.
   - In `build`, trigger forced activation and retries on `onFocusChange` and `onTapDown`.
3. Verify formatting and test suites:
   - Run `dart format`, `flutter analyze`, and `flutter test`.
   - Run `cargo fmt`, `cargo clippy`, and `cargo test`.

## Section 5: Unblocking Codex Session Echoes and Eliminating Web Output Stalling

### Thinking

Detailed debugging of session-218 (`stuck-codex`) revealed three cooperating root causes preventing user keystrokes from displaying:

1. Remote session event lookup and event stranding in `main.dart`:
   - `_processWebSocketEvent` looked up sessions using `s.title == 'triage / $sessionId'`.
   - If `s.title` diverged (such as when custom labels or renamed titles were used), `sessionIndex` evaluated to `-1`.
   - When `sessionIndex == -1` or `session.status == 'loading'`, incoming WebSocket events (such as `Output`) were buffered into `_pendingEvents[sessionId]`.
   - Even when `sessionIndex != -1` and `session.status != 'loading'`, `_processWebSocketEvent` never drained `_pendingEvents[sessionId]`. Events buffered during loading or transitions remained trapped indefinitely.
   - In addition, `_createSession` created `SessionVm` without passing `sessionId: sessionId`, leaving `remoteSessionId` dependent on parsing `title`.
   - Solution: In `_processWebSocketEvent`, match sessions via `s.remoteSessionId == sessionId || s.sessionId == sessionId || s.title == 'triage / $sessionId'`. Before processing a live event, drain any queued events from `_pendingEvents.remove(sessionId)`. In `_createSession`, pass `sessionId: sessionId`.

2. Live output buffering stall in `terminal_pane_web.dart`:
   - In `onWrite(String data)`: if `activePane._initialContentWritten` is false, incoming data is pushed into `activePane._pendingLiveWriteBuffer` instead of being written directly to `_term`.
   - `_initialContentWritten` is only set to true by `_finishInitialContent()`, which waits for a 250ms stability timer or 800ms force-finalize timer in `_onFit()`.
   - When the user types, `_sendInput` sends bytes to the backend, which echoes them back over WebSocket. Because the user is typing while `_initialContentWritten` is false, the echoed bytes are held in `_pendingLiveWriteBuffer` indefinitely without being rendered.
   - Neither `_sendInput` nor `_sendMobileInput` flushed `_pendingLiveWriteBuffer` or finalized initial content.
   - Solution: In `onWrite`, if `activePane._lastFittedCols >= 10 && activePane._lastFittedRows >= 5`, immediately call `_finishInitialContent` and write to `term`. In `_sendInput` and `_sendMobileInput`, if valid fitted dimensions exist, immediately call `_finishInitialContent`, and always call `_flushPendingLiveWrites()`. In `_activateTerminal`, also flush `_flushPendingLiveWrites()`.

3. Destructive terminal clearing on controller update:
   - In `didUpdateWidget`, when `oldWidget.controller != widget.controller`, `_triggerFullReplayOrReset()` called `_resetTerminalSafe()`, sending `\x1b[2J\x1b[3J\x1b[H` to clear xterm.js.
   - Because `session.hasFitted` was already true, `noteViewFit` returned early without replaying history. The existing terminal buffer was wiped clean, leaving the display blank.
   - Furthermore, if `!_initialContentWritten`, `_triggerFullReplayOrReset()` called `_pendingLiveWriteBuffer.clear()`, destroying pending output chunks.
   - Solution: Remove `_triggerFullReplayOrReset()` from the controller update path in `didUpdateWidget`. The controller itself issues `clear()` via its sink listener when a genuine reset is required. In `_triggerFullReplayOrReset()`, remove `_resetTerminalSafe()` and `_pendingLiveWriteBuffer.clear()` to prevent destructive buffer wipes.

### Plan

1. In `flutter/triage_client/lib/main.dart`:
   - Update `_processWebSocketEvent` session lookup to check `s.remoteSessionId == sessionId || s.sessionId == sessionId || s.title == 'triage / $sessionId'`.
   - In `_processWebSocketEvent`, drain `_pendingEvents.remove(sessionId)` before handling incoming events once the session is not loading.
   - Pass `sessionId: sessionId` when constructing `SessionVm` in `_createSession`.
2. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - In `onWrite`, if `activePane` has fitted dimensions, finalize initial content and write directly to `term`.
   - In `_sendInput` and `_sendMobileInput`, finalize initial content if fitted, and always call `_flushPendingLiveWrites()`.
   - In `_activateTerminal`, flush `_flushPendingLiveWrites()`.
   - In `didUpdateWidget`, remove `_triggerFullReplayOrReset()` from the `oldWidget.controller != widget.controller` block.
   - In `_triggerFullReplayOrReset()`, remove `_resetTerminalSafe()` and `_pendingLiveWriteBuffer.clear()`.
3. Validate and build:
   - Format with `dart format`.
   - Verify with `flutter analyze` and `flutter test`.
   - Check `cargo check --workspace` and `cargo test --workspace`.
   - Rebuild web bundle and reload daemon.

## 6. Code-Review-Graph Uninstallation and Tool Hook Removal

### Thinking

The code-review-graph MCP server and automated tool hooks (such as `.gemini/hooks/crg-update.sh` and `.claude/settings.json`) run on session starts and tool use with long timeouts (up to 30s). When background terminals and agents run concurrently, multiple instances of `uvx code-review-graph serve` are spawned, holding file handles, executing incremental graph updates, and consuming process resources. Completely removing these configuration files, agent instructions, and background processes unblocks active development and terminal interactions.

### Plan

1. Delete `.mcp.json`, `.gemini/`, `.claude/`, `.qoder/`, `.kiro/`, `.opencode.json`, `.cursorrules`, `.windsurfrules`, `GEMINI.md`, `QODER.md`, and `.github/code-review-graph.instruction.md`.
2. Remove code-review-graph instruction sections from `AGENTS.md` and `CLAUDE.md`, and remove `.code-review-graph/` from `.gitignore`.
3. Kill all running `code-review-graph` background processes and remove local database caches.
4. Clean rebuild Flutter web client release bundle, compile release `triaged`, and reload daemon via zero-downtime handover.

## 7. Propagate Fitted Dimensions to Swapped Controllers and Eliminate Terminal Store History Deadlock

### Thinking

When a session is lazy-loaded via `_loadDaemonSessionInto`, a new `SessionVm` replaces the placeholder session. The new `SessionVm` is constructed with `_viewReady = false`, staging its history in `_pendingHistory` while awaiting `noteViewFit`. In `TerminalPane`, `didUpdateWidget` binds the new controller when `oldWidget.controller != widget.controller`, but previously never invoked `onViewFit` or `_writeInitialContent()`. Because the DOM container was already rendered and its pixel dimensions remained unchanged, `ResizeObserver` never fired. Consequently, `noteViewFit` was never called for the new `SessionVm`, `_pendingHistory` remained unplayed, and `TerminalStore` remained stuck in `AttachPhase.awaitingHistory`.

In this state, `TerminalStore._reduceLive` routes all incoming live output (including user typing echoes from Codex) into `_pendingLive` rather than writing to the sink. Because `HistoryBytes` was never dispatched, `_flushPendingLive` never ran, freezing the terminal display while keystrokes continued to reach the backend PTY.

Furthermore, `onWrite` in `terminal_pane_web.dart` should write directly to `term` whenever the xterm.js instance exists in memory rather than pushing data into `_pendingLiveWriteBuffer`.

### Plan

1. In `flutter/triage_client/lib/main.dart`:
   - In `_loadDaemonSessionInto`, carry forward fitted dimensions (`hasFitted`, `lastFittedCols`, `lastFittedRows`, `ownFittedCols`, `ownFittedRows`, `hostSizeCols`, `hostSizeRows`) and call `session.noteViewFit` if `oldSession._viewReady` or fitted dimensions exist.
   - In `SessionVm.applyLiveBytes`, if `!_viewReady` but `lastFittedCols != null && lastFittedRows != null`, invoke `noteViewFit` immediately so history and live bytes drain.
2. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - In `didUpdateWidget`, when `oldWidget.controller != widget.controller`, ensure `_containerEventOwners[_sanitizedId] = this;` and call `_writeInitialContent()` if `_initialized`.
   - In `didUpdateWidget`, always re-assert `_containerEventOwners[_sanitizedId] = this;`.
   - In `onWrite`, write directly to `term` if `term != null`.
3. Preserve stub invariants:
   - Keep `terminal_pane_stub.dart` sizing strictly driven by layout, avoiding false terminal size drift on app resume.
4. Validate and test:
   - Run `cargo check --workspace` and `cargo test --workspace`.
   - Run `flutter test`.
   - Build web bundle and execute zero-downtime reload.
