# Plan: Session Tab Scroll State Cache and Delta Merge

## Thinking

When switching between sessions/tabs or when restoring a session, users experience jarring scroll jumps:
1. When switching sessions, the terminal momentarily snaps to the top before jumping elsewhere or remaining stranded at the top.
2. When restoring a session (or refreshing after tab switch), the client completely clears the terminal content (`_sink.clear()` and ANSI erase sequences), blanks the screen, and re-emulates the entire history from scratch, causing the scroll position to land in an unexpected location.

Root cause analysis:

### 1. Jumpy Scroll and Snapping to Top on Tab Switch
- **Native (`terminal_pane_stub.dart`)**:
  - `SessionWorkspace` rebuilds whenever `_selectedSession` changes because `TerminalPane` has `key: ValueKey(session.title)`.
  - On every mount, `_scrollController` is instantiated fresh with the default `initialScrollOffset: 0.0`.
  - In frame 1 of layout and paint, `xt.TerminalView` renders scrolled to offset 0.0 (the top of the scrollback buffer).
  - Only after the frame (and in a 50ms timer) does `_scrollToCursor` run and call `jumpTo(saved)` or `jumpTo(maxScrollExtent)`.
  - This guarantees a visible, jarring flicker where content renders at line 0 (the top) before jumping to the target position.
- **Web (`terminal_pane_web.dart`)**:
  - When a tab is switched away or unmounted, the DOM container's `clientWidth`/`clientHeight` becomes 0 and the element's DOM `scrollTop` drops to 0.
  - xterm.js listens to viewport scroll and fires `onScroll(0)`.
  - In `terminal_pane_web.dart`, the `onScroll` callback records `viewportY` when `viewportY < baseY`. Because `viewportY` becomes 0 during DOM detachment, `_sessionSavedViewportY[sessionId]` is overwritten with 0 (line 0, the top of scrollback).
  - When switching back to the session, `_restoreScrollPosition` reads `savedY = 0` and invokes `scrollToLine(0)`, snapping the terminal to the top.

### 2. Clearing Content and Restoring from Scratch
- **`TerminalStore` (`terminal_store.dart`)**:
  - `HistoryBytes` always calls `_sink.clear()`, wiping out all existing buffer lines, scrollback, and carries.
  - When `restoreSession` is called for an exited session, or on initial fit, or during snapshot refreshes with `replayHistory: true`, the client re-runs `session.applyHistory(rawOutput)`.
  - This resets the emulator, drops carries, re-emulates all bytes from offset 0, and loses the active scroll position.
- **Web Background Disconnect (`terminal_pane_web.dart`)**:
  - When a tab is switched away, `dispose()` calls `_unbindController()`, removing `_onWrite` from `TerminalController`.
  - While backgrounded, any live chunks arriving from the daemon are written to `SessionVm.terminal` (unused on web) but are dropped from `_sessionTerms[sanitizedId]` (the xterm.js instance).
  - When switching back, `terminal_pane_web.dart` was forced to either do a full reset (`_resetTerminalSafe()` emitting `\x1b[2J\x1b[3J\x1b[H`) or suffer missing content.

### 3. Solution Architecture: Cache & Delta Merge
- **Delta-Merge in `TerminalStore`**:
  - Each snapshot contains `output_seq` (end sequence) and `raw_output_start` (start byte offset in the full output log).
  - `TerminalStore` already tracks `_appliedLiveSeq` (the highest sequence applied to the sink).
  - When `HistoryBytes` arrives with `rawOutputStart`:
    - If `appliedSeq >= throughOutputSeq`: the client already has all bytes. No-op: do not clear, do not rewrite.
    - If `rawOutputStart <= appliedSeq < throughOutputSeq`: calculate `deltaOffset = appliedSeq - rawOutputStart`. Slice only the newly arrived delta bytes (`bytes.sublist(deltaOffset)`) and append them via `_applyLive` without calling `_sink.clear()`.
    - If `appliedSeq < rawOutputStart` (buffer rollover) or store not live: clear and full replay.
  - This keeps the existing buffer intact, prevents screen flashing, and preserves the user's scroll position.
