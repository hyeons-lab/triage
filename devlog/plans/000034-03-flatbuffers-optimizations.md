# Plan — FlatBuffers Protocol Optimizations

## Thinking
We need to implement two requested protocol optimizations on our branch `feat/flatbuffers-protocol`:

1. **Zero-Copy FlatBuffers Deserialization inside Rust `stress_client` and `triage-transport-ws`**:
   - Currently, `stress_client`'s `parse_fb_server_message` deserializes messages into an owned `ServerMessage` struct, which allocates `String`s, `Vec`s, etc.
   - We will define a new zero-copy lifetime-bound enum/struct `ServerMessageBorrowed<'a>` in `triage-transport-ws` (re-exporting it or housing it in `flatbuffers_proto.rs`).
   - We will implement a `parse_fb_server_message_borrowed<'a>(&'a [u8]) -> Result<ServerMessageBorrowed<'a>, ProtocolError>` helper.
   - This new type will borrow fields directly from the underlying WebSocket frame's binary buffer (e.g. using `&'a str` instead of `String`).
   - We will update the `stress_client.rs` binary to use `ServerMessageBorrowed<'a>` for parsing and zero-copy validation during the handshake, list, and event verification steps.

2. **FlatBuffers Integration inside the Flutter remote TUI client**:
   - We have already successfully compiled `triage.fbs` into Dart inside `flutter/triage_client/lib/generated/triage_triage.generated_generated.dart`.
   - We added the `flat_buffers: ^23.5.26` dependency to the Flutter client.
   - Now we need to modify `triage_websocket_client.dart` to:
     - Advertise the subprotocols `["triage-flatbuffers", "triage-json"]` during standard WebSocket handshake.
     - Detect binary frames and dynamically deserialize them using the generated Dart FlatBuffers bindings (`triage.generated.ServerMessage`).
     - Map the FlatBuffers results to standard Dart `Map<String, dynamic>` maps inside `_handleIncomingMessage` to preserve clean compatibility with the UI layer (`main.dart`), avoiding any breaking refactoring of UI components.
     - Fall back to standard JSON parsing when `triage-json` is negotiated by the daemon.

Let's verify that both changes compile, tests pass, and performance E2E works cleanly.

## Plan
- [ ] Create `ServerMessageBorrowed<'a>` and related borrowed types in `crates/triage-transport-ws/src/flatbuffers_proto.rs` or `lib.rs`.
- [ ] Implement zero-copy parsing functions: `parse_fb_server_message_borrowed` in `triage-transport-ws`.
- [ ] Refactor `stress_client.rs` to use `parse_fb_server_message_borrowed` and borrow directly from the binary frame instead of allocating owned structures.
- [ ] Update `triage_websocket_client.dart` to negotiate `triage-flatbuffers` subprotocol.
- [ ] Implement binary frame parsing in Dart: decode binary frame messages to Dart structures using FlatBuffers generated classes.
- [ ] Validate and verify everything compiles successfully in Rust (`cargo check` and `cargo test`) and Flutter (`flutter test` and `flutter build web`).
