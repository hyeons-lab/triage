# Plan — Configurable Binary FlatBuffers Protocol for Triage

## Thinking
To dramatically reduce network payload sizes and eliminate CPU parsing and garbage collection bottlenecks in the Triage terminal output stream, we will implement a configurable FlatBuffers binary protocol.
We will negotiate the serialization format dynamically on a per-connection basis using RFC 6455 subprotocol negotiation.
This allows JSON and FlatBuffers clients to run simultaneously on the same TCP port.
To compile the FlatBuffers schema, we will add a Cargo build-time step that calls `flatc` and fails if it is not installed on the system path, as requested.
To guarantee maximum reliability and quantitatively prove the performance improvements, we will add a complete multi-tier benchmarking suite, including Rust Criterion microbenchmarks and a standalone E2E stress testing tool.

## Plan
1. **Define Schema**:
   Create `crates/triage-core/schema/triage.fbs` defining all core structures, requests, events, and envelopes.
2. **Build Configuration**:
   Update `crates/triage-core/Cargo.toml` with `flatbuffers` and add `build.rs` to invoke `flatc`.
3. **Rust Bindings Helper**:
   Create `crates/triage-core/src/flatbuffers_proto.rs` to handle conversion helpers.
4. **WebSocket Transport Support**:
   Update `crates/triage-transport-ws` to expose `ProtocolFormat` and implement binary frame deserializers/serializers.
5. **Hyper Routing Negotiation**:
   Update `crates/triaged/src/http.rs` to check the `Sec-WebSocket-Protocol` header and choose/return the correct subprotocol.
6. **Daemon WebSocket Upgrades**:
   Update `crates/triaged/src/ws.rs` to read/write binary WebSocket frames when using the FlatBuffers protocol.
7. **Criterion Microbenchmarks**:
   Add `crates/triage-transport-ws/benches/` microbenchmarks using Criterion to test JSON vs. FlatBuffers performance.
8. **E2E Stress Testing Tool**:
   Add `crates/triage-transport-ws/src/bin/stress_client.rs` to perform high-throughput network benchmarks.
9. **Verification and Testing**:
   Ensure all cargo checks, clippy warnings, and test suites pass cleanly.
