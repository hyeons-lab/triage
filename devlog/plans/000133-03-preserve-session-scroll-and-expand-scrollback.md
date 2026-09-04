# Plan: Preserve Session Scroll Position and Expand Scrollback History

## Thinking

Users switching between sessions in the Triage client experience erratic scroll jumps:
1. When switching to another session and back, the scroll position either snaps to the bottom (even if scrolled up to read past output) or briefly starts at the top (line 0) before snapping down.
2. The scrollback history is too short to inspect past logs or compilation errors.

### Root Causes

1. **Short history scrollback limits**:
   - In `crates/triaged/src/session.rs`, `RAW_OUTPUT_TAIL_CAP` is hardcoded to 1 MiB (1,048,576 bytes). While on-disk session logs hold 12 MiB to 16 MiB (`MAX_SESSION_LOG_BYTES`), snapshot generation only reads the trailing 1 MiB.
   - In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`, `_initTerminal` does not specify `scrollback` in the xterm.js options, defaulting to xterm.js's built-in limit of 1,000 lines.
   - In `flutter/triage_client/lib/main.dart`, `SessionVm.terminal` defaults to 10,000 lines.

2. **Terminal wiped on session switch**:
   - In `flutter/triage_client/lib/main.dart`, `_selectSession` unconditionally invokes `_refreshSessionSnapshot(session, includeHistory: true)` on every session re-selection.
   - That triggers `_applySnapshotToSession`, which invokes `session.applyHistory(...)`.
   - `applyHistory` dispatches `HistoryBytes`, which calls `_sink.clear()`, wiping the client terminal emulator buffer and re-emulating the trailing 1 MiB. This destroys in-memory scrollback accumulated from live streaming and resets the scroll position.

3. **Unconditional jump to bottom on focus/replay**:
   - When switching sessions, `_selectSession` increments `focusCursorRevision`.
   - In `terminal_pane_web.dart` and `terminal_pane_stub.dart`, a `focusCursorRevision` change triggers `_scrollToCursor(requestFocus: true)`, which unconditionally executes `scrollToBottom`.
   - Scroll offsets are not saved or tracked per-session.
   - Because `applyHistory` clears the buffer asynchronously, the viewport momentarily sits at line 0 (the top) while empty before timers or post-replay callbacks fire to scroll to the bottom.

### Solution

1. **Expand History and Scrollback Capacity**:
   - In `crates/triaged/src/session.rs`, increase `RAW_OUTPUT_TAIL_CAP` to 4 MiB (`4 * 1024 * 1024`) so clients can receive up to 50,000 lines of scrollback history while keeping snapshot serialization safely within WebSocket frame limits.
   - In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`, configure `options.scrollback = 50000;`.
   - In `flutter/triage_client/lib/main.dart`, increase `SessionVm.terminal` `maxLines` to `50000`.

2. **Avoid Wiping Terminal on Switching Live Sessions**:
   - In `flutter/triage_client/lib/main.dart`, when re-selecting an already-loaded, already-fitted session that is currently live (`session.store.state.phase == AttachPhase.live`), refresh session metadata without clearing and replaying history (`forceHistoryReplay: false`).

3. **Track and Restore Per-Session Scroll Position**:
   - In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
     - Listen to `_term.onScroll` and record the scroll position (`_sessionSavedViewportY[sessionId]`).
     - If the user is at the bottom (`viewportY >= baseY`), treat it as pinned to bottom (`null`).
     - If scrolled up, save the `viewportY` line number.
     - When switching to a cached session or refocusing, restore `scrollToLine(savedY)` if scrolled up; only call `scrollToBottom` if following the bottom.
     - When the user sends keyboard input, clear the saved scroll position and scroll to bottom so the prompt is visible.
   - In `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
     - Save and restore scroll position on session switch.
     - If scrolled up, restore the saved scroll offset instead of unconditionally jumping to `maxScrollExtent`.

## Plan

1. **Update Daemon History Cap**:
   - In `crates/triaged/src/session.rs`, set `RAW_OUTPUT_TAIL_CAP = 4 * 1024 * 1024`.

2. **Update Web and Stub Terminal Limits**:
   - In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`, set `scrollback: 50000` in xterm options.
   - In `flutter/triage_client/lib/main.dart`, set `maxLines: 50000` on `SessionVm.terminal`.

3. **Implement Scroll Position Preservation**:
   - In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`, subscribe to `onScroll`, maintain per-session scroll state, and restore previous scroll line upon switching back.
   - In `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`, maintain per-session scroll offset and restore it when switching sessions.
   - In `flutter/triage_client/lib/main.dart`, update `_applySnapshotToSession` to avoid calling `applyHistory` when the session is already live unless history replay was explicitly forced.

4. **Testing and Validation**:
   - Run `flutter analyze` and `flutter test`.
   - Run workspace verification: `cargo check --workspace`, `cargo test --workspace`, `cargo clippy`.
   - Verify that switching sessions retains scroll positions and does not reset to top or snap to bottom when scrolled up.
