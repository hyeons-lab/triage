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
- 2026-09-07T01:15-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
  - Added `_isExternalInput(html.Element? element)` helper that exempts any `xterm-helper-textarea` or elements within any session container (`_sessionContainers.values`), ensuring dormant terminal textareas from unmounted sessions do not block the active terminal from claiming focus.
  - Updated `_activateTerminal()` to check `_isExternalInput`, assign `_currentMountedPane = this;` only after the input guard, request Flutter focus, and verify `_container.isConnected` before focusing the textarea (rescheduling via `requestAnimationFrame` if pending DOM attachment).
  - Replaced generic `primaryFocus` exclusion in `_eventTargetsTerminal()` with an explicit `EditableText` check so non-text controls (such as sidebar rail tiles or buttons) do not block ambient terminal keystrokes.
  - Added `_clearFocusRetryTimers()` helper, automatically removing each timer when it fires and clearing all pending timers on dispose.
  - Explicitly blurred active `textarea` and `_term` in `dispose()` to prevent zombie active elements in the browser DOM.
- 2026-09-07T01:15-0700 `flutter/triage_client/lib/main.dart`:
  - Added `FocusManager.instance.primaryFocus?.unfocus();` to `_selectSession` upon selecting any session so stale widget focus is cleared.
  - Set `canRequestFocus: false` on `SessionListTile`'s `InkWell` to prevent rail clicks from capturing focus.
- 2026-09-07T01:46-0700 `devlog/plans/000144-01-web-terminal-focus-lifecycle.md`: Added Section 3 detailing Shadow DOM activeElement retargeting, idle host input bypass, and retry expansion for new sessions.
- 2026-09-07T01:46-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
  - Added `_deepActiveElement()` helper to traverse Shadow DOM roots recursively and resolve the leaf active element.
  - Updated `_isActiveElementInTerminal()`, `_activateTerminal()`, `_eventTargetsTerminal()`, and `dispose()` to inspect `_deepActiveElement()` instead of `html.document.activeElement`.
  - Exempted Flutter Web engine internal text editing host elements (`flt-text-editing`) in `_isExternalInput()` unless an `EditableText` holds primary focus.
  - Introduced `_activeTextarea` getter ensuring cached textarea is verified for DOM connection and re-queried if detached.
  - Invoked `_term.focus()` alongside `textarea.focus()` in `_focusTerminal()` and `_activateTerminal()`.
  - Moved post-frame focus retry timers `[50, 150, 300]` outside the `cachedContainer` check so newly created sessions also benefit from focus retries.
- 2026-09-07T09:22-0700 `devlog/plans/000144-01-web-terminal-focus-lifecycle.md`: Added Section 4 covering input lease self-healing, gesture-driven focus retries, and dialog dismissal cursor reactivation.
- 2026-09-07T09:22-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
  - Added recursive `_isFlutterInternalElement()` checking light DOM and shadow root ancestor chains for `flt-` and `flutter-` tags and class names.
  - Updated `_isExternalInput()` to evaluate Flutter internal elements against active `EditableText` focus so hidden engine text inputs do not lock the terminal.
  - Added `force` parameter to `_activateTerminal()` and `_scheduleFocusRetries()` to bypass external input checks on explicit user gestures.
  - Passed `force: true` to `_activateTerminal()` and `_scheduleFocusRetries()` on container `onMouseDown`, `onClick`, and `onTouchEnd` events, as well as `onFocusChange` and `onTapDown`.
  - Updated `didUpdateWidget()` to re-assert active pane authority, invoke `_activateTerminal()`, and schedule focus retries on `focusCursorRevision` or `controller` changes.
- 2026-09-07T09:22-0700 `flutter/triage_client/lib/main.dart`:
  - Updated `_setupSessionInputListener()` to self-heal and re-acquire `InteractiveController` lease on demand via `_client.attachSession()` rather than discarding input or falsely marking the session disconnected.
  - Updated `_selectSession()` to restore `session.status = 'attached'` and reset `statusColor` if the client is connected and the session was marked disconnected.
  - Updated `_openCustomLabelDialog()` and `_closeSession()` to call `session.focusCursorOnNextDisplay()` upon dialog dismissal.
