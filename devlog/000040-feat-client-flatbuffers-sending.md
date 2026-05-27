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

## Decisions

- Leverage generated FlatBuffers `ObjectBuilder` classes to cleanly construct outgoing request payloads.
- Dynamically select the serialization strategy (FlatBuffers vs JSON) based on the `WebSocketChannel.protocol` property post-connection.
- Attach to existing sessions as `AttachMode.InteractiveController` to match the interactive TUI operational requirements.

- [x] Modify `triage_websocket_client.dart` to implement full request serialization.
- [x] Verify that all client and daemon tests pass successfully.

## Commits

- HEAD — feat: implement client-side FlatBuffers serialization and sending
