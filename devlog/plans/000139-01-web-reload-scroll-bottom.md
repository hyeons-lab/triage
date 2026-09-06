# Implementation Plan: Web Terminal Reload Scroll to Bottom Fix

## Thinking

### Problem Analysis
When the Triage web client is loaded or reloaded in a browser (http://127.0.0.1:7777 or http://192.168.4.40:7777), the active terminal viewport fails to position at the bottom of the buffer (the live prompt / cursor). Users observe that the terminal viewport remains stuck at line 0 / top of the scrollback buffer, or fails to flush and position properly upon reload.

### Root Cause Identification
1. **Controller Swap in `didUpdateWidget` Suppresses Fitting and Replay**:
   - On web page reload, `_loadDaemonSessions()` populates `_sessions` with placeholder `SessionVm`s, and `TerminalPane` mounts.
   - The DOM layout settles within 250ms, firing `_finishInitialContent()` on the placeholder session. This marks `_initialContentWritten = true` on `_TerminalPaneState`.
   - When `_loadDaemonSessionInto` completes its asynchronous WebSocket attach and snapshot retrieval, it instantiates a replacement `SessionVm` with a fresh `TerminalController`.
   - `_sessions[0] = session` triggers a rebuild of `TerminalPane`. Because the session key (`ValueKey(session.title)`) is identical, Flutter reuses the existing `_TerminalPaneState` and calls `didUpdateWidget(oldWidget)`.
   - In `didUpdateWidget`, `oldWidget.controller != widget.controller` was guarded with `if (!_initialContentWritten) { _triggerFullReplayOrReset(); }`. Because `_initialContentWritten` is already true, this branch is skipped.
   - Consequently, `_writeInitialContent()` is never called for the new controller, `widget.onViewFit` is never triggered, `session.noteViewFit` is never called, and `session._pendingHistory` remains unflushed.
2. **Missing Post-Replay Scroll Restoration in Pipeline**:
   - Even when history is replayed, `TerminalStore._reduceHistory` writes decoded bytes into `_sink` asynchronously without signaling completion to the view.
   - Neither `TerminalSink`, `TerminalControllerSink`, nor `TerminalController` provide an event or callback when history replay has completed.
   - Consequently, `term.scrollToBottom()` is never executed after the full snapshot has been parsed into `xterm.js`.
3. **Premature and False Viewport Latching in `onScrollCallback`**:
   - In `terminal_pane_web.dart`, `onScrollCallback` listens to xterm.js `onScroll`.
   - During history replay, buffer clearance (`\x1b[2J\x1b[3J\x1b[H`), or asynchronous chunk parsing, `viewportY` can temporarily be 0 while `baseY > 0`.
   - The condition `else if (viewportY >= 0)` is met, latching `_sessionSavedViewportY[sessionId] = 0`.
   - Subsequent calls to `_restoreScrollPosition()` see `savedY == 0` and execute `term.scrollToLine(0)`, pinning the viewport to line 0 permanently.
4. **Replay Callback Settling in `xterm.js`**:
   - In xterm.js, `term.write(data, callback)` is asynchronous and executes its callback only when the write buffer has been fully parsed and applied to the active buffer.
   - Using `term.write('', callback)` or coordinating through a replay-complete signal ensures `baseY` has settled before `scrollToBottom()` or `scrollToLine()` is invoked.

### Solution Design
1. **Extend `TerminalSink`, `TerminalControllerSink`, and `TerminalController` with Replay Completion Signals**:
   - Add `void onHistoryReplayed()` to `TerminalSink` (with default no-op).
   - In `TerminalControllerSink`, implement `onHistoryReplayed()` by forwarding to `controller.notifyHistoryReplayed()`.
   - In `TerminalController`, maintain `_historyReplayedListeners` with `addHistoryReplayedListener` and `removeHistoryReplayedListener`.
   - In `TerminalStore._reduceHistory`, after `_writeDecoded(bytes)` and `_flushPendingLive`, call `_sink.onHistoryReplayed()`.
2. **Handle Controller Replacement in `terminal_pane_web.dart`**:
   - In `didUpdateWidget`, when `oldWidget.controller != widget.controller`, always invoke `_triggerFullReplayOrReset()`.
   - In `_triggerFullReplayOrReset()`, if `_initialContentWritten` is true, call `_resetTerminalSafe()`, `_writeInitialContent()`, and `_afterReplayContentWritten(initialReplay: true)` (ensuring `_focusCursorAfterReplay` or initial replay scroll executes).
3. **Guard `onScrollCallback` Against Programmatic Replay Artifacts**:
   - Add a `_suppressScrollSave` flag during history replay, clear, and programmatic scroll restoration.
   - In `onScrollCallback`, only store to `_sessionSavedViewportY` if `!_suppressScrollSave`.
   - Purge `_sessionSavedViewportY[sessionId]` on `onClear()`.
4. **Reliable Post-Replay Scroll to Bottom**:
   - In `_bindController()`, register a listener on `controller.addHistoryReplayedListener`.
   - When history replay finishes, wait for `term.write('', callback)` and microtask/post-frame to ensure xterm.js buffer layout has completed, then invoke `_restoreScrollPosition(requestFocus: true)`.
   - If `_sessionSavedViewportY` does not contain a saved offset (the reload / clean open case), execute `term.scrollToBottom()`.

---

## Plan

1. **Update Devlog**:
   - Create `devlog/000139-fix-web-reload-scroll-bottom.md` with required sections and real ISO 8601 timestamps.
2. **TerminalSink & TerminalController Enhancements**:
   - In `flutter/triage_client/lib/terminal/terminal_sink.dart`, add `void onHistoryReplayed() {}`.
   - In `flutter/triage_client/lib/widgets/terminal_pane.dart`, add `_historyReplayedListeners` and `notifyHistoryReplayed()` to `TerminalController`.
   - In `flutter/triage_client/lib/terminal/terminal_controller_sink.dart`, override `onHistoryReplayed()` to invoke `controller.notifyHistoryReplayed()`.
   - In `flutter/triage_client/lib/terminal/terminal_store.dart`, call `_sink.onHistoryReplayed()` at the end of `_reduceHistory()`.
3. **Web Terminal Pane Corrections (`flutter/triage_client/lib/widgets/terminal_pane_web.dart`)**:
   - Listen to `controller.addHistoryReplayedListener` in `_bindController()` (and unbind in `_unbindControllerFrom`).
   - Add `_suppressScrollSave` guard around history replay, clear, and scroll restoration.
   - When history replay finishes, settle via `term.write('', callback)` and execute `_restoreScrollPosition(requestFocus: true)`.
   - In `didUpdateWidget`, ensure `oldWidget.controller != widget.controller` always triggers full replay / reset even if `_initialContentWritten` is true.
   - In `_triggerFullReplayOrReset`, pass `initialReplay: true` so scroll position is restored to bottom.
4. **Verification**:
   - Run `cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo test --workspace`.
   - Run `flutter analyze` and `flutter test`.
   - Rebuild web release bundle: `flutter build web --release`.
   - Re-sign installed daemon and execute zero-downtime reload: `triaged reload`.
   - Test reload via Chrome CDP on port 9222 and verify `viewportY == baseY` and prompt lines are visible at the bottom of the viewport.
5. **PR and Documentation**:
   - Complete devlog with commit entries following HEAD rule.
   - Push with explicit refspec and open PR.
