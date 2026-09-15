# Plan: Fix Composer Upward Scroll Freezing and Refit Snap to Top

## Thinking

### Problem Analysis
The user reported two closely related symptoms on macOS desktop (and observable across platforms):
1. "the session still snaps to the top when I refit"
2. "I still have an issue where I try to scroll up when I see the input composer. it doesn't respond. then I see it snapped to the top and it starts responding to scroll. I have to press the down arrow key to go back to the input composer"

### Root Cause Diagnosis
1. **Gesture Freezing on Upward Scroll**:
   - In `_repinScrollAnchor()` (`terminal_pane_stub.dart`), whenever background terminal writes or cursor blinks occur (which happens multiple times a second in interactive CLIs like Antigravity CLI and Codex), a post-frame callback called `position.jumpTo(desired)`.
   - `position.jumpTo(desired)` calls `goIdle()` on Flutter's active `ScrollActivity`, unconditionally terminating the user's active trackpad/mouse scroll gesture mid-flight. The user experiences this as the viewport resisting or freezing ("it doesn't respond").
   - Furthermore, in web `terminal_pane_web.dart` line 1137, `onScrollCallback` executed `if (viewportY < baseY) { js_util.callMethod(term, 'scrollToBottom', []); }` whenever `_viewportIsAtBottom` evaluated to true, counter-scrolling back to bottom during the user's upward scroll attempt.
2. **Snap to Top (0.0 Offset)**:
   - In `TerminalScrollAnchor.desiredOffset()` (`terminal_scroll_anchor.dart`), when `line.index <= 0` or when `desired` evaluated to `<= 0.0`, it returned `0.0` rather than `null`. In `BufferLine`, line indices decrease as lines scroll up through vertical margins or buffer operations, eventually reaching 0. Returning `0.0` caused `position.jumpTo(0.0)` in `_repinScrollAnchor`, `_scrollToCursor`, and `_onTerminalResize`, jumping the viewport to line 0 at the very top of the scrollback.
   - In `_scrollAnchor.capture(...)`, capturing was permitted when `pixels <= 0.0`, which indexed `buffer.lines[0]` and latched the anchor to line 0.
   - In `_scrollToCursor()` (`terminal_pane_stub.dart`), when `wasScrolledUp` was true, any fallback to `saved == 0.0`, `savedFraction == 0.0`, or `savedDistance == maxScrollExtent` evaluated `target` to `0.0`, jumping directly to the top.
   - In `didUpdateWidget()`, when `oldWidget.focusCursorRevision != widget.focusCursorRevision`, it called `_scrollToCursor(requestFocus: true)` with the default `forceBottom: false`, which cancelled the `forceBottom: true` timer scheduled by `_onRefit()` and fell back to `target = 0.0` whenever a stale saved map entry was present.
   - In `_onTerminalResize()`, it checked whether static saved maps contained `widget.terminalId` rather than evaluating live scroll metrics, and jumped to `target` (evaluating to `0.0`).

### Remediation Plan
1. **Prevent Gesture Interruption in `_repinScrollAnchor`**:
   - In `_repinScrollAnchor()` (`terminal_pane_stub.dart`), immediately return if `position.isScrollingNotifier.value` is true. Never interrupt an active user scroll gesture.
   - Return early if `desired == null || desired <= 0.0`. Never jump to 0.0 during re-pinning.
2. **Harden `TerminalScrollAnchor`**:
   - In `capture()` (`terminal_scroll_anchor.dart`), do not capture an anchor if `pixels <= 0.0` or if `topRow <= 0`.
   - In `desiredOffset()`, if `line.index <= 0` or `desired <= 0.0`, clear `_line` and return `null`. A scroll anchor must represent a non-zero scrollback offset.
3. **Harden `_scrollToCursor` and `didUpdateWidget`**:
   - In `didUpdateWidget()`, evaluate `isAtBottom` from current scroll metrics and pass `forceBottom: isAtBottom` to `_scrollToCursor()`.
   - In `_scrollToCursor()`, ensure `target` falls back to `position.maxScrollExtent` rather than `0.0` if saved metrics are degenerate or non-positive.
4. **Harden `_onTerminalResize` and `_saveScrollOffset`**:
   - In `_onTerminalResize()`, evaluate `isAtBottom` directly from `pos.pixels` and `pos.maxScrollExtent`. If at the bottom, clear saved maps and call `_snapToBottom(pos)`. If scrolled up, only restore `target` if `target > 0.0`.
   - In `_saveScrollOffset()`, when `position.pixels <= 0.0`, clear all saved maps and clear `_scrollAnchor`.
5. **Clean Up Web Pane Counter-Scrolling**:
   - In `terminal_pane_web.dart`, remove the harmful `scrollToBottom` invocation inside `onScrollCallback`.
   - In `_scrollToCursor`, ensure `effectiveSavedY > 0` before calling `scrollToLine`, otherwise falling back to `scrollToBottom`.
6. **Validation**:
   - Run unit and widget tests: `flutter test`.
   - Rebuild macOS release app: `flutter build macos --release`.
   - Test in the running app with Antigravity CLI to verify upward scrolling from the composer and refit button behavior.

## Plan
1. Update `flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart` to guard `capture` and `desiredOffset` against zero/degenerate offsets.
2. Update `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` to guard `_repinScrollAnchor` against active scrolling, pass `forceBottom` on focus revision in `didUpdateWidget`, prevent degenerate zero targets in `_scrollToCursor`, and clean up `_onTerminalResize` and `_saveScrollOffset`.
3. Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to remove the upward scroll counter-bottom trigger in `onScrollCallback` and guard `_scrollToCursor`.
4. Update unit tests in `flutter/triage_client/test/terminal/terminal_scroll_anchor_test.dart` and `flutter/triage_client/test/widget_test.dart`.
5. Verify tests and lints pass (`flutter test`, `cargo test`, `flutter analyze`).
6. Build and test macOS release application.
7. Update devlog.
