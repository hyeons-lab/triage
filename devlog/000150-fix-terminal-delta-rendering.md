# 000150: fix/terminal-delta-rendering

## Intent

Fix terminal rendering in the Triage client so it does not clear and re-render the entire screen contents, lose scroll position, and scroll down from the top every few seconds while loading. Implement reliable delta updates, cache existing terminal buffers across reconnects and session switches, and prevent spurious reconnect loops.

## Decisions

- 2026-09-16T15:21-0400: Correct regression detection in `TerminalStore._reduceHistory`. A snapshot with an `output_seq` or log byte offset behind the live stream is a normal race where the client is ahead, not an epoch regression. Use `kSeqEpochResetWindow` for epoch reset detection and allow snapshots with `currentLogBytes >= snapshotEndBytes` to no-op cleanly without clearing the terminal buffer.
- 2026-09-16T15:21-0400: Preserve `_appliedLogBytes` and terminal state in `SessionVm.applyHistory`. Avoid dispatching `Attach()` when the session is already live or has scrollback history ready, allowing incoming snapshots to delta-merge seamlessly.
- 2026-09-16T15:21-0400: Retain existing `SessionVm` instances and terminal buffers across reconnects to the same daemon in `_loadDaemonSessions`. Reconcile metadata and grouping in place instead of disposing active terminals, wiping the sessions list, and forcing a full screen clear and replay.
- 2026-09-16T15:21-0400: Guard against spurious reconnect loops in `_checkCredentialStorageStillMatches`. Normalize credential string comparisons with trimming, and avoid tearing down active authenticated connections when storage is temporarily unhydrated.
- 2026-09-16T17:16-0400: Address review findings across multi-round audits. Gated `_hidePopover()` teardown to unconditionally invoke `entry.remove()` and `entry.dispose()`, debounced resubscription requests via `_resubscribeInFlight`, handled auth challenges cleanly in background snapshot refreshes, and rolled back subscription state and pending events on resubscription failure.

## What Changed

- 2026-09-16T15:52-0400 flutter/triage_client/lib/terminal/terminal_store.dart: Rewrote regression detection (`isSnapshotSeqRegressed`, `hasLogByteGap`, `isLogShrunk`) so snapshots behind or overlapping live output do not abort delta merge. Made fully covered snapshots cleanly no-op and overlapping snapshots append delta bytes via `_applyLive` without buffer resets.
- 2026-09-16T15:52-0400 flutter/triage_client/lib/main.dart: Preserved `_appliedLogBytes` in `applyHistory` by avoiding spurious `Attach()` dispatches on ready scrollbacks. Preserved existing `SessionVm` instances and active terminal buffers across daemon reconnections instead of clearing and disposing them. Replaced `OverlayPortal` with `OverlayEntry` in `_SessionListTileState` to eliminate Flutter accessibility semantics assertion collisions.
- 2026-09-16T15:52-0400 flutter/triage_client/test/terminal/terminal_store_test.dart: Added unit tests verifying delta merge behaviour for snapshots behind live output and snapshots overlapping live output.
- 2026-09-16T17:16-0400 flutter/triage_client/lib/terminal/terminal_store.dart: Refined sequence 0 reset detection for null `rawOutputStart`, added `lastSnapshotSeq == null` handling in `isLogShrunk`, and called `_closeSyncBlockAndFlush()` on delta append.
- 2026-09-16T17:16-0400 flutter/triage_client/lib/main.dart: Cleared `_subscriptionIds` on disconnect, added `_resubscribeInFlight` debounce set, safely routed `TriageAuthException` in background snapshot refreshes, styled load failures in red upon selection resubscription failure, and cleaned up popover overlay teardown.
- 2026-09-16T17:16-0400 flutter/triage_client/test/terminal/terminal_store_test.dart: Added tests for sequence fallback without rawOutputStart, unchanged snapshot sequences, UTF-8 rune splitting across delta boundaries, and empty snapshot payloads.

## Commits

- HEAD: fix(client): resolve terminal flicker and preserve session buffer on reconnect

## Progress

- [x] Harden delta merge logic in `TerminalStore._reduceHistory`
- [x] Preserve delta merge state in `SessionVm.applyHistory`
- [x] Preserve existing sessions and terminal buffers across reconnects in `_loadDaemonSessions`
- [x] Prevent spurious reconnect loops in `_checkCredentialStorageStillMatches`
- [x] Add unit tests for terminal store delta merge edge cases
- [x] Resolve Flutter accessibility semantics assertion collision in session list tiles
- [x] Verify Flutter test suite and analyze checks (518 tests passing, 0 analyze issues)
- [x] Verify Rust tests and workspace checks (331 tests passing, 0 clippy warnings)
- [x] Run iterative Antigravity Code Review loops to clean status
