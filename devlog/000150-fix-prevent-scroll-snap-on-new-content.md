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

## Progress
- [x] Create worktree and plan file
- [x] Fix bottom detection in `terminal_scroll_anchor.dart`
- [x] Fix bottom checks and anchor retention in `terminal_pane_stub.dart`
- [x] Fix web bottom detection and gesture release snap in `terminal_pane_web.dart`
- [x] Add unit and widget tests for scroll-up stability during live streaming output
- [x] Run full test suite and analysis

## Issues
- None.

## What Changed
- 2026-09-17T08:33-0400 flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart: tightened bottom detection threshold in capture() from kScrollPinReleaseGraceLines to 0.5px so scrolling up immediately creates and retains a scroll anchor.
- 2026-09-17T08:33-0400 flutter/triage_client/lib/widgets/terminal_pane_stub.dart: updated isAtBottom checks across saveScrollOffset, onFit, onRefit, and resize handling to use 0.5px threshold, preventing false bottom classification and anchor deletion when scrolled up near bottom; re-pinned scroll anchor on pointer up/cancel events.
- 2026-09-17T08:33-0400 flutter/triage_client/lib/widgets/terminal_pane_web.dart: updated viewportIsAtBottom to require viewportY >= baseY and remaining scroll distance <= 2px instead of 30px; guarded pointer-release bottom snap to only trigger when no scrolled-up position is saved.
- 2026-09-17T08:33-0400 flutter/triage_client/test/terminal/terminal_scroll_anchor_test.dart: added unit tests asserting capture behavior within and outside the 3-line grace band near bottom.
- 2026-09-17T08:33-0400 flutter/triage_client/test/widget_test.dart: added widget tests verifying that scrolling up near the bottom retains scroll position across refit, fit, and session lifecycle events without snapping to bottom.

## Commits
- HEAD: fix(terminal): prevent scroll snapping to bottom on new content while scrolling up
