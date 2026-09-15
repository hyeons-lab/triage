# Plan 01: Real-Time Session Synchronization

## Thinking

When a user creates or terminates a session on one client (e.g. from another laptop, via the TUI, or via the CLI), other connected clients (like the web client) do not update their siderail list of sessions in real time. The user must manually refresh the browser page or reconnect to see new sessions.

### Root Cause Analysis

1. **Protocol Absence**:
   The WebSocket protocol defined in `crates/triage-transport-ws` and the FlatBuffers schema in `crates/triage-core/schema/triage.fbs` support connection-wide pushes for:
   - `SessionSnippetUpdated`
   - `SessionContextUpdated`
   - `SessionJudgePolicyUpdated`
   - `RailPinsUpdated`
   - `SessionCustomLabelUpdated`
   - `UpdateAvailable`
   However, there are no push messages for session lifecycle events (`SessionStarted` or `SessionTerminated`).

2. **Daemon Does Not Broadcast on Lifecycle Changes**:
   In `crates/triaged/src/session.rs`:
   - `start_session`: inserts the new session into the `sessions` map and writes the manifest, but does not emit any message over `global_senders`.
   - `shutdown_session`: removes the session from the map and updates the manifest, but only delivers `SessionEvent::Exited` to clients directly subscribed to that session. Other clients are not notified.

3. **Client Session List Fetching is One-Shot**:
   In `flutter/triage_client/lib/main.dart`:
   - `_loadDaemonSessions` only runs once during the connection handshake.
   - When a session is created locally, it is added to `_sessions` in memory.
   - When a session is created or terminated remotely, no event is received and the client does not poll.

### Proposed Solution

1. **Schema & Protocol Extension**:
   - In `crates/triage-core/schema/triage.fbs`:
     Define `SessionStartedPayload` with fields:
     - `session_id: string;`
     - `current_working_directory: string;`
     - `repository_root: string;`
     - `worktree_root: string;`
     - `branch: string;`
     - `last_activity_ms: uint64;`
     Define `SessionTerminatedPayload` with fields:
     - `session_id: string;`
     Append `SessionStartedPayload` and `SessionTerminatedPayload` to `union ServerMessagePayload`.
   - In `crates/triage-transport-ws/src/lib.rs`:
     Add `SessionStarted` and `SessionTerminated` variants to `ServerMessage`.
   - In `crates/triage-transport-ws/src/flatbuffers_proto.rs`:
     Add serialization in `build_server_message` and deserialization in `parse_fb_server_message_borrowed` and `ServerMessageBorrowed`.
   - Regenerate Dart bindings using `scripts/generate-dart-flatbuffers.sh`.

2. **Daemon Broadcasts**:
   - In `crates/triaged/src/session.rs` `start_session`:
     After successfully inserting into `sessions` and persisting the manifest, broadcast `ServerMessage::SessionStarted` over `self.broadcast_global(...)`. Query the initial git context and activity timestamp from the actor/launch config.
   - In `crates/triaged/src/session.rs` `shutdown_session`:
     After successfully removing the session and persisting the manifest, broadcast `ServerMessage::SessionTerminated` over `self.broadcast_global(...)`.

3. **Client Handling**:
   - In `flutter/triage_client/lib/services/triage_websocket_client.dart`:
     - Decode `SessionStartedPayload` and `SessionTerminatedPayload` in `_onBinaryMessage`.
     - Forward `session_started` and `session_terminated` events to `_eventController` in both text and binary message handlers.
   - In `flutter/triage_client/lib/main.dart`:
     - Handle `session_started`:
       If the session ID is not already present in `_sessions`, instantiate a new `SessionVm` via `_loadingDaemonSession(sessionId, loading: false)`, apply initial context and activity timestamp, setup input listener, append to `_sessions`, and invoke `_regroupRail()`.
     - Handle `session_terminated`:
       If the session ID is present in `_sessions`, dispose its view model, destroy its terminal pane cache via `TerminalPane.destroySession`, remove it from `_sessions`, adjust `_selectedIndex` if needed, clean up pins/custom labels, invoke `_regroupRail()`, and attach the newly selected session if the active session was the one terminated.

4. **Testing & Validation**:
   - Unit tests in `crates/triage-transport-ws` verifying round-trip JSON and FlatBuffers serialization of `SessionStarted` and `SessionTerminated`.
   - Integration tests in `crates/triaged` verifying `start_session` and `shutdown_session` push global messages.
   - Flutter tests in `flutter/triage_client/test/triage_websocket_client_test.dart` and `widget_test.dart` verifying client decoding and live rail updates.
   - Verification with `cargo check --workspace`, `cargo test --workspace`, `cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `flutter analyze`, and `flutter test`.

## Plan

1. Edit `crates/triage-core/schema/triage.fbs` to add `SessionStartedPayload` and `SessionTerminatedPayload`.
2. Run `scripts/generate-dart-flatbuffers.sh` to update Dart generated FlatBuffers bindings.
3. Update `crates/triage-transport-ws/src/lib.rs` and `crates/triage-transport-ws/src/flatbuffers_proto.rs` with `SessionStarted` and `SessionTerminated`.
4. Update `crates/triaged/src/session.rs` to broadcast `SessionStarted` on `start_session` and `SessionTerminated` on `shutdown_session`.
5. Update `flutter/triage_client/lib/services/triage_websocket_client.dart` to decode and dispatch both messages.
6. Update `flutter/triage_client/lib/main.dart` to dynamically add and remove sessions in the rail.
7. Add Rust and Flutter tests for the new messages and state transitions.
8. Validate entire workspace, update devlog, commit, and push to PR.
