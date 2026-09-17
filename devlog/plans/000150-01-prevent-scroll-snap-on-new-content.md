# Plan 000150-01: Prevent Terminal Scroll Snapping to Bottom on New Content

## Thinking

### Problem Statement
When viewing an active terminal session with new output streaming in (such as an agent running or logs printing), attempting to scroll up causes the viewport to snap immediately back to the bottom near the composer. The user cannot scroll up to read previous output while new content arrives.

### Root Cause Analysis

1. **Flawed Bottom Boundary Check in `TerminalScrollAnchor.capture` (`terminal_scroll_anchor.dart`)**:
   - In `terminal_scroll_anchor.dart`, `capture()` used:
     ```dart
     if (lineHeight <= 0 ||
         lineCount <= 0 ||
         pixels <= 0.0 ||
         pixels >= maxScrollExtent - kScrollPinReleaseGraceLines * lineHeight) {
       _line = null;
       return;
     }
     ```
     `kScrollPinReleaseGraceLines` is 3 lines (30 to 60 pixels).
     When a user is at the bottom and initiates an upward scroll, their position is initially within 3 lines of `maxScrollExtent`. Because of this 3-line grace threshold, `capture()` treats the viewport as still "at the bottom" and sets `_line = null`, refusing to capture an anchor.
   - The docstring for `kScrollPinReleaseGraceLines` notes:
     "How close to the bottom a downward scroll must land before the pin is released. Wider than the single line TerminalScrollAnchor.capture uses to decide it is already at the bottom..."
     The grace lines were intended solely for `shouldReleaseScrollPin` when scrolling *down* towards live output, preventing treadmill drift. For upward scrolling, any position above the bottom (`pixels < maxScrollExtent - 0.5`) is an intentional scroll away from bottom and must capture an anchor.

2. **Overly Wide Bottom Check in Native Pane Scroll Handlers (`terminal_pane_stub.dart`)**:
   - `_saveScrollOffset`, `_onFit`, `_onRefit`, `_onTerminalResize`, and `didUpdateWidget` all defined `isAtBottom` as:
     `position.pixels >= position.maxScrollExtent - kScrollPinReleaseGraceLines * lh`
   - In `_saveScrollOffset`, this cleared `_sessionSavedScrollOffsets`, `_sessionSavedScrollAnchors`, and called `_scrollAnchor.clear()`.
   - In `_scrollToCursor`, `isNearBottom` forced `target = position.maxScrollExtent` and cleared the anchor.
   - When new content arrived while within this 3-line zone, `_scrollAnchor.hasAnchor` was false, and layout snapped the viewport back to `maxScrollExtent`.

3. **In-Flight Scroll Re-Pin Dropping (`terminal_pane_stub.dart`)**:
   - `_repinScrollAnchor()` aborted when `position.isScrollingNotifier.value` was true or `_activePointers.isNotEmpty`, but did not re-schedule once scrolling or touch gestures settled.
   - When pointer events finish in `_handlePointerUp` and `_handlePointerCancel`, or when `isScrollingNotifier` flips to false, held anchors need to apply any pending re-pin.

4. **Web Viewport Snapping (`terminal_pane_web.dart`)**:
   - `_viewportIsAtBottom` returned true if `viewportY >= baseY - 1` or `remainingPixels <= 30`. Scrolling up 1 line or 25 pixels was classified as "at bottom", deleting `_sessionSavedViewportY[sessionId]`.
   - In `_restoreScrollPosition`, `if (_isUserGestureActive) _pendingScrollToBottomOnRelease = true;` unconditionally forced a bottom snap on pointer release even when the user was scrolled up.

## Plan

1. **Fix `terminal_scroll_anchor.dart`**:
   - In `TerminalScrollAnchor.capture()`, change the bottom boundary from `pixels >= maxScrollExtent - kScrollPinReleaseGraceLines * lineHeight` to `pixels >= maxScrollExtent - 0.5`.
   - Ensure `capture()` captures an anchor immediately whenever `pixels < maxScrollExtent - 0.5` and `pixels > 0.0`.
   - In `shouldReleaseScrollPin()`, retain the downward direction guard (`pixels > lastPixels`) and the 3-line grace release band for downward scrolling.

2. **Fix `terminal_pane_stub.dart`**:
   - In `_saveScrollOffset`, define `isAtBottom` as `position.pixels >= position.maxScrollExtent - 0.5`.
   - In `_onFit`, `_onRefit`, and `_onTerminalResize`, define `isAtBottom` as `pos.pixels >= pos.maxScrollExtent - 0.5`.
   - In `didUpdateWidget`, define `isAtBottom` on `focusCursorRevision` change as `pos.pixels >= pos.maxScrollExtent - 0.5`.
   - In `_scrollToCursor`, define `isNearBottom` as `position.pixels >= position.maxScrollExtent - 0.5`.
   - In `_handlePointerUp` and `_handlePointerCancel`, if `_activePointers.isEmpty` and `_scrollAnchor.hasAnchor`, call `_repinScrollAnchor()`.
   - Attach a listener to `_scrollController.position.isScrollingNotifier` to re-pin the anchor once an active scroll gesture settles.

3. **Fix `terminal_pane_web.dart`**:
   - In `_viewportIsAtBottom`, require `viewportY >= baseY` and `remainingPixels <= 2`. If `viewportY < baseY` or `remainingPixels > 2`, return `false`.
   - In `_restoreScrollPosition`, only set `_pendingScrollToBottomOnRelease = true` if `!_sessionSavedViewportY.containsKey(_sanitizedId)`. Do not force bottom snap if the user has a saved scrolled-up viewport position.

4. **Verify and Test**:
   - Update and add unit tests in `test/terminal/terminal_scroll_anchor_test.dart` asserting that capturing within the grace band (e.g. 1 or 2 lines above bottom) captures and holds the anchor.
   - Add widget tests in `test/widget_test.dart` verifying that scrolling up near the bottom does not snap back to the bottom when new output arrives.
   - Run `flutter test`, `cargo test --workspace`, and `flutter analyze` to ensure zero regressions.
