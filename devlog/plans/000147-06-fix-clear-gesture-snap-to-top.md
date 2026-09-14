# Fix Clear Gesture Collision and Snap to Top During Session Loading

## Thinking

The user observed that when scrolling before or while a session is loading:
1. It still shows the old content from the previous session state.
2. If they scroll with their finger down while it is loading, the terminal buffer clears underneath their touch.
3. Clearing the buffer while the finger is down collapses the scroll extent to 0, which snaps the viewport to the top.
4. The fresh history content renders during or after the clear, but the viewport remains stuck at line 0 (top of scrollback) instead of following content to the bottom.

Detailed Root Cause Analysis:

1. Stale Content Display During Loading:
   - In `terminal_pane_web.dart`, DOM elements and xterm.js instances are cached in `_sessionContainers[sanitizedId]` and `_sessionTerms[sanitizedId]`.
   - On reconnect (e.g. after daemon reload or client reconnect), `loadingSessionTitles` preserves `_sessionContainers` so the pane does not flash black.
   - However, while `_loadDaemonSessionInto` or `_refreshSessionSnapshot` fetches history from the daemon over WebSocket, the session is in `status == 'loading'` (`!session.loaded`).
   - The pane displays the stale text from before the reload at full opacity and accepts touch interactions.
   - The user sees text, touches the screen, and begins scrolling before the fresh history arrives.

2. Buffer Clear Under Active Touch:
   - When history arrives from the daemon, `SessionVm.applyHistory` dispatches `HistoryBytes`.
   - In `terminal_store.dart`, `_reduceHistory` issues `_sink.clear()`.
   - On Web, `onClear()` invokes `term.clear()` and wipes display lines with `\x1b[?1049l\x1b[H\x1b[2J\x1b[3J`.
   - On Native, `terminalController.addClearListener` in `main.dart` wipes `terminal.mainBuffer.clear()`.
   - Clearing the buffer reduces the line count to 0 or 1.
   - In both DOM xterm.js and Flutter `ScrollPosition`, the scroll extent immediately collapses to 0.0 (`scrollTop = 0`).

3. Active Gesture Overriding Programmatic Scroll to Bottom:
   - In mobile browsers (iOS Safari, Android Chrome), when a touch gesture is in flight on an element (`touchstart` active, finger resting or moving), browser touch controllers ignore or override programmatic JavaScript `element.scrollTop = ...` assignments.
   - In `terminal_pane_web.dart`, `_afterReplayContentWritten` triggers `_restoreScrollPosition`, calling `_term.scrollToBottom()`.
   - Because the user's finger is down, the browser's touch controller drops or overrides the scroll assignment, leaving `scrollTop` locked at 0.
   - When the user lifts their finger (`touchend`), no subsequent scroll-to-bottom is executed, leaving the user stranded at line 0.
   - On Native (`terminal_pane_stub.dart`), `TerminalPane` never listened to `addHistoryReplayedListener` at all, so once `mainBuffer.clear()` clamped `pixels` to 0.0, the native viewport also stayed at 0.0.

Remediation Strategy:

1. Visual and Interaction Guard for Loading Sessions:
   - Pass `isLoading: session.status == 'loading' || !session.loaded` to `TerminalPane`.
   - In `terminal_pane_web.dart`:
     - When `widget.isLoading` is true, set `_container.style.pointerEvents = 'none'` and wrap the platform view in `IgnorePointer(ignoring: true)` and `AnimatedOpacity(opacity: 0.7)`.
     - Render a subtle indeterminate linear progress bar at the top of the pane during loading.
     - When `isLoading` transitions from true to false, restore `pointerEvents = 'auto'` and invoke `_restoreScrollPosition(requestFocus: false)`.
   - In `terminal_pane_stub.dart`:
     - Wrap terminal view in `IgnorePointer(ignoring: widget.isLoading)` and `AnimatedOpacity(opacity: widget.isLoading ? 0.7 : 1.0)`.
     - Render the matching progress indicator during loading.

