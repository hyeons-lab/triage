# Devlog — feat/flatbuffers-protocol

## Agent
- **Name**: Antigravity (Gemini 3.5 Flash)
- **Role**: AI Software Engineer Pair

## Intent
Implement a high-performance binary serialization protocol for the Triage WebSocket API using FlatBuffers. Support standard RFC 6455 subprotocol negotiation (`triage-flatbuffers` vs `triage-json`) so both protocols can run concurrently on the same port. Require the global FlatBuffers compiler (`flatc`) for builds, and add thorough Criterion serialization/deserialization microbenchmarks and E2E stress testing.

## Progress
- [x] Create branch devlog and initial plan file.
- [x] Define the FlatBuffers schema (`triage.fbs`) inside `triage-core`.
- [x] Add `flatbuffers` dependencies and implement build script in `triage-core/build.rs`.
- [ ] Implement conversion helpers in `flatbuffers_proto.rs` in `triage-core`.
- [ ] Refactor `triage-transport-ws` to support `ProtocolFormat` and binary message handlers.
- [ ] Refactor `triaged` to negotiate subprotocols and route binary WebSocket frames.
- [ ] Implement Criterion microbenchmarks inside `crates/triage-transport-ws/benches/`.
- [ ] Implement standalone E2E stress test client inside `crates/triage-transport-ws/src/bin/stress_client.rs`.
- [ ] Update Flutter web client to compile and support FlatBuffers serialization.
- [ ] Verify functionality via automated unit and integration tests.

## Decisions
- Require `flatc` to be installed globally on developers' systems instead of checking in generated files.
- Adopt standard RFC 6455 subprotocol negotiation to avoid query parameters and match industry conventions.

## Next Steps
- Implement the FlatBuffers schema file.

## Commits
- HEAD — dev(web): initialize branch devlog and plan for FlatBuffers protocol
