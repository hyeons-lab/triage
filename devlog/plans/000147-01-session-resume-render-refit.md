# Plan: Session Resume Render Refit and Scroll Position Fix

## Thinking

### Problem Analysis
There are two interconnected issues reported by the user:

1. **Refit Snaps to Top Bug**:
   - When the user clicks or taps the refit button, the terminal snaps all the way to line 0 (the top of scrollback).
   - In `terminal_pane_web.dart`, `_refitAndSend` calls `_onFit`, which executes `fitAddon.fit()`.
   - In `xterm.js`, `fit()` reflows buffer lines and recomputes the DOM `.xterm-viewport.scrollHeight`. During this reflow pass, `.xterm-viewport.scrollTop` is transiently out of sync, firing an `onScroll` event where `_viewportIsAtBottom` returns false.
   - Because `_suppressScrollSave` is false during refit, `onScrollCallback` saves `_sessionSavedViewportY = 0` (or the top viewport offset).
   - Immediately following `_refitActiveSession()`, `_refitAndFocusActiveSession()` in `main.dart` calls `_refocusActiveSession()`, bumping `focusCursorRevision`.
   - When `TerminalPane` rebuilds with the incremented revision, it invokes `_restoreScrollPosition(requestFocus: true)`.
   - `_restoreScrollPosition` reads `effectiveSavedY = _sessionSavedViewportY[_sanitizedId] == 0`, and explicitly calls `term.scrollToLine(0)`, snapping the viewport to the very top.
   - Retries at 50ms, 200ms, 600ms, and 1500ms reinforce this jump, preventing the user from staying at the bottom.

2. **Session Resume Rendering Corruption (Codex CLI sessions)**:
   - When switching between sessions, `TerminalPane` on Web disposes its state for the outgoing session, calling `_resizeObserver.disconnect()` and clearing `_resizeObserver = null`.
   - When resuming the session, `initState` adopts the cached container, but never re-attaches `_resizeObserver`.
   - At `initState`, the DOM element is not yet laid out (`clientWidth == 0`), so `_onFit()` bails immediately. With no `ResizeObserver` alive and no delayed retry timers scheduled on cached container adoption, the terminal is never refitted once attached to the DOM.
   - In `main.dart` `_selectSession`, selecting an already-fitted session (`session.hasFitted == true`) only refreshes metadata (`includeHistory: false`). Because snapshot dimensions on the daemon match the client's target dimensions, no resize is dispatched and no `SIGWINCH` is generated.
   - While in the background, interactive programs like Codex (built on Ink / React CLI) emit output and render question prompts. If the terminal geometry was un-fitted or if cursor coordinates drifted, Ink's relative cursor calculations (`\x1b[NA` cursor up) target wrong lines, producing overlapping, garbled text.
   - Only manual taps of the refit button currently fix it because refit sends a `SIGWINCH` resize jiggle (`rows - 1` then `rows`), prompting the child process to redraw.

### Strategy
1. **Fix Refit Snap to Top**:
   - In `terminal_pane_web.dart`:
     - Before invoking `_onFit()` or `fitAddon.fit()`, check if the terminal was currently at the bottom (`wasAtBottom`).
     - Suppress scroll saving (`_suppressScrollSaveFor`) during refit operations so transient resize/reflow scroll events cannot write `0` into `_sessionSavedViewportY`.
     - When `wasAtBottom` is true, explicitly remove `_sessionSavedViewportY` and call `term.scrollToBottom()`.
     - In `_restoreScrollPosition`, if `_sessionSavedViewportY` is not set or if `wasAtBottom` was true, ensure it invokes `scrollToBottom()`.
     - In `onScrollCallback`, guard against transient resize reflows reporting `viewportY = 0` when `baseY > 0` unless the user actually performed an intentional scroll action.

2. **Fix Session Resume & Codex Prompt Corruption**:
   - In `terminal_pane_web.dart`:
     - Extract `_setupResizeObserver()` and call it on container adoption in `initState` and `didUpdateWidget`.
     - Run `_triggerFitWithDelayedRetries()` in `initState` when adopting a cached container.
     - Call `term.refresh(0, fittedRows - 1)` in `_onFit` and `_refitAndSend` to ensure xterm.js forces a complete canvas/DOM row repaint.
   - In `main.dart`:
     - In `_selectSession`, when resuming an already-fitted session, schedule an automatic `_refitActiveSession()` post-frame when the session matches and client is connected.
     - This automatically refits the terminal emulator to the current layout and dispatches the resize jiggle to the host, triggering `SIGWINCH` so Codex repaints its prompt without requiring manual refit button clicks.
   - In `terminal_pane_stub.dart`:
     - Register `addRefitListener` so native terminal controller refit events trigger a widget rebuild and `_scrollToCursor(requestFocus: false)` to maintain bottom stickiness.

## Plan

1. Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Add `_setupResizeObserver()` helper and attach observer in cached container adoption.
   - Trigger delayed fit retries on cached container adoption in `initState`.
   - Record `wasAtBottom` before `fitAddon.fit()` and suppress scroll saving during fit and refit passes.
   - If `wasAtBottom` was true, enforce `scrollToBottom()` and clear `_sessionSavedViewportY`.
   - Call `term.refresh(0, rows - 1)` to repaint xterm.js row viewports on fit and refit.

2. Update `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
   - Add `addRefitListener` and `removeRefitListener` to `widget.controller`.
   - Implement `_onRefit` to rebuild and ensure scroll position aligns with bottom/cursor.

3. Update `flutter/triage_client/lib/main.dart`:
   - In `_selectSession`, schedule `_refitActiveSession()` in `addPostFrameCallback` for already-fitted sessions.

4. Add and update tests:
   - Add widget tests verifying that refit keeps the terminal at the bottom when not scrolled up.
   - Add tests verifying automatic refit dispatch upon session resume.
   - Run `flutter test` and `cargo test --workspace`.
