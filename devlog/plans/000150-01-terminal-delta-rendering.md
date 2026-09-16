# 000150-01: Terminal Delta Rendering and Cache Preservation

## Thinking

The user reported that terminal rendering repeatedly clears and re-renders the entire contents, loses scroll position, and scrolls down from the top every few seconds while loading data:
1. It frequently loses its scroll position.
2. It resets and clears the screen over and over.
3. It keeps starting from the top every few seconds and scrolls down as data streams in.

### Root Cause Diagnosis

Through detailed tracing of `TerminalStore`, `SessionVm`, and `TriageHome` in `flutter/triage_client`, four interacting root causes were identified:

1. **`TerminalStore._reduceHistory` delta merge condition false-positive regressions**:
   - `isSequenceRegressed` checked `throughOutputSeq < baselineSeq`. In a live session streaming chunks, `_appliedLiveSeq` advances ahead of asynchronous snapshots. When a snapshot arrives with `throughOutputSeq <= _appliedLiveSeq`, `isSequenceRegressed` evaluated to `true`, treating normal client lead as a regression and bypassing delta merge.
   - `isLogBytesRegressed` checked `rawOutputStart + bytes.length < currentLogBytes`. When live bytes advance `_appliedLogBytes` beyond the snapshot tail, this condition evaluated to `true`, disabling the exact case lines 347-360 were written to handle (`currentLogBytes >= snapshotEndBytes`).
   - Consequently, any snapshot received on an active session aborted delta merge and triggered `FULL REPLAY`, executing `_sink.clear()`, wiping the xterm buffer, resetting viewport scroll, and replaying all bytes from byte 0.

2. **`SessionVm.applyHistory` dispatches `const Attach()` unconditionally on non-live phase**:
   - When `applyHistory` is called on a session that already has history or when a re-attach occurs, if `phase != AttachPhase.live || wasExited`, `store.dispatch(const Attach())` was dispatched.
   - `Attach()` sets `_appliedLogBytes = null` and resets phase to `awaitingHistory`. This wiped the exact byte offset state required for delta merging in `TerminalStore`, forcing every subsequent `HistoryBytes` action to take the full replay and clear branch.

3. **`_loadDaemonSessions` destroys all existing sessions on reconnect**:
   - When reconnecting to the same server, `_loadDaemonSessions` disposed all existing `SessionVm` instances and cleared `_sessions.clear()`.
   - It then instantiated brand new `SessionVm` and `TerminalStore` instances, throwing away the existing terminal buffer and requiring a complete replay from byte 0.

4. **Credential storage watcher periodic reconnect loop**:
   - `_credentialStorageTimer` runs every 2 seconds invoking `_checkCredentialStorageStillMatches()`.
   - If `retrieveTokenFor(_activeServerId) != _bearerToken` (due to storage timing, key prefix mismatches, whitespace, or unsaved credentials), it set `_bearerToken = null` and called `_connectWebSocket(isReconnect: true)`.
   - This caused an aggressive reconnect loop every 2 seconds, triggering the full session wipe, dispose, re-instantiation, terminal clear, and full history replay.

### Target Architecture

1. **`TerminalStore` Delta Merge Hardening**:
   - Sequence regression is only an epoch reset when `throughOutputSeq < baselineSeq - kSeqEpochResetWindow` (consistent with `_isSeqEpochReset`).
   - Log bytes regression occurs only when there is a true gap (`currentLogBytes < rawOutputStart`) or an epoch reset.
   - When `currentLogBytes >= snapshotEndBytes`, the store safely no-ops without modifying terminal buffers.
   - When `currentLogBytes` overlaps with `[rawOutputStart .. rawOutputStart + bytes.length]`, only the unseen delta bytes are extracted and written via `_applyLive`.
   - Viewport scroll position is preserved without invoking `_sink.clear()`.

2. **`SessionVm.applyHistory` Delta Preservation**:
   - Do not dispatch `const Attach()` if the session already has `scrollbackReady` and an active `_appliedLogBytes` anchor, allowing snapshots to delta-merge directly.

3. **Session Cache Invalidation Safeguards in `_loadDaemonSessions`**:
   - On reconnect to the same server (`sameServer == true`), preserve existing `SessionVm` instances and terminal buffers.
   - Reconcile the session list in place: update context, activity stamps, and labels, while only disposing sessions that no longer exist on the daemon.
   - Prevent re-instantiating active sessions and destroying terminal state.

4. **Credential Watcher Normalization**:
   - Trim tokens and verify non-empty values before triggering reconnects.
   - If currently connected and authenticated, ensure storage contains the active token rather than tearing down a valid connection.

## Plan

1. Update `TerminalStore` in `flutter/triage_client/lib/terminal/terminal_store.dart`:
   - Correct `isSequenceRegressed` and `isLogBytesRegressed` calculations.
   - Ensure delta merge handles already-covered and overlapping snapshots without clearing the sink.
   - Add unit tests in `flutter/triage_client/test/terminal/terminal_store_test.dart` covering:
     - Snapshot with sequence or bytes behind live stream without clearing.
     - Snapshot overlapping live stream appending only delta bytes.
     - Gap in history triggering clean replay.
     - True sequence epoch reset triggering clean replay.

2. Update `SessionVm.applyHistory` in `flutter/triage_client/lib/main.dart`:
   - Preserve `_appliedLogBytes` across snapshot refreshes by skipping `Attach()` when `scrollbackReady` is true and `appliedLogBytes != null`.

3. Update `_loadDaemonSessions` and `_loadDaemonSessionInto` in `flutter/triage_client/lib/main.dart`:
   - Preserve existing `SessionVm` instances across reconnects when `sameServer` is true.
   - Avoid clearing `_sessions` and disposing active terminal controllers when reconnecting to the same daemon.
   - Avoid creating duplicate replacement view models when a session is already loaded.

4. Normalize `_checkCredentialStorageStillMatches` in `flutter/triage_client/lib/main.dart`:
   - Guard against spurious reconnect loops when credentials match after trimming or when active connection is already established.

5. Validate test suite and build targets:
   - Run `flutter test` across all client test suites.
   - Run `cargo check --workspace` and `cargo test --workspace`.
   - Verify web and macOS compilation.
