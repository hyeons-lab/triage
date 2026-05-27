# Branch Devlog: feat/feat-client-flatbuffers-sending

- **Agent:** Antigravity
- **Intent:** Implement full client-side FlatBuffers serialization and sending inside `triage_client`, establishing dynamic bi-directional FlatBuffers communication.

## Intent

Support the FlatBuffers binary subprotocol in the Flutter client for outgoing requests (in addition to existing incoming parsing), enabling fully functional binary WebSocket communication with the daemon.

## What Changed

- Reinstated both `triage-flatbuffers` and `triage-json` subprotocols in connection parameters inside `triage_websocket_client.dart`.
- Implemented `isFlatBuffersNegotiated` getter to dynamically detect the negotiated subprotocol post-handshake.
- Added private serialization mapper `_serializeFlatBuffersRequest` using generated `ObjectBuilder` classes to serialize all 11 client request payloads.
- Intercepted `_send` and `writeInput` to serialize and dispatch binary FlatBuffers payloads instead of JSON text frames when `triage-flatbuffers` is active.
- Resolved subprotocol timing race conditions by awaiting the WebSocket handshake ready promise (`channel.ready`) before assigning the channel reference and sending any requests.
- Mapped outgoing `AttachSessionRequestTable.mode` dynamically from the input request mode string to corresponding FlatBuffers `AttachMode` enum values (`Observer`, `AgentController`, `InteractiveController`), rather than hardcoding.
- Tightened FlatBuffers attach mode validation so unsupported mode strings fail instead of silently becoming `InteractiveController`.
- Added regression tests for handshake publication timing, invalid attach modes, and `restoreSession` FlatBuffers serialization.

## Decisions

- Leverage generated FlatBuffers `ObjectBuilder` classes to cleanly construct outgoing request payloads.
- Dynamically select the serialization strategy (FlatBuffers vs JSON) based on the `WebSocketChannel.protocol` property post-connection.
- Attach to existing sessions as `AttachMode.InteractiveController` to match the interactive TUI operational requirements.

- [x] Modify `triage_websocket_client.dart` to implement full request serialization.
- [x] Verify that all client and daemon tests pass successfully.

## Commits

- HEAD — fix(client): address FlatBuffers PR review comments
- 34bb2d3 — fix(client): await channel ready and map AttachMode enum in FlatBuffers path
- 26fdbaf — docs(devlog): document round 2 review resolutions in plan file
- c0a411a — fix(client): resolve nested extraction bugs for styled_rows, attach, and subscribe client requests
- d9db6f5 — fix(client): address PR comments on channel safety, allocations, and add FlatBuffers unit tests
- 78f7a30 — feat(client): implement bi-directional FlatBuffers serialization and sending

## Progress

- 2026-05-27T13:57-0700: Addressed follow-up PR review comments by delaying channel publication until WebSocket readiness, rejecting unknown FlatBuffers attach modes, and adding focused test coverage for handshake timing, invalid modes, and restore-session serialization.