- 2026-09-07T16:36-0700 `devlog/plans/000144-01-web-terminal-focus-lifecycle.md`: Added Section 5 detailing session event lookup refinement, pending event buffer draining, live write gating elimination on user typing, and non-destructive controller updates.
- 2026-09-07T16:36-0700 `flutter/triage_client/lib/main.dart`:
  - Updated `_processWebSocketEvent` to match sessions by `remoteSessionId`, `sessionId`, or `title`, and immediately drain pending buffered events once the session is not loading.
  - Passed explicit `sessionId` to `SessionVm` constructor in `_createSession`.
- 2026-09-07T16:36-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
  - In `onWrite`, immediately finalized initial content and wrote directly to `term` if valid fitted dimensions exist, eliminating live write output stalling in `_pendingLiveWriteBuffer`.
  - In `_sendInput` and `onDataCallback`, finalized initial content when fitted and flushed pending live writes.
  - In `_activateTerminal`, flushed pending live writes upon terminal activation.
  - Removed destructive `_triggerFullReplayOrReset()` call on controller update in `didUpdateWidget`.
  - Removed `_resetTerminalSafe()` screen clearing and `_pendingLiveWriteBuffer.clear()` from `_triggerFullReplayOrReset()`, and removed unused helper.
- 2026-09-07T18:44-0700 `.mcp.json`, `.gemini/`, `.claude/`, `.qoder/`, `.kiro/`, `.opencode.json`, `.cursorrules`, `.windsurfrules`, `GEMINI.md`, `QODER.md`, `.github/code-review-graph.instruction.md`, `AGENTS.md`, `CLAUDE.md`, `.gitignore`:
  - Completely uninstalled code-review-graph: deleted repository configurations, tool hooks, and agent instructions.
  - Terminated background code-review-graph processes and removed local `.code-review-graph` database caches.
  - Clean rebuilt Flutter web client release bundle, recompiled `triaged` in release mode, and executed zero-downtime daemon handover preserving all 28 live sessions.

## Decisions

