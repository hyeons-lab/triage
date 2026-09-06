# 000137: Session Tab Scroll State Cache and Delta Merge

- **Agent:** Gemini 3.8 Flash (High) @ triage branch fix/session-tab-scroll-cache
- **Intent:** Prevent jumpy scrolling and scroll position resetting to the top when switching between sessions, stop clearing and restoring sessions from scratch, and enable the client to cache session state and delta-merge updated output.

## What Changed

- **2026-09-05T18:03-0700** devlog/plans/000137-01-session-tab-scroll-cache.md: Created implementation plan for session tab scroll state caching and delta merging.
- **2026-09-05T19:03-0700** flutter/triage_client/lib/terminal/terminal_intent.dart, flutter/triage_client/lib/terminal/terminal_store.dart: Added rawOutputStart parameter to HistoryBytes, tracked _appliedLogBytes, and added delta-merge logic in _reduceHistory that appends new bytes without clearing sink or resetting carries when snapshots overlap.
- **2026-09-05T19:03-0700** flutter/triage_client/lib/main.dart: Updated SessionVm.applyHistory and _PendingHistory to carry rawOutputStart, bypassed Attach dispatch when store is already live to preserve streaming carries, passed rawOutputStart in _loadDaemonSession, _applySnapshotToSession, and _createSession, and imported terminal_state.dart.
- **2026-09-05T19:03-0700** flutter/triage_client/lib/widgets/terminal_pane_stub.dart: Initialized ScrollController with saved offset or _kBottomScrollSentinel (1e9) to clamp to bottom on frame 1 without top snapping or assertion errors, and prevented sub-pixel jumpTo jitter.
- **2026-09-05T19:03-0700** flutter/triage_client/lib/widgets/terminal_pane_web.dart: Added detachment and visibility guards to onScrollCallback to prevent DOM unmount artifacts from corrupting saved viewport to line 0, snapshotted viewportY prior to container unbinding, added persistent session write listeners so background tabs receive live output, and avoided destructive resets during tab switches or session restore.
- **2026-09-05T19:03-0700** flutter/triage_client/test/terminal/terminal_store_test.dart: Added unit tests verifying delta-merge append without sink clear, fully covered no-op, and ring buffer rollover fallback replay.
- **2026-09-05T19:38-0700** flutter/triage_client/lib/main.dart: Dispatched Attach on history restore when store.state.exited is true, and formatted if-statement in filter with braces.
- **2026-09-05T19:38-0700** flutter/triage_client/lib/terminal/terminal_store.dart: Guarded delta merge with !s.exited and exact sequence matching fallback, enforced monotonic historyHighWaterSeq resolution, and reset _appliedLogBytes in _resetCarries.
- **2026-09-05T19:38-0700** flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart: Added clone and copyFrom methods to preserve scroll anchor state across widget lifecycles.
- **2026-09-05T19:38-0700** flutter/triage_client/lib/widgets/terminal_pane_stub.dart: Maintained _sessionSavedScrollAnchors static cache, captured anchor before saving offset, restored scroll anchor on widget init and session swap, and used null-aware element for copy button.
- **2026-09-05T19:38-0700** flutter/triage_client/lib/widgets/terminal_pane_web.dart: Safely flushed pending live write buffer in dispose to prevent dropped writes on fast tab switch, deduplicated persistent controller unbinding, removed premature unmounted jump in scroll restoration, and refit terminal before restoring scroll position.
- **2026-09-05T19:38-0700** flutter/triage_client/test/terminal/terminal_store_test.dart, flutter/triage_client/test/terminal/terminal_scroll_anchor_test.dart: Added regression tests for exited session restoration delta-merge bypass and scroll anchor cloning/copying.

## Decisions