- **Native Initial Scroll Offset**:
  - In `terminal_pane_stub.dart`, initialize `ScrollController` with `initialScrollOffset: _sessionSavedScrollOffsets[widget.terminalId] ?? double.maxFinite`.
  - Flutter's `ScrollPosition` clamps `initialScrollOffset` to `maxScrollExtent` (if following the bottom) or the saved offset during the very first layout pass.
  - Frame 1 renders directly at the correct offset; it never renders at 0.0.
- **Web Detachment Guard and Background Delivery**:
  - In `terminal_pane_web.dart`, guard `onScroll` so detachment / hide artifacts (`scrollTop == 0` when unmounted or clientWidth <= 0) never overwrite `_sessionSavedViewportY`.
  - Maintain write delivery to cached `_sessionTerms[sanitizedId]` while switched away so background tabs stay updated in real time.
  - Remove destructive `_resetTerminalSafe()` calls during tab resume.
- **Tab Caching in UI**:
  - Maintain cached session views so tab switching preserves widget state and avoids clearing or rebuilding from scratch.

## Plan

1. **TerminalIntent & TerminalStore Delta Merge**
   - Update `flutter/triage_client/lib/terminal/terminal_intent.dart`:
     - Add optional `rawOutputStart` parameter to `HistoryBytes`.
   - Update `flutter/triage_client/lib/terminal/terminal_store.dart`:
     - In `_reduceHistory`, detect when `s.phase == AttachPhase.live` and `s.scrollbackReady` with known sequence numbers.
     - If `appliedSeq >= throughOutputSeq`: return `s` without clearing.
     - If `rawOutputStart != null && appliedSeq >= rawOutputStart && appliedSeq < throughOutputSeq`: slice `bytes.sublist(appliedSeq - rawOutputStart)` and apply as live bytes, updating `historyHighWaterSeq`.
     - Otherwise: execute standard `_sink.clear()` and full replay.
   - Update `SessionVm.applyHistory` in `flutter/triage_client/lib/main.dart`:
     - Accept optional `rawOutputStart`.
     - Extract `raw_output_start` from daemon snapshots in `_applySnapshotToSession` and pass it to `session.applyHistory`.
     - Avoid dispatching `Attach()` if the session is already live so live state is not prematurely set to `awaitingHistory`.

2. **Native Scroll Preservation (`terminal_pane_stub.dart`)**
   - Initialize `_scrollController` in `_TerminalPaneState` with `initialScrollOffset: _sessionSavedScrollOffsets[widget.terminalId] ?? double.maxFinite`.
   - Ensure `_saveScrollOffset` saves accurate offsets and only updates when clients are attached and valid.
   - Synchronize or preserve scroll anchors on `SessionVm` so background output trims do not drift viewports across tab switches.

3. **Web Scroll Preservation & Background Writes (`terminal_pane_web.dart`)**
   - In `_bindTerminalSubscriptions`:
     - Guard `onScroll` callback: ignore scroll changes if `_container.isConnected != true`, `_terminalWrapper.clientWidth <= 0`, or the pane is not the active event owner.
   - In `_unbindContainerEvents` / `dispose`:
     - Snapshot the active `viewportY` before unbinding.
   - In `_unbindController` / `_bindController`:
     - Keep background write subscription active for `_sessionTerms[sanitizedId]` so live bytes received while tab is backgrounded are written into the xterm.js instance.
   - In `didUpdateWidget` / remount:
     - Remove calls to `_resetTerminalSafe()` and `_triggerFullReplayOrReset()` on already-cached sessions.
     - Restore scroll position cleanly using the preserved `_sessionSavedViewportY` without jumping to line 0.

