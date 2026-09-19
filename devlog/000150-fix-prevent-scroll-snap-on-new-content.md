# Devlog 000150: Prevent Terminal Scroll Snapping to Bottom on New Content

## Agent
Antigravity (gemini-2.5-pro) @ repository branch fix/prevent-scroll-snap-on-new-content

## Intent
Prevent the terminal viewport from snapping to the bottom (near the composer) when new streaming content arrives while the user is actively scrolling up or reading scrolled-up output.

## Decisions
- 2026-09-17T08:27-0400 Strict bottom check for scroll anchor capture: Use `pixels >= maxScrollExtent - 0.5` instead of `kScrollPinReleaseGraceLines * lineHeight` so that upward scrolling immediately captures an anchor and preserves reading position rather than falsely dropping the anchor within 3 lines of the bottom.
- 2026-09-17T08:27-0400 Maintain downward release grace: Keep the 3-line grace band in `shouldReleaseScrollPin` exclusively for downward scrolling (`pixels > lastPixels`) to prevent treadmill drift when intentionally chasing live output.
- 2026-09-17T08:27-0400 Precision bottom detection in web client: Update `_viewportIsAtBottom` in `terminal_pane_web.dart` to require `viewportY >= baseY` and `remainingPixels <= 2` instead of 30 pixels, avoiding premature bottom classification when scrolling up.
- 2026-09-17T08:27-0400 Guard pointer-release bottom snap on web: Only set `_pendingScrollToBottomOnRelease = true` if `!_sessionSavedViewportY.containsKey(_sanitizedId)` so active gestures while scrolled up do not force a bottom snap upon pointer release.
- 2026-09-17T09:22-0400 Widen web subpixel remaining distance threshold to 4px: Accommodate subpixel layout rounding on high-DPI (Retina) screens and browser zoom levels in terminal_pane_web.dart so maxed-out viewports are reliably classified as at bottom.
- 2026-09-17T10:24-0400 Hook scroll end notification for inertial fling settling: Wrapped TerminalView with NotificationListener<ScrollEndNotification> in terminal_pane_stub.dart so that when a fling finishes and isScrollingNotifier transitions to false, scroll anchors are reliably re-pinned and deferred bottom snaps complete.
- 2026-09-17T10:24-0400 Continuous grace-band downward release: In _captureScrollAnchor, removed _scrollAnchor.hasAnchor guard so consecutive downward scroll events inside the 3-line grace band consistently clear the anchor and arm deferred bottom snap rather than ping-ponging into capturing a new anchor.
- 2026-09-17T10:24-0400 Preserve web row 0 history scroll position: In terminal_pane_web.dart, updated onScrollCallback and _restoreScrollPosition to treat row 0 (savedY == 0 with baseY > 0) as a valid scrolled-up position and restore via scrollToLine(0) rather than purging the entry and snapping to bottom.
- 2026-09-17T10:24-0400 Unified session scroll cleanup: Extracted _clearSavedSessionScroll helper in terminal_pane_stub.dart to atomically remove all 4 session scroll maps across fit, refit, clear, input, and snap paths.
- 2026-09-17T11:40-0400 Microtask settling evaluation on scroll end: Wrap ScrollEndNotification handling in scheduleMicrotask to avoid evaluating stale isScrollingNotifier.value before ScrollPosition.beginActivity finishes updating the notifier.
- 2026-09-17T11:40-0400 Stationary grace band retention: Retain pending bottom snap and suppress scroll anchor capture while resting stationary in the grace band unless reversing upward, preventing spurious anchor creation.
- 2026-09-17T11:40-0400 Non-positive extent and headless font metric guards: Guard desiredOffset against non-positive maxScrollExtent, guard _repinScrollAnchor against unmeasured extents, and fall back to style metrics in _lineHeight() when renderTerminal is unmeasured in headless testing.

## Progress
- [x] Create worktree and plan file
- [x] Fix bottom detection in `terminal_scroll_anchor.dart`
- [x] Fix bottom checks and anchor retention in `terminal_pane_stub.dart`
- [x] Fix web bottom detection and gesture release snap in `terminal_pane_web.dart`
- [x] Add unit and widget tests for scroll-up stability during live streaming output
- [x] Run full test suite and analysis
- [x] Address CI review feedback and local review findings across Rounds 1-4
- [x] Update review refinements in `~/.gemini/review-refinements.md`
- [x] Run /antigravity-local-review-fix-loop max to clean approval

## Issues
- None.

