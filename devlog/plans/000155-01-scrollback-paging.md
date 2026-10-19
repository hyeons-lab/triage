# 000155-01 Scrollback Paging Fix

## Thinking

Scrollback paging stalls on two independent failure modes:

1. **Dense scrollback on native (`historyTrimBudgetsForWindow`)**: The initial 64 KiB attach window can already contain more than 1,000 lines (`kHistoryReplayMaxLines`). When the user scrolls to the top and requests a 128 KiB or 256 KiB window, trimming every replay to the same fixed 1,000-line budget drops the newly fetched older prefix and replays the exact same suffix. Moreover, recording `_appliedHistoryStart = rawStart` without adding the bytes dropped by `trimHistoryTail` makes `rawStart == 0` prematurely report that the beginning of the log is loaded even when older lines in that payload were trimmed away.
2. **Barren pages on TUI sessions (`_continuePastBarrenPage` and `NoOlderScrollbackPill`)**: Full-screen or scroll-region TUIs can produce 64–256 KiB of in-place redraws that add zero scrollback lines. When a page adds zero lines while the viewport is still near the top, the pane should automatically request the next deeper window until either new lines appear or the replay budget is exhausted, and then show a transient `NoOlderScrollbackPill` ("No older scrollback in reach") that auto-dismisses after 3 seconds or immediately on a subsequent replay/session swap.

## Plan

1. Add `historyTrimBudgetsForWindow(windowBytes, web: ...)` and `trimHistoryTailWithOffset` in `terminal_store.dart` so line budgets scale with the served window (`scaledLines.clamp(platformLines, kEmulatorMaxScrollbackLines)`) and `_appliedHistoryStart` reflects `rawStart + trimmed.droppedBytes`.
2. Thread `windowBytes` through `SessionVm.applyHistory`, `_PendingHistory`, and `HistoryBytes`, and consolidate `_canPageHistory` and `_pageHistoryUp` onto `_nextHistoryPage`.
3. Notify `notifyHistoryPageStarted()` and `notifyHistoryReplayed()` when a paged snapshot returns empty or non-progressing `effectiveStart` so the pane's barren-page continuation and exhaustion pill still run.
4. Implement `_continuePastBarrenPage`, `_dismissNoOlderScrollback`, and `NoOlderScrollbackPill` across `terminal_pane.dart`, `terminal_pane_stub.dart`, and `terminal_pane_web.dart` (measuring `wasNearTop` from the pre-replay anchor on web and restoring the scroll position before continuing).
5. Add unit and widget tests in `session_history_window_test.dart`, `terminal_store_test.dart`, `widget_test.dart`, and `live_history_paging_test.dart`.
