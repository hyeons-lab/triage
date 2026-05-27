# Plan: Fix WebSocket Subprotocol Mismatch in Flutter Client

This plan details dropping the unsupported FlatBuffers subprotocol advertisement from the client's WebSocket connection protocols to ensure it only requests JSON subprotocol communication.

## Thinking

1.  **Bug Details**:
    *   The Flutter client offers `protocols: ['triage-flatbuffers', 'triage-json']`.
    *   Because `triage-flatbuffers` is listed first, the server selects the binary FlatBuffers subprotocol.
    *   However, the client currently only implements JSON serialization and sends text frames (`Message::Text`).
    *   The server detects the incorrect frame type for the FlatBuffers subprotocol, errors out, and shuts down the connection.
2.  **Proposed Fix**:
    *   In `flutter/triage_client/lib/services/triage_websocket_client.dart` on line 16, remove `'triage-flatbuffers'` from the list of advertised protocols, leaving only `'triage-json'`.
    *   This forces the server to negotiate `triage-json`, which matches the client's actual capability.
3.  **Verification**:
    *   Run `flutter test` inside the client to verify no unit test regressions occur.
    *   Run `cargo test --workspace` inside the workspace to verify the daemon side remains unaffected.

## Plan

1.  **Modify Client Code**:
    *   Update `flutter/triage_client/lib/services/triage_websocket_client.dart` to specify `protocols: ['triage-json']`.
2.  **Verify**:
    *   Run `flutter test` in `flutter/triage_client` to confirm all client integration and unit tests pass.
    *   Run `cargo test --workspace` to ensure all daemon unit tests pass.