2. Web Active Gesture Tracking and Deferred Scroll-to-Bottom:
   - In `terminal_pane_web.dart`:
     - Track active touch and pointer counts: `_activeTouchCount` and `_activePointerCount`.
     - Listen to `onTouchStart`, `onTouchEnd`, `onTouchCancel`, `pointerdown`, `pointerup`, and `pointercancel` on `_container`.
     - When `onClear()` runs, flag `_pendingScrollToBottomOnRelease = true` and call `_suppressScrollSaveFor(Duration(milliseconds: 1500))`.
     - In `_restoreScrollPosition()`, if a user gesture is active, record `_pendingScrollToBottomOnRelease = true`.
     - When the gesture ends (finger lifted, `_activeTouchCount == 0 && _activePointerCount == 0`), if `_pendingScrollToBottomOnRelease` is true, clear the flag and invoke `_restoreScrollPosition(requestFocus: false)` with staggered retry timers (80ms, 250ms) to ensure momentum deceleration lands at the bottom.

3. Native History Replay and Clear Scroll Protection:
   - In `terminal_pane_stub.dart`:
     - Bind `widget.controller.addClearListener(_onClear)` and `widget.controller.addHistoryReplayedListener(_onHistoryReplayed)`.
     - In `_onClear()`, call `_suppressScrollSaveFor(Duration(milliseconds: 1500))` and mark `_pendingBottomSnapOnPointerUp = true`.
     - In `_onHistoryReplayed()`, if a gesture is active (`_activePointers.isNotEmpty` or `position.isScrollingNotifier.value`), flag `_pendingBottomSnapOnPointerUp = true`. If idle, immediately invoke `_scrollToCursor(requestFocus: false, forceBottom: true)`.
     - In `_handlePointerUp` and `_handlePointerCancel`, when `_activePointers.isEmpty` and `_pendingBottomSnapOnPointerUp` is true, clear the flag and invoke `_scrollToCursor(requestFocus: false, forceBottom: true)` with staggered retries.

4. Validation:
   - Add unit/widget tests in `flutter/triage_client/test/widget_test.dart` verifying:
     - `TerminalPane` correctly accepts `isLoading` and renders `IgnorePointer` and loading indicator.
     - Buffer clear during active pointer gesture retains bottom snap intent and scrolls to bottom upon pointer release.
     - Stale content scroll interaction is blocked while a session is loading.
   - Verify all existing Flutter tests and Cargo tests pass.

## Plan

1. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Add `isLoading` property to `TerminalPane` (default `false`).
   - Add `_activeTouchCount`, `_activePointerCount`, and `_pendingScrollToBottomOnRelease`.
   - In `_bindContainerEvents()`, subscribe to touch and pointer start/end/cancel events.
   - Implement `_handleUserGestureEnded()` to execute deferred bottom scroll and handle momentum settling.
   - In `onClear()`, set `_pendingScrollToBottomOnRelease = true` and suppress scroll save for 1500ms.
   - In `_restoreScrollPosition()`, flag `_pendingScrollToBottomOnRelease = true` if a gesture is active.
   - In `_syncPointerEvents()`, set `pointerEvents = 'none'` when `widget.isLoading` is true.
   - In `build()`, wrap in `IgnorePointer(ignoring: widget.isLoading)`, `AnimatedOpacity`, and render top loading indicator when `isLoading` is true.
   - In `didUpdateWidget()`, handle `isLoading` transitions.

2. In `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
   - Add `isLoading` property to `TerminalPane` (default `false`).
   - Add `_pendingBottomSnapOnPointerUp`.
   - Bind `addClearListener(_onClear)` and `addHistoryReplayedListener(_onHistoryReplayed)`.
   - Implement `_onClear()` and `_onHistoryReplayed()`.
   - In `_handlePointerUp` and `_handlePointerCancel`, trigger deferred bottom scroll when `_activePointers.isEmpty`.
   - In `build()`, wrap in `IgnorePointer(ignoring: widget.isLoading)`, `AnimatedOpacity`, and render matching top loading indicator.

3. In `flutter/triage_client/lib/main.dart`:
   - Pass `isLoading: session.status == 'loading' || !session.loaded` to `TerminalPane` in `WorkspaceView.build`.

4. Test Verification:
   - Add widget test cases verifying `isLoading` blocks touch interaction and clear-during-scroll snaps to bottom upon release.
   - Run `flutter test` across all 480+ tests.
   - Run `cargo test --workspace`.
   - Run `cargo fmt --all -- --check` and `cargo clippy --all-targets --all-features -- -D warnings`.

5. Update devlog and push PR commit.
