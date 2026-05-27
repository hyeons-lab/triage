# Branch Devlog: fix/ws-subprotocol-json

- **Agent:** Antigravity
- **Intent:** Configure the Flutter client's WebSocket connection to only advertise the `triage-json` subprotocol, resolving a frame-type mismatch crash on the server.

## Intent

Resolve the connection loop issue where the server negotiates `triage-flatbuffers` but the client only implements and transmits JSON text frames, causing the server to reject the frame type and abort the connection.

## What Changed

- Dropped `triage-flatbuffers` from the advertised WebSocket protocols list inside `triage_websocket_client.dart`, forcing negotiation of `triage-json`.

## Decisions

- Limit the client's WebSocket subprotocol list to `['triage-json']` to prevent server negotiation of FlatBuffers until the client implements FlatBuffers serialization.

- [x] Modify `triage_websocket_client.dart` to drop FlatBuffers from offered protocols.
- [x] Verify that all client and daemon tests pass successfully.

## Commits

- HEAD — chore: drop flatbuffers subprotocol from client offered protocols
