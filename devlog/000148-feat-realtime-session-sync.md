# Real-Time Session List Synchronization

## Agent
Antigravity (gemini-3.8-flash) @ triage branch feat/realtime-session-sync

## Intent
Synchronize the session list across connected clients in real time so that when sessions are created or terminated from another client (e.g. laptop, TUI, or CLI), other connected clients (like Flutter web) update their siderails immediately without requiring a page refresh.

## What Changed
- 2026-09-14T23:18-0400 devlog/plans/000148-01-realtime-session-sync.md: authored plan to introduce SessionStarted and SessionTerminated push messages across daemon, transport, FlatBuffers schema, and client.
- 2026-09-14T23:20-0400 crates/triage-core/schema/triage.fbs: added SessionStartedPayload and SessionTerminatedPayload tables to FlatBuffers schema and added both to ServerMessagePayload union.
- 2026-09-14T23:20-0400 flutter/triage_client/lib/generated/triage_triage.generated_generated.dart: regenerated Dart FlatBuffers bindings using scripts/generate-dart-flatbuffers.sh.
- 2026-09-14T23:21-0400 crates/triage-transport-ws/src/lib.rs: added SessionStarted and SessionTerminated enum variants to ServerMessage with serde serialization.
- 2026-09-14T23:21-0400 crates/triage-transport-ws/src/flatbuffers_proto.rs: implemented binary FlatBuffers serialization and zero-copy deserialization for SessionStarted and SessionTerminated payloads.
- 2026-09-14T23:21-0400 crates/triaged/src/session.rs: emitted SessionStarted in start_session off-lock with resolved context metadata, and SessionTerminated in shutdown_session upon session termination and manifest removal.
- 2026-09-14T23:21-0400 flutter/triage_client/lib/services/triage_websocket_client.dart: handled session_started and session_terminated text events and decoded SessionStartedPayload and SessionTerminatedPayload binary FlatBuffers frames into typed event maps.
- 2026-09-14T23:21-0400 flutter/triage_client/lib/main.dart: subscribed to session_started and session_terminated events, inserting new sessions into _sessions with context metadata and removing terminated sessions while updating selected index and regrouping the siderail.
- 2026-09-14T23:23-0400 crates/triaged/src/session.rs: added session_lifecycle_broadcasts_started_and_terminated unit test validating broadcast delivery over global push channel.
- 2026-09-14T23:24-0400 flutter/triage_client/test/triage_websocket_client_test.dart: added unit tests for decoding SessionStartedPayload and SessionTerminatedPayload over FlatBuffers binary protocol and dispatching JSON text events.
- 2026-09-14T23:25-0400 flutter/triage_client/test/widget_test.dart: added widget tests verifying siderail dynamically adds new session on session_started and removes session on session_terminated.

## Decisions
- 2026-09-14T23:18-0400 Broadcast SessionStarted and SessionTerminated via connection-wide push channel: rather than requiring clients to poll listSessions periodically, emit push messages over the existing global_senders broadcast channel so connected clients receive updates with zero latency and no polling overhead.
- 2026-09-14T23:18-0400 Include initial context in SessionStarted: include working directory, repository root, worktree root, branch, and activity timestamp in the SessionStarted payload so receiving clients can group and render the new session row immediately without waiting for a secondary context fetch.
- 2026-09-14T23:20-0400 Fetch session context off-lock before broadcasting SessionStarted: in start_session, drop the sessions mutex before querying actor context via request_session_context to eliminate lock contention during actor channel communication.

## Commits
HEAD: feat(session): real-time session list synchronization across daemon and clients

## Progress
- [x] Create worktree `worktrees/realtime-session-sync` and branch `feat/realtime-session-sync`
- [x] Create plan `devlog/plans/000148-01-realtime-session-sync.md` and devlog `devlog/000148-feat-realtime-session-sync.md`
- [x] Extend FlatBuffers schema with `SessionStartedPayload` and `SessionTerminatedPayload`
- [x] Regenerate Dart FlatBuffers bindings via `scripts/generate-dart-flatbuffers.sh`
- [x] Extend `triage-transport-ws` protocol and serialization/deserialization
- [x] Broadcast `SessionStarted` and `SessionTerminated` from `triaged` `start_session` and `shutdown_session`
- [x] Implement client push message decoding in `triage_websocket_client.dart`
- [x] Update `main.dart` to dynamically add/remove sessions and regroup the siderail
- [x] Add comprehensive Rust and Flutter unit/widget tests
- [x] Validate workspace, format, clippy, tests
