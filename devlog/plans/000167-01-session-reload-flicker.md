# 000167-01: Eliminate Session Reload Flicker and Top-to-Bottom Scroll Jumps

## Thinking

Even with lazy history loading and delta snapshot merges in place, users still experience repeated session reloads and visible top-to-bottom scrolling animations on session switch, input, and refresh. Tracing the Flutter client (`main.dart`, `terminal_pane_web.dart`, and `terminal_pane_stub.dart`) reveals four compounding causes:

1. **Unconditional `rows - 1` -> `rows` PTY jiggle on web session switch and connect**:
   In `main.dart`, `_selectSession` (lines 5263-5273) and `_connectWebSocket` (lines 2805-2814) schedule a post-frame callback that calls `_refitActiveSession()` unconditionally on web, even when neither `session.hostSizeDriftedFromOwnFit` nor `_selectedSessionGridDriftedFromHost()` is true. `_refitActiveSession()` calls `session.terminalController.refit()`, which in `terminal_pane_web.dart` (`_onRefit` -> `_refitAndSend(force: true)`) sends `resizeSession(cols, rows - 1)` followed 60ms later by `resizeSession(cols, rows)`. That delivers two `SIGWINCH` signals to the PTY on every session switch, forcing full-screen TUIs (Claude Code, Gemini CLI, Muse, vim, htop) to clear and redraw from top to bottom.

2. **DOM re-insertion `scrollTop = 0` poisoning `_sessionSavedViewportY` on web session switch**:
   In `terminal_pane_web.dart`, when switching away from a session and switching back, the cached `_container` (`HtmlElementView`) is removed from and re-inserted into the DOM. Browsers reset `.xterm-viewport.scrollTop` to `0` on DOM re-insertion. Because `initState` did not arm `_suppressScrollSaveFor` before remounting and `_onFit()` queried `_viewportIsAtBottom(_container, viewportY, baseY)` directly instead of checking `_sessionSavedViewportY.containsKey(_sanitizedId)`, `_onFit()` saw the transient `scrollTop == 0` (`viewportY == 0`), treated the session as scrolled up, saved `_sessionSavedViewportY[_sanitizedId] = 0`, and called `term.scrollToLine(0)`. When the user next typed or refreshed, `onData` called `scrollToBottom()`, visibly scrolling from the top of the buffer to the bottom.

3. **Unbatched multi-frame `term.write` and visible clear during full and paged history replays**:
   When `TerminalStore` executes a full replay (`_sink.clear()` -> `_writeDecoded(replayBytes)` -> `_sink.onHistoryReplayed()`), historical output containing Mode 2026 synchronized blocks triggers hundreds of separate `onWrite` calls. In `terminal_pane_web.dart`, `onClear()` immediately cleared the visible terminal (`viewportY = 0`) and each `onWrite` invoked `term.write(data)` separately while `_terminalWrapper` remained visible (`opacity: 1`). xterm.js parsed those queued writes across multiple animation frames before `_restoreScrollPosition` or `_restorePagedScrollPosition`'s 50ms polling timer restored the scroll offset. Similarly, on native (`terminal_pane_stub.dart`), `_scrollToCursor` only scheduled `jump()` in `addPostFrameCallback` (after `flushPaint`) rather than jumping synchronously when content dimensions are already available. And on web, `SessionVm` also attached `package:xterm` write/clear/resize listeners (`terminal.write`, `terminal.resize` with 50,000-line reflow) on the main thread despite `session.terminal` never being rendered on web.

4. **Redundant `attachSession` RPC in `_selectSession` and unconditional `setState` in `_applySnapshotToSession`**:
   In `main.dart`, when selecting an already-fitted subscribed session, `_selectSession` issues a standalone `attachSession(mode: 'Observer', historyBytes: kHistoryLeaseProbeBytes)` lease probe and immediately calls `_refreshSessionSnapshot(session, includeHistory: false)`, which issues a second identical `attachSession` RPC. When that metadata refresh returns ~50ms later, `_applySnapshotToSession` unconditionally runs `setState(() { ... })` even when no UI-visible field changed, triggering a second full `TriageHomePage` widget rebuild after every session switch.

## Plan

1. **Gate automatic web post-frame refit on actual size drift (`main.dart`)**:
   - Extract or use a helper (`_fitOrReclaimActiveSessionOnWeb()`) in `_selectSession` and `_connectWebSocket` post-frame callbacks: if `_selectedSession.hostSizeDriftedFromOwnFit || _selectedSessionGridDriftedFromHost()` is true, call `_refitActiveSession()` to jiggle and reclaim the PTY; otherwise call `_selectedSession.terminalController.fit()` so `FitAddon.fit()` runs locally without sending a `rows - 1` -> `rows` jiggle.
   - Skip registering the unused `package:xterm` write/clear/resize listeners in `SessionVm` when `kIsWeb` is true.

2. **Collapse duplicate `attachSession` on select and skip no-op `setState` on metadata refresh (`main.dart`)**:
   - In `_selectSession`, only run the standalone `Observer` lease-probe `attachSession` when `!session.hasFitted`, since the `session.hasFitted && subscribed` branch immediately runs `_refreshSessionSnapshot(includeHistory: false)` which performs the same `Observer` attach and updates `session.hasInputLease` (including resetting `hasInputLease = false` on error).
   - In `_applySnapshotToSession`, update non-visual sizing fields directly and only invoke `setState` when a UI-visible field (`loaded`, `replayHistory`, `rows`, `cwd`, `bracketedPasteEnabled`, `isExited`, `status`, or `statusColor`) actually changes.

3. **Prevent DOM remount scroll-reset poisoning, coalesce writes, and hide replay transitions on web (`terminal_pane_web.dart`)**:
   - In `initState` when adopting a cached container, arm `_suppressScrollSaveFor(const Duration(milliseconds: 1000))` immediately and restore scroll position in the post-frame callback after DOM attachment.
   - In `_onFit()`, determine `wasAtBottom` from `!_sessionSavedViewportY.containsKey(_sanitizedId)` rather than reading a transient DOM `scrollTop` during remount or async writes, so `_onFit()` never poisons `_sessionSavedViewportY` with `0`.
   - Coalesce `onClear` and `onWrite` per session across the current microtask turn (and across synchronous `onClear` -> `onWrite` -> `_onHistoryReplayed` replay sequences) into a single `term.write` call.
   - During full and paged history replays on web, set `_terminalWrapper.style.opacity = '0'` (preserving DOM focus on `.xterm-helper-textarea`, with a safety timer backstop) before executing `term.clear()` and the single coalesced `term.write(payload, callback)`, and run scroll restoration (`scrollToLine` / `scrollToBottom` or paged anchor adjustment) plus `opacity = ''` synchronously inside the `term.write` completion callback.

4. **Snap scroll position synchronously before paint on native (`terminal_pane_stub.dart`)**:
   - In `_scrollToCursor`, execute the scroll jump synchronously (without synchronous focus mutation) when `syncJump` is true and `_scrollController` already has content dimensions, in addition to the post-frame and timer passes. Pass `syncJump: false` only when `widget.terminal` is swapped in `didUpdateWidget` before `RenderTerminal` has laid out the incoming terminal.

5. **Validation and tests**:
   - Add regression tests in `test/widget_test.dart` verifying that re-selecting an already-fitted subscribed session issues a single `attachSession` probe and does not emit extra rebuilds or `rows - 1` jiggles when size has not drifted.
   - Run `flutter analyze` and `flutter test`.