- **2026-09-05T18:03-0700 Decision: TerminalStore Delta Merge over Full Clear**: Instead of dispatching `Attach` and clearing the terminal sink on every snapshot refresh or session restore, inspect `raw_output_start` and the client's `_appliedLogBytes`. When the snapshot overlaps with the client's current sequence, slice only the newly arrived delta bytes and append them via `_applyLive`. This prevents screen clearing, keeps existing scrollback intact, and preserves the viewport position.
- **2026-09-05T18:08-0700 Decision: Cumulative Byte Offset Tracking in TerminalStore**: In `crates/triaged/src/session.rs`, `output_seq` is a per-chunk monotonic sequence number whereas `raw_output_start` and `bytes_logged` are cumulative byte offsets. Tracking cumulative byte offsets (`_appliedLogBytes`) in `TerminalStore` avoids unit mismatch and computes exact byte slices against `bytes_logged`.
- **2026-09-05T18:08-0700 Decision: Finite Initial Scroll Offset Sentinel**: Use `1e9` as the bottom scroll sentinel for `ScrollController(initialScrollOffset: ...)` on native. This complies with Flutter's `assert(initialScrollOffset.isFinite)` while clamping cleanly to `maxScrollExtent` during the first layout pass.
- **2026-09-05T18:08-0700 Decision: Selective Attach Dispatch**: When `SessionVm.applyHistory` receives an updated snapshot for an already-live session, do not dispatch `Attach()`. This preserves streaming carries and live status so `TerminalStore` can cleanly delta-merge.
- **2026-09-05T18:03-0700 Decision: Web Detachment Scroll Guard**: In `terminal_pane_web.dart`, ignore xterm.js scroll callbacks when the container is detached from the DOM or clientWidth is 0. This prevents DOM detachment artifacts (`scrollTop == 0`) from corrupting `_sessionSavedViewportY` to line 0.
- **2026-09-05T18:03-0700 Decision: Background Write Delivery for Web Cached Sessions**: Maintain write routing to cached `xterm.js` instances while tabs are switched away so background sessions stay up to date and do not require full re-emulation upon tab re-selection.
- **2026-09-05T19:38-0700 Decision: Exited State Resets on History Restore**: When a session exits, `store.state.exited` is set to true. On subsequent history restoration, dispatching `Attach()` resets the store to `awaitingHistory`, clears `exited`, and resets sequence and log byte trackers so the new session instance replays cleanly without deadlocking input or dropping output.
- **2026-09-05T19:38-0700 Decision: Native Scroll Anchor Caching Across Tab Switches**: Cache `TerminalScrollAnchor` instances in `_sessionSavedScrollAnchors` keyed by `terminalId`. When returning to a tab where the user had scrolled up, restore the anchor so background output trims do not drift the viewport.

## Issues

- **2026-09-05T19:38-0700 Issue: Exited Session Restoration Deadlock**:
  - Problem: If a session exited, `store.state.exited` remained true while `phase` remained `live`. When restored with seq 0, `SessionVm.applyHistory` skipped `Attach()`, and `_reduceHistory` evaluated `currentSeq >= throughOutputSeq` as true, dropping the fresh prompt and leaving the terminal in a dead input state.
  - Resolution: Added `store.state.exited` check to dispatch `Attach()`, guarded delta-merge with `!s.exited`, and added regression test.
- **2026-09-05T19:38-0700 Issue: Web Buffer Dropped on Fast Tab Switch**:
  - Problem: If a user switched tabs while history replay was staged, live writes buffered in `_pendingLiveWriteBuffer` were discarded when the pane was disposed.
  - Resolution: Added `_flushPendingLiveWrites()` at the top of `dispose()` in `terminal_pane_web.dart`.

## Progress

- [x] Initial research and root cause diagnosis
- [x] Create worktree and branch devlog / plan
- [x] Implement delta merge in `TerminalIntent`, `TerminalStore`, and `SessionVm`
- [x] Implement native initial scroll offset preservation
- [x] Implement web detachment scroll guard and background write delivery
- [x] Verify tab switching and session restore behavior
- [x] Add unit and widget tests
- [x] Verify flutter and cargo test suites pass cleanly
- [x] Round 1 Antigravity local code review (Max effort)
- [x] Apply Round 1 review fixes and verify test suites
- [x] Round 2 Antigravity local code review (Max effort: Clean pass / Approved)
- [x] Apply Round 2 hygiene and verify test suites

## Commits

- cd0a50f: fix(client): cache session scroll state and delta-merge terminal output
- HEAD: fix(client): harden session tab scroll cache and restore lifecycle
