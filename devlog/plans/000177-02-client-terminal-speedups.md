## Thinking

After migrating `triage_client` to `xterm2: ^5.4.0`, several hot paths on the Flutter client still perform avoidable allocations, byte scans, and timer churn on attach, history replay, and live streaming:

1. **Redundant gzip decompressions on snapshot attach, metadata refresh, and history page-up**:
   - `rawOutputViewportFromSnapshot(snapshot)` in `triage_websocket_client.dart` calls `rawOutputPrefixFromSnapshot(snapshot)` and `rawOutputFromSnapshot(snapshot)` internally, even when callers (`_loadDaemonSession`, `_applySnapshotToSession`, `_pageHistoryUp` in `main.dart`) already decoded both fields right before calling `rawOutputViewportFromSnapshot`.
   - In `_pageHistoryUp`, `snapshotCarriesHistory(snapshot)` also decompresses both fields before the caller immediately decompresses them again.
2. **Test-only `StyledRow` mirror allocation in production**:
   - `SessionVm.rows` (`fallbackRows` in `TerminalPane`) is only rendered when `runningUnderFlutterTest() && !TerminalPane.debugForceNativeTerminalView`.
   - In production builds, `_plainRowsFromSnapshot` still parses `snapshot['lines']` into `List<StyledRow>` and `StyledSpan` objects on every attach and metadata refresh, and `_applySnapshotToSession` deep-compares `session.rows` against `nextRows` via `_styledRowsEqual`.
3. **Redundant history byte scans in `TerminalStore` and `_PendingHistory`**:
   - `TerminalStore._reduceHistory` calls `trimHistoryReplay` unconditionally before checking `if (useViewportForRaw)`, even though the `useViewportForRaw` branch discards `trimmed` and computes `trimHistoryTailWithOffset(rawOutputPrefix, ...)` instead.
   - `trimHistoryReplay` scans `rawOutputPrefix` and `rawOutput` twice each via `_collectGenuineNewlineIndices` (once directly and once inside `trimHistoryTailWithOffset`).
   - `_PendingHistory.effectiveStart` recomputes `trimHistoryReplay` on every `session.historyStart` read while history awaits the initial terminal view fit.
4. **Mode 2026 `Timer` churn and per-write `xt.Terminal` notifications during history replay**:
   - `TerminalStore._processSynchronizedOutput` arms `_syncLiveFlushTimer` and `_syncWatchdogTimer` inside the `while (cursor < input.length)` loop at every `\x1b[?2026h` marker, only to cancel both timers on the very next iteration when `\x1b[?2026l` is encountered in the same chunk. Deferring timer arming until after the loop (when `_inSynchronizedOutput` remains true) eliminates timer churn for closed frames.
   - `writeToXterm` forwards `\x1b[?2026h` and `\x1b[?2026l` to `xt.Terminal.write`, which allocates its own 150ms watchdog timer per frame and suppresses `terminal.notifyListeners()` for 150ms when `TerminalStore` flushes an open frame. Stripping `\x1b[?2026h` and `\x1b[?2026l` in `writeToXterm` lets `TerminalStore` remain the single authority for Mode 2026 framing.
   - During `SessionVm._flushPendingHistory`, a replay containing many Mode 2026 frames invokes `_sink.write` hundreds of times synchronously, firing `terminal.notifyListeners()` on each write. Wrapping the synchronous history dispatch in `terminal.setSynchronizedUpdateMode(true)` and ending synchronized mode inside a `historyReplayed` listener batches all replay writes into a single notification before `TerminalPane._onHistoryReplayed` runs.
5. **Eager `xt.Terminal` allocation for unloaded rail placeholders and missing `terminal.dispose()`**:
   - `SessionVm` eagerly constructs `xt.Terminal(maxLines: _kNativeTerminalScrollbackLines)` for every rail placeholder session, even though unloaded rail items never mount a `TerminalPane` and are replaced by a fresh `SessionVm` when selected. Making `SessionVm.terminal` lazy and calling `_terminal?.dispose()` in `SessionVm.dispose()` avoids allocating unused terminal buffers and cleans up any active `xt.Terminal` timers on disposal.

## Plan

1. Update `rawOutputViewportFromSnapshot` in `flutter/triage_client/lib/services/triage_websocket_client.dart` (and `_rawOutputViewportFromSnapshot` in `lib/main.dart`) to accept optional `decodedPrefix` and `decodedRawOutput` buffers, and reuse already-decoded buffers across `_loadDaemonSession`, `_applySnapshotToSession`, and `_pageHistoryUp`.
2. Gate `_plainRowsFromSnapshot` and placeholder `_plainRow` allocations in `flutter/triage_client/lib/main.dart` behind `runningUnderFlutterTest()`.
3. In `flutter/triage_client/lib/terminal/terminal_store.dart`:
   - Move `trimHistoryReplay` into the `else` branch of `if (useViewportForRaw)` in `_reduceHistory`, and combine prefix + separator + viewport into a single `_writeHistoryChunk` call.
   - Pass precomputed newline indices into `trimHistoryTailWithOffset` from `trimHistoryReplay` so neither buffer is scanned twice.
   - Cache `effectiveStart` on `_PendingHistory` in `lib/main.dart`.
4. In `flutter/triage_client/lib/terminal/terminal_store.dart` and `lib/main.dart`:
   - Defer `_armSyncLiveFlush()` and `_rearmSyncWatchdog()` until after the marker loop in `_processSynchronizedOutput`.
   - Strip `\x1b[?2026h` and `\x1b[?2026l` in `writeToXterm`.
   - Batch `xt.Terminal` notifications across `SessionVm._flushPendingHistory()`.
5. Make `SessionVm.terminal` lazy in `flutter/triage_client/lib/main.dart` and dispose `_terminal` in `SessionVm.dispose()`.
6. Add unit tests in `flutter/triage_client/test/terminal/terminal_store_test.dart`, run `flutter analyze` and `flutter test`, update `devlog/000177-feat-xterm2-migration.md`, commit, push, and rebuild the release Android APK.
