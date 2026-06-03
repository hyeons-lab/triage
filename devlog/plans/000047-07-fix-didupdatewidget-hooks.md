## Thinking

We are addressing the issue where the layout still looks incorrect in `Triage.app` after sidebar collapse (stale wrapped lines and split prompt lines around the prompt).
As discovered:
- The previous agent (in Option B) removed the `replayRevision` check from `didUpdateWidget` in `terminal_pane_stub.dart`.
- When a session layout is resized, the daemon correctly reflows the history log and returns a new snapshot, incrementing `replayRevision`.
- But because `didUpdateWidget` was ignoring `replayRevision`, the native client never cleared the persistent `xt.Terminal` buffer and replayed the new, reflowed snapshot.
- As a result, the stale, pre-resize wrapped lines remained stuck in the visual terminal buffer, corrupting subsequent output.

### Action Plan
1. **Restore didUpdateWidget hooks in terminal_pane_stub.dart**:
   - Done. Added back checks for `resyncRevision`, `replayRevision`, `isExited`, and `replayPending` to trigger `_triggerFullReplayOrReset()`.
   - This ensures the persistent terminal buffer is cleared and replayed with the reflowed snapshot immediately when sizes or snapshots change.
2. **Rebuild all targets**:
   - Rebuild the Flutter web client: `flutter build web` inside `flutter/triage_client`.
   - Rebuild the Flutter macOS client: `flutter build macos` inside `flutter/triage_client`.
   - Recompile cargo release workspace packages: `cargo build --release -p triage && cargo build --release -p triaged`.
   - Install cargo release binaries: `cargo install --path crates/triage && cargo install --path crates/triaged`.
   - Copy the new macOS app: `rm -rf /Applications/Triage.app && cp -R flutter/triage_client/build/macos/Build/Products/Release/Triage.app /Applications/`.
3. **Verify all tests pass**:
   - Done. Verified that all 73 tests continue to pass.

## Plan

1. **Build Flutter Web Client**:
   Run `flutter build web` inside `flutter/triage_client`.
2. **Build Flutter macOS Client**:
   Run `flutter build macos` inside `flutter/triage_client`.
3. **Build Rust Crates**:
   `cargo build --release -p triage`
   `cargo build --release -p triaged`
4. **Install Rust Binaries**:
   `cargo install --path crates/triage`
   `cargo install --path crates/triaged`
5. **Copy macOS App to Applications**:
   `rm -rf /Applications/Triage.app`
   `cp -R flutter/triage_client/build/macos/Build/Products/Release/Triage.app /Applications/`