## What Changed
- 2026-09-17T08:33-0400 flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart: tightened bottom detection threshold in capture() from kScrollPinReleaseGraceLines to 0.5px so scrolling up immediately creates and retains a scroll anchor.
- 2026-09-17T08:33-0400 flutter/triage_client/lib/widgets/terminal_pane_stub.dart: updated isAtBottom checks across saveScrollOffset, onFit, onRefit, and resize handling to use 0.5px threshold, preventing false bottom classification and anchor deletion when scrolled up near bottom; re-pinned scroll anchor on pointer up/cancel events.
- 2026-09-17T08:33-0400 flutter/triage_client/lib/widgets/terminal_pane_web.dart: updated viewportIsAtBottom to require viewportY >= baseY and remaining scroll distance <= 2px instead of 30px; guarded pointer-release bottom snap to only trigger when no scrolled-up position is saved.
- 2026-09-17T08:33-0400 flutter/triage_client/test/terminal/terminal_scroll_anchor_test.dart: added unit tests asserting capture behavior within and outside the 3-line grace band near bottom.
- 2026-09-17T08:33-0400 flutter/triage_client/test/widget_test.dart: added widget tests verifying that scrolling up near the bottom retains scroll position across refit, fit, and session lifecycle events without snapping to bottom.
- 2026-09-17T09:22-0400 flutter/triage_client/lib/widgets/terminal_pane_web.dart: widened remainingPixels check in _viewportIsAtBottom from 2px to 4px to accommodate high-DPI fractional layout rounding.
- 2026-09-17T09:22-0400 flutter/triage_client/test/terminal/terminal_scroll_anchor_test.dart: updated test description to clarify that anchor capture is asserted just above the bottom rather than within grace band.
- 2026-09-17T09:22-0400 flutter/triage_client/test/widget_test.dart: added session termination assertion to test both session start and termination events.
- 2026-09-17T10:24-0400 flutter/triage_client/lib/widgets/terminal_pane_stub.dart: wrapped TerminalView in NotificationListener<ScrollEndNotification> to handle fling settling; removed anchor re-capture in saveScrollOffset; removed _scrollAnchor.hasAnchor guard in _captureScrollAnchor to prevent downward ping-pong; extracted _clearSavedSessionScroll helper.
- 2026-09-17T10:24-0400 flutter/triage_client/lib/widgets/terminal_pane_web.dart: preserved row 0 history in onScrollCallback and _restoreScrollPosition; widened remainingPixels check in _viewportIsAtBottom.
- 2026-09-17T10:24-0400 flutter/triage_client/test/terminal/terminal_scroll_anchor_test.dart: added unit tests verifying consecutive downward events in grace band consistently report shouldReleaseScrollPin == true.
- 2026-09-17T10:24-0400 flutter/triage_client/test/widget_test.dart: added widget tests verifying fling scroll settling anchor preservation, grace zone streaming output stability, and grace band fling snap to bottom.
- 2026-09-17T11:40-0400 flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart: defined kNativeScrollSubpixelTolerance constant; guarded desiredOffset against non-positive maxScrollExtent.
- 2026-09-17T11:40-0400 flutter/triage_client/lib/widgets/terminal_pane_stub.dart: wrapped NotificationListener<ScrollEndNotification> handling in scheduleMicrotask; retained pending bottom snap during stationary touch in grace band; guarded _repinScrollAnchor against unmeasured extents; provided font metric fallback in _lineHeight.
- 2026-09-17T11:40-0400 flutter/triage_client/lib/widgets/terminal_pane_web.dart: tracked _sessionSavedViewportY on fit restoration; documented 10px threshold distinguishing web DOM scaling from native subpixel scroll physics.
- 2026-09-17T11:40-0400 flutter/triage_client/test/terminal/terminal_scroll_anchor_test.dart: added unit test for desiredOffset with non-positive maxScrollExtent.
- 2026-09-17T11:40-0400 flutter/triage_client/test/widget_test.dart: added widget tests for stationary touch in grace band, upward reversal after dragging down in grace band, and microtask anchor re-pinning on fling settling.
- 2026-09-18T22:11-0400 rebase onto main (7db2935, #172 hardware shift-tab): one conflict in terminal_pane_stub.dart isTest fallback, resolved by keeping #172's Focus wrapper (hardware backtab key handling) around identical fallback content; #172's tab-dispatch deltas in both panes are independent of scroll anchoring. Verified rebased Dart files are byte-identical to the CI-green tree outside #172's hunks; dart analyze and dart format clean.
- 2026-09-18T22:11-0400 Copilot review dispositions: devlog HEAD entry fixed to em-dash rule; anchor capture test name ('capturing just above the bottom holds an anchor') already renamed in 02e4187 so the grace-band comment is satisfied with no further change; widget 'start or terminate' test already covers both emitSessionStarted and emitSessionTerminated so that comment needs no change.

## Commits
- b9ebab2: fix(terminal): prevent scroll snapping to bottom on new content while scrolling up
- e1203c8: test(terminal): refine test assertions and widen web subpixel scroll epsilon
- db2f093: fix(terminal): eliminate anchor resurrection, preserve row 0 scroll, and hook fling settling
- 0bc60af: fix(terminal): defer scroll settling to microtask, retain stationary grace band touch, and guard unmeasured extents
- HEAD — docs(devlog): apply HEAD rule and record rebase onto main with Copilot review dispositions
