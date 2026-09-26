# 000153-01: Terminal Delta Followup and Session Lifecycle Hardening

## Thinking

Following the merge of PR #174 (which introduced delta merging in `TerminalStore`, retained `SessionVm` instances across same-daemon reconnects, and eliminated spurious credential loops), several follow-up hardening opportunities and edge-case invariants were identified across the client terminal engine and session lifecycle:

1. **Negative counter corruption**:
   - `throughOutputSeq` and `rawOutputStart` counters originate from the schema as uint64 values. If an invalid or corrupted negative value arrives, it could bypass checks or poison watermark comparisons.
   - Solution: sanitize counters with `_sanitizeCounter`, treating negative numbers as null/unknown so they fall back safely toward replay rather than corrupting watermark comparisons.

2. **Host input suppression on delta-append path**:
   - In `_reduceHistory`, the full replay path invokes `_beginHostInputSuppression()` to suppress the emulator's responses to terminal queries (such as cursor position or device attributes) that are re-fed during replay, preventing them from leaking to the host.
   - During a delta merge that appends unseen bytes, re-fed terminal queries within the delta slice could similarly leak back to the host if not suppressed.
   - Solution: call `_beginHostInputSuppression()` before `_applyLive` on the delta-append path as well, and ensure `_clearSinkState` clears any active suppression timer so it cannot leak across lifecycle boundaries.

3. **Log shrink detection during daemon log trims**:
   - The daemon can rebase `bytes_logged` when trimming historical scrollback logs while `output_seq` stays monotonic. A trim presents as an advanced or unchanged sequence with fewer log bytes.
   - A stale snapshot also ends behind the live head, but its sequence trails applied baselines (staying a no-op).
   - Solution: refine `isLogShrunk` so when `snapshotEndBytes < currentLogBytes`, it only classifies as shrunk if the sequence is fresh (`isSeqFresh`), triggering a full replay.

4. **Zero-copy UTF-8 carry decode**:
   - When `_utf8Carry.isEmpty` in `_writeDecoded`, copying `bytes` with `List<int>.from(bytes)` is unnecessary because the buffer is only read or sliced.
   - Solution: alias `bytes` directly when carry is empty, avoiding heap allocations in high-throughput streaming.

5. **Popover rebuild optimization in `SessionListTile`**:
   - `_SessionListTileState.didUpdateWidget` called `_popoverEntry!.markNeedsBuild()` unconditionally on every widget update.
   - Solution: compare all visual properties displayed by the popover (`glanceTitle`, `title`, `customLabel`, `subtitle`, `statusColor`, `repoName`, `branch`, `worktreeName`, `cwd`, `snippet`, `snippetDetail`) before marking the entry dirty.

6. **Coalesced history refresh recovery**:
   - When a history refresh (`includeHistory: true`) races with an in-flight metadata refresh, it could be dropped by the `_refreshInFlight` guard, leaving the session without historical scrollback while reporting success.
   - Solution: track dropped history refreshes in `_refreshHistoryFollowUp` and schedule a follow-up once the in-flight refresh completes.

7. **Credential token trimming at boundaries**:
   - Normalize credentials at storage read boundaries (`_loadOrCreateClientId`, `_refreshBearerTokenFromStorage`) to match trimmed comparisons in the credential watcher.

8. **Test coverage**:
   - Add unit tests covering low-baseline sequence epoch resets, delta merges over plain `List<int>`, re-attach full replay after detach, shorter snapshot with advanced sequence, and reentrant dispose during history write.

## Plan

1. Verify and bundle `TerminalStore` hardening in `flutter/triage_client/lib/terminal/terminal_store.dart`:
   - Implement `_sanitizeCounter` for sequence numbers and byte offsets.
   - Add `_beginHostInputSuppression()` on the delta-append path.
   - Clean up suppression timers and host suppression flags in `_clearSinkState`.
   - Refine `isLogShrunk` logic for daemon log trimming under fresh sequence numbers.
   - Optimize `_writeDecoded` to avoid copying byte lists when UTF-8 carry is empty.

2. Verify and bundle `main.dart` session lifecycle hardening:
   - Optimize `SessionListTile.didUpdateWidget` to check visual properties before rebuilding popover entries.
   - Add `_refreshHistoryFollowUp` queue to ensure dropped history refreshes re-run.
   - Normalize stored client IDs and bearer tokens by trimming at boundaries.
   - Route auth exceptions cleanly in detached snapshot refresh follow-ups.

3. Verify unit tests in `flutter/triage_client/test/terminal/terminal_store_test.dart`:
   - Shorter snapshot with advanced sequence replays instead of no-op.
   - Delta merge over standard `List<int>` appends only the delta.
   - History replay after re-Attach replays even with overlapping sequence numbers.
   - Reentrant dispose during history write does not throw on notify.
   - Sequence epoch reset edge cases.

4. Run all validation suites:
   - `flutter analyze`
   - `flutter test`
   - `cargo fmt --all -- --check`
   - `cargo clippy --all-targets --all-features -- -D warnings`
   - `cargo test --workspace`

5. Commit devlog, plan, and code changes bundled together, push to origin, and open a pull request.