- 2026-09-06T23:05-0700 Exclude `FocusScopeNode` from `primaryFocus` check: In Flutter, when no child widget holds focus, `primaryFocus` defaults to the route `FocusScopeNode` (which retains a non-null context). Exclude `FocusScopeNode` so ambient window keydown events are routed to the active terminal pane when no input field holds focus.
- 2026-09-06T23:05-0700 Guard `_activateTerminal()` on `!mounted`: Abort before inspecting widget properties or DOM elements if the state is unmounted.
- 2026-09-06T23:05-0700 Re-assert `_currentMountedPane` on `_activateTerminal()`: Ensure user interactions (such as clicks, taps, or refits) dynamically establish pane authority for ambient keystroke handling.
- 2026-09-06T23:06-0700 Short-circuit focus retries once verified: Cancel remaining retry timers immediately if `_isActiveElementInTerminal() && _focusNode.hasFocus` is true to avoid unnecessary DOM queries and refocus attempts.
- 2026-09-06T23:13-0700 Guard SelectElement and match event.code Tab: Ensure native dropdowns are not intercepted and Tab navigation is symmetrically bypassed.
- 2026-09-07T01:15-0700 Distinguish external form inputs from terminal helper textareas: An inactive session's `xterm-helper-textarea` can remain as `html.document.activeElement` when switching sessions. Exempting `xterm-helper-textarea` and any element within `_sessionContainers` prevents `_activateTerminal()` and `_eventTargetsTerminal()` from treating dormant sessions as external form fields.
- 2026-09-07T01:15-0700 Restrict `primaryFocus` ambient bypass to `EditableText`: In Flutter, clicking buttons or list tiles assigns focus to their `FocusNode`. Only yield ambient keystrokes if the focused widget actually accepts text editing (`EditableText`).
- 2026-09-07T01:15-0700 Re-attempt focus on `requestAnimationFrame` when disconnected: Calling `.focus()` on a DOM element not yet connected to the document is a silent no-op. If `!_container.isConnected`, schedule focus once the browser attaches the platform view.
- 2026-09-07T01:46-0700 Deep Shadow DOM traversal for activeElement: Under standard DOM semantics, `document.activeElement` on platform view elements retargets to the shadow host (`<flt-platform-view>` or `<flt-glass-pane>`). Traversing `shadowRoot.activeElement` recursively resolves the true focused element, preventing window capture listeners from mistaking focused xterm textareas for inactive elements and suppressing keystrokes.
- 2026-09-07T01:46-0700 Differentiate Flutter engine idle input hosts: Flutter Web maintains hidden text editing host elements in the DOM even when no text field is active. Exempting `flt-text-editing` elements unless an `EditableText` is focused prevents false external input locks from aborting `_activateTerminal()`.
- 2026-09-07T01:46-0700 Apply focus retries to new sessions: Newly created sessions register platform views that take multiple frames to attach and layout in the browser DOM. Scheduling focus retries across both new and cached containers guarantees reliable terminal input activation.
- 2026-09-07T09:22-0700 Self-healing input lease re-attachment: If `writeInput()` fails or input is received for a session whose status is not attached, check `_client.isConnected`. If the WebSocket is alive and the session is not exited, request an `InteractiveController` lease via `attachSession()` and retry the write instead of disconnecting the session.
- 2026-09-07T09:22-0700 Gesture-driven focus enforcement: Direct mouse, click, and touch gestures on the terminal container or GestureDetector indicate unambiguous user focus intent. Bypassing external input guards via `force: true` and triggering the retry ladder ensures focus immediately transfers to xterm.
- 2026-09-07T09:22-0700 Dialog dismissal cursor focus restoration: Closing modal dialogs like custom label renaming leaves DOM focus on hidden Flutter engine elements. Invoking `session.focusCursorOnNextDisplay()` on dismissal increments `focusCursorRevision` and triggers terminal focus reactivation.
- 2026-09-07T16:36-0700 Resilient remote session lookup in WebSocket event processing: Match remoteSessionId, sessionId, and title fallback in _processWebSocketEvent so sessions with custom labels or renamed titles route events reliably.
- 2026-09-07T16:36-0700 Proactive pending event draining on WebSocket messages: Once a session is not in loading state, immediately drain any buffered events from _pendingEvents before handling new messages to preserve message sequence and output order.
- 2026-09-07T16:36-0700 Immediate live write finalization on user input: If the user sends input or incoming output arrives while valid fitted dimensions are present, finalize initial content immediately rather than waiting for stability timers, avoiding output stalls.
- 2026-09-07T16:36-0700 Eliminate destructive screen clearing on controller swap: Terminal state is owned by xterm.js in the browser; controller swaps during rebinds must not clear the screen or wipe pending live buffers.
- 2026-09-07T18:44-0700 Complete removal of code-review-graph: The code-review-graph MCP server, automated hooks, and database indexing spawned background processes on every session start and tool execution with long timeouts, causing process blocking and resource contention across active terminals.

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
- [x] Address session switch input restoration lockout
- [x] Exempt terminal helper textareas from external input guard
- [x] Restrict primaryFocus ambient rejection to EditableText
- [x] Blur unmounted session textarea on dispose
- [x] Unfocus stale widget focus on session selection
- [x] Implement Shadow DOM deep activeElement traversal
- [x] Exempt idle Flutter text editing hosts from external input guard
- [x] Apply focus retries to newly created sessions
- [x] Self-healing input lease re-attachment on input error
- [x] Direct user gesture forced focus retries on mousedown, click, touch, and tap
- [x] Dialog dismissal cursor focus restoration
- [x] Flutter internal element ancestor traversal in _isExternalInput()
- [x] Resilient session lookup and pending event draining in main.dart
- [x] Immediate live write finalization and flush in terminal_pane_web.dart
- [x] Eliminate destructive terminal resets and buffer clearing on controller update
- [x] Uninstall code-review-graph and remove automated tool hooks
- [x] Clean build Flutter web release bundle and reload daemon via zero-downtime handover

## Commits

- 833c770: fix(triage_client): harden web terminal focus lifecycle and ambient routing
- 0baa475: fix(triage_client): restore input on session switch and refine focus delegation
- c747c84: fix(triage_client): penetrate shadow dom focus and eliminate external input false locks
- e192036: fix(triage_client): re-acquire input lease on demand and harden focus retry lifecycle
- e76d810: fix(triage_client): unblock session output stream and eliminate destructive resets
- HEAD: chore: uninstall code-review-graph and remove automated tool hooks