4. **Session Tab Switching Workflow (`main.dart`)**
   - In `_selectSession` and `_refreshSessionSnapshot`:
     - When switching between tabs or restoring an exited session, leverage delta merge so content is never cleared or replayed from scratch.
     - Coordinate view fit and refit so grid sizes are re-asserted without resetting scroll.

5. **Validation and Verification**
   - Add unit tests in `flutter/triage_client/test/terminal/terminal_store_test.dart` verifying:
     - Delta merge when snapshot overlaps with existing applied sequence (no `_sink.clear()`).
     - No-op when snapshot sequence is already covered.
     - Full replay fallback when sequence has a gap or buffer rolled over.
   - Run `cargo test --workspace` to ensure daemon and protocol compatibility.
   - Run `flutter test` across all client test suites.
   - Verify zero em dashes and formatting compliance across all modified files.

## Critical Review & Plan Revisions

### Critical Findings
1. **Unit Mismatch: `output_seq` vs `raw_output_start`**:
   - In the initial plan, delta slicing proposed `deltaOffset = appliedSeq - rawOutputStart`.
   - Detailed audit of `crates/triaged/src/session.rs` reveals that `output_seq` is a per-chunk monotonic counter (`output_seq += 1` per write), whereas `raw_output_start` and `bytes_logged` are cumulative byte offsets!
   - Subtracting a chunk sequence number (e.g. 42) from a byte offset (e.g. 50,000) would calculate a negative or invalid offset.
   - **Revision**: `TerminalStore` must track `_appliedLogBytes` (the cumulative byte offset in the full output log). When initial history is loaded, `_appliedLogBytes = (rawOutputStart ?? 0) + bytes.length`. For each live chunk, `_appliedLogBytes += bytes.length`. Delta slicing is then accurately computed as `_appliedLogBytes - rawOutputStart` against `bytes_logged`.

2. **Flutter `ScrollController` Finite Assertion**:
   - Flutter's `ScrollController` constructor asserts `initialScrollOffset.isFinite`. Passing `double.infinity` causes a fatal assertion failure in debug mode.
   - **Revision**: Use a finite sentinel offset `_kBottomScrollSentinel = 1e9` (1 billion pixels) when following the bottom. Flutter's `ScrollPosition.applyContentDimensions` clamps `1e9` cleanly to `maxScrollExtent` during the first layout pass, eliminating the frame-0 top flicker without asserting.

3. **Premature `store.dispatch(const Attach())` Reset**:
   - `SessionVm.applyHistory` previously dispatched `const Attach()` unconditionally before replaying history. `Attach` sets `phase = AttachPhase.awaitingHistory`, clears `_pendingLive`, and resets carries.
   - **Revision**: In `SessionVm.applyHistory`, if `store.state.phase == AttachPhase.live`, bypass `dispatch(const Attach())` and directly dispatch `HistoryBytes(..., rawOutputStart: ...)`. This preserves the live streaming carries and allows `TerminalStore` to perform the non-destructive delta merge.

4. **Web DOM Detachment Artifact Filter**:
   - When `TerminalPane` on Web is hidden or unmounted, the browser resets DOM `scrollTop` to 0, which fires an xterm.js `onScroll` event and corrupts `_sessionSavedViewportY` to line 0.
   - **Revision**: In `onScrollCallback`, verify `_container.isConnected == true` and `_terminalWrapper.clientWidth > 0` before updating `_sessionSavedViewportY`. Snapshot the viewport line prior to unbinding and freeze it during detachment.

5. **Web Background Write Delivery**:
   - When `TerminalPane` was disposed on tab switch, removing `_onWrite` from `TerminalController` starved `_sessionTerms[sanitizedId]` of live background writes.
   - **Revision**: Persist write delivery to the cached xterm.js instance for the full lifetime of the session. Clean up only when `TerminalPane.destroySession(sessionId)` is called on session deletion.
