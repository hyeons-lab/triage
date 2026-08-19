# Plan: Session Auto-Approval Judge Toggle UI (Flutter + TUI)

## Thinking

The approval judge backend and heuristic allowlists are functional in `triaged`, and the TUI has keyboard shortcut (`F5`) support with text badges (`🤖`/`👤`). However, remote Flutter web/desktop users currently lack visual indicators and toggle controls for auto-approval in the side rail and top session header, and TUI users cannot click the badge with a mouse to toggle auto-approval.

We need to:
1. Extend the FlatBuffers and JSON WebSocket protocol in `crates/triage-core/schema/triage.fbs` and `crates/triage-transport-ws`:
   - Add requests: `GetSessionJudgePolicy`, `SetSessionJudgePolicy`, `ListSessionJudgePolicies`.
   - Add results: `SessionJudgePolicyResult`, `SessionJudgePoliciesResult`.
   - Add event payload: `SessionJudgePolicyUpdatedPayload`.
   - Broadcast `ServerMessage::SessionJudgePolicyUpdated` whenever a session's policy changes.
2. Regenerate Dart FlatBuffers bindings via `scripts/generate-dart-flatbuffers.sh`.
3. Update Flutter WebSocket client (`flutter/triage_client/lib/services/triage_websocket_client.dart`):
   - Expose methods `getSessionJudgePolicy`, `setSessionJudgePolicy`, `listSessionJudgePolicies`.
   - Handle incoming `SessionJudgePolicyUpdated` events.
4. Update Flutter UI (`flutter/triage_client/lib/main.dart`):
   - Add `judgePolicy` and `onToggleJudgePolicy` to `SessionListTile` / `SessionRail`.
   - Render a toggleable icon button (`Icons.smart_toy` / `Icons.person_outline` or custom badge) in each session tile and in the active session header.
   - Wire 1-click toggling to update the daemon immediately with real-time UI reaction.
5. Update Ratatui Terminal TUI (`crates/triage/src/main.rs`):
   - Add mouse click support on the session sidebar item / `🤖`/`👤` badge to toggle auto-approval directly.
6. Verify and test:
   - Run `cargo fmt`, `cargo clippy`, `cargo test --workspace`.
   - Run `flutter analyze` and `flutter test`.
   - Test live `triaged reload` and verify UI interaction.

## Plan

1. **Schema & Protocol**:
   - Edit `crates/triage-core/schema/triage.fbs` with new requests/results/payloads.
   - Run `./scripts/generate-dart-flatbuffers.sh` to update Dart generated files.
   - Update `crates/triage-transport-ws/src/lib.rs` and `crates/triage-transport-ws/src/flatbuffers_proto.rs`.
   - Update `crates/triaged/src/session.rs` to broadcast `SessionJudgePolicyUpdated` in `set_session_judge_policy`.

2. **Flutter Client Integration**:
   - In `triage_websocket_client.dart`, add judge policy API methods and event parser.
   - In `main.dart`, store `judgePolicy` in `SessionVm`, seed on connect via `listSessionJudgePolicies()`, and subscribe to updates.
   - Add toggle buttons in `SessionListTile` and `_SessionHeader`.

3. **Terminal TUI Mouse Interaction**:
   - In `crates/triage/src/main.rs`, update mouse click handling in `sidebar_area` to select session and toggle judge policy on badge click.

4. **Testing & Validation**:
   - Verify Rust and Flutter tests pass.
   - Update devlog and push commits to PR #143.
