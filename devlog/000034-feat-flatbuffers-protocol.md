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
- [x] Implement conversion helpers in `flatbuffers_proto.rs` in `triage-core`.
- [x] Refactor `triage-transport-ws` to support `ProtocolFormat` and binary message handlers.
- [x] Refactor `triaged` to negotiate subprotocols and route binary WebSocket frames.
- [x] Implement Criterion microbenchmarks inside `crates/triage-transport-ws/benches/`.
- [x] Implement standalone E2E stress testing tool (`crates/triage-transport-ws/src/bin/stress_client.rs`).
- [x] Verify functionality via automated unit and integration tests.

## Decisions
- Require `flatc` to be installed globally on developers' systems instead of checking in generated files.
- Adopt standard RFC 6455 subprotocol negotiation to avoid query parameters and match industry conventions.
- Explicitly set `listener.set_nonblocking(true)` in the HTTP + WebSocket server's Tokio adapter to prevent blocking TCP accept deadlocks on Windows systems.
- Nested lints like `collapsible-if` and `redundant-closure` were fixed inside `triage-core` compilation targets to ensure zero linter warnings.

## Commits
- HEAD — fix(client): increase minimum terminal column clamp to 80 to prevent prompt wrapping
- 927e384 — fix(client): resolve transient narrow terminal sizing and E2E build embedding
- 43e6c07 — refactor(flatbuffers): address PR review comments, implement safe fallible parsing, and compliant subprotocol negotiation
- c0b8469 — ci: install flatc compiler dependency in CI workflows for Linux, macOS, and Windows
- 4e6559c — refactor(flatbuffers): output generated bindings to OUT_DIR and remove tracked generated file
- 9a0a0f5 — feat(flatbuffers): implement Criterion benchmarks, E2E stress testing tool, and fix Windows socket hang
- b03b3bc — feat(flatbuffers): implement subprotocol negotiation and binary frame routing inside triaged daemon
- 4305355 — feat(flatbuffers): implement FlatBuffers adapter inside triage-transport-ws
- 11f1a34 — feat(flatbuffers): implement FlatBuffers schema compilation and core model builders
- 9481a9a — dev(web): initialize branch devlog and plan for FlatBuffers protocol
