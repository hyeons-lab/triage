# Plan: Implement Client-Side FlatBuffers Serialization & Sending

This plan details implementing the serialization and transmission of client requests using FlatBuffers inside the Flutter client (`triage_client`), complementing its existing deserializer and establishing a fully bi-directional FlatBuffers capability.

## Thinking

1.  **Requirement**:
    *   The client needs to support binary serialization for the FlatBuffers subprotocol.
    *   Currently, it parses FlatBuffers from the server but only sends JSON text frames when communicating, which causes frame-type mismatch crashes on the server.
2.  **Proposed Design**:
    *   Reinstate `protocols: ['triage-flatbuffers', 'triage-json']` to connect to both subprotocols.
    *   Expose `isFlatBuffersNegotiated` based on `_channel!.protocol == 'triage-flatbuffers'`.
    *   Map all client-side requests to corresponding generated FlatBuffers builder objects and serialize them when `isFlatBuffersNegotiated` is true.
3.  **Client request mappings**:
    *   `hello`: `HelloRequestObjectBuilder`
    *   `pair`: `PairRequestObjectBuilder`
    *   `start_session`: `StartSessionRequestTableObjectBuilder`
    *   `list_sessions`: `ListSessionsRequestObjectBuilder`
    *   `attach_session`: `AttachSessionRequestTableObjectBuilder`
    *   `subscribe_session_events`: `SubscribeSessionEventsRequestTableObjectBuilder`
    *   `resize_session`: `ResizeSessionRequestTableObjectBuilder`
    *   `restore_session`: `RestoreSessionRequestTableObjectBuilder`
    *   `snapshot_session`: `SnapshotSessionRequestObjectBuilder`
    *   `shutdown_session`: `ShutdownSessionRequestObjectBuilder`
    *   `styled_rows`: `StyledRowsRequestTableObjectBuilder`
    *   `write_input`: `WriteInputRequestTableObjectBuilder`

## Plan

1.  **Create Devlog & Plan**: Done.
2.  **Modify `triage_websocket_client.dart`**:
    *   Offer both subprotocols in `protocols`.
    *   Inspect `_channel!.protocol` to determine the active protocol.
    *   Add a private helper method `_serializeFlatBuffersRequest` to handle mapping and serialization of outgoing payloads.
    *   Integrate the FlatBuffers path into `_send` and `writeInput`.
3.  **Verification**:
    *   Run `flutter test` and `cargo test --workspace` to ensure all tests pass.
