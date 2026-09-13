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

## Thinking: Eliminating Duplicate Text Blocks on Session Resume

### Problem Root Causes
1. **Host PTY SIGWINCH Coalescing on Web Jiggle**:
   - `_refitAndSend` in `terminal_pane_web.dart` was calling `sendResizeOut(cols, rows - 1)` immediately followed by `sendResizeOut(cols, rows)` synchronously in the same microtask.
   - Both WebSocket frames were sent back-to-back, causing `triaged` to execute `ioctl(TIOCSWINSZ)` for `rows - 1` and `rows` within nanoseconds.
   - Under POSIX, pending `SIGWINCH` signals are coalesced by the OS kernel. When Node.js (running interactive CLIs like Codex / Ink) processed the signal, `ioctl(TIOCGWINSZ)` was called. Because `rows` had already returned to its original value, Node.js (`lib/internal/tty.js`) checked `this.columns === oldCols && this.rows === oldRows` and suppressed the `resize` event.
   - Consequently, Codex never received a resize event, its DECSTBM scrolling regions and line-wrapping calculations remained out of sync, and relative cursor up (`\x1b[NA`) overwrote earlier lines, leaving duplicate blocks of text on every update.
   - Staggering the restoration of `rows` by 60ms guarantees that the kernel delivers two distinct `SIGWINCH` signals, allowing Node.js to fire its resize event and force Ink to repaint cleanly.

2. **Cached Container Adoption Omitted Refit Jiggle**:
   - In `terminal_pane_web.dart`, `initState` adopting a cached container only called `_triggerFitWithDelayedRetries()`.
   - `_triggerFitWithDelayedRetries` invokes `_onFit()`, which only sends a single resize when dimensions change, and never performs a jiggle. If the dimensions matched what was previously fitted, nothing was sent to the host.
   - Adopting a cached container must invoke `_onRefit()` so the full refit, refresh, and staggered jiggle sequence runs as the container is re-attached to the DOM.

3. **Premature `_lastRefitCols` Latching on Zero-Width DOM Layout**:
   - When `_refitAndSend(force: true)` ran on the first frame of session resume, `_terminalWrapper.clientWidth` was often 0 because the browser had not yet performed DOM layout for the platform view.
   - `_onFit()` skipped the fit, but `_refitAndSend` proceeded to latch `_lastRefitCols` and `_lastRefitRows`.
   - On subsequent delayed retries (50ms, 200ms, 600ms, 1500ms), `force` was false, and because `cols == _lastRefitCols`, all retries returned early without sending the refit jiggle once the element had layout dimensions.
   - Latching `_lastRefitCols` and `_lastRefitRows` must only occur when `clientWidth > 0 && clientHeight > 0`.

4. **`onClear` in Web Did Not Clear the Active Screen Buffer**:
   - In `terminal_pane_web.dart`, `onClear` only called `term.clear()`.
   - In xterm.js, `term.clear()` only clears the scrollback lines above the viewport; it leaves the active screen rows and cursor position unchanged.
   - When a full history replay occurred, replaying bytes over uncleared active rows resulted in duplicate blocks of text.
   - Writing `\x1b[H\x1b[2J\x1b[3J` in `onClear` ensures the active screen is cleared and the cursor is returned to home before replaying history.

5. **Reconnect and Initial Connect Web Refit**:
   - In `main.dart`, after `_loadDaemonSessions()` in `_connectWebSocket` completes (e.g. after reconnect or app start), `_refitActiveSession()` was not scheduled on web.
   - On web, switching or connecting to sessions requires post-frame refitting because xterm.js DOM elements only compute accurate layout dimensions after Flutter finishes layout and attachment.

## Plan: Staggered PTY Jiggle, Container Adoption Refit, and True Screen Clear

1. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - In `_refitAndSend`:
     - Only latch `_lastRefitCols` and `_lastRefitRows` when `_terminalWrapper.clientWidth > 0 && _terminalWrapper.clientHeight > 0`.
     - Stagger `sendResizeOut(targetId, cols, rows)` 60ms after `sendResizeOut(targetId, cols, rows - 1)` so the host kernel delivers distinct `SIGWINCH` events to Node.js/Ink.
     - When `!wasAtBottom`, restore scroll offset via `scrollToLine` to prevent viewport jumps.
   - In `initState`:
     - Call `_onRefit()` instead of `_triggerFitWithDelayedRetries()` when adopting a cached container.
   - In `onClear`:
     - Write `\x1b[H\x1b[2J\x1b[3J` to `term` alongside `term.clear()` to completely erase active screen rows and home the cursor.

2. In `flutter/triage_client/lib/main.dart`:
   - In `_connectWebSocket`:
     - Schedule `_refitActiveSession()` post-frame on web after `_loadDaemonSessions()` completes.

3. Verify:
   - Run `flutter analyze`, `flutter test`, and `cargo test --workspace`.
   - Verify zero em dashes across all touched files.
