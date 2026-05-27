# Plan — Address PR #41 Review Comments

## Thinking
To address all 18 review comments left on the PR, we will implement the following structured fixes:
1. **Fallible parsing and panic elimination in FlatBuffers client messages**: Make `parse_client_message` return a `Result<ClientMessage, ProtocolError>`. Avoid `unwrap()` on untrusted data. Validate all fields and return error responses instead of panicking or defaulting to unrelated commands.
2. **Scoping `triage-transport-ws` Cargo dependencies**: Introduce a `stress-client` feature gating optional dependencies (`tokio`, `tokio-tungstenite`, `futures-util`).
3. **Fancier and compliant subprotocol negotiation**: Parse the client offered protocols as exact comma-separated trimmed tokens, respecting client preference order.
4. **Mismatched frame error handling**: Send a structured protocol error back to the client if they send text frames over a flatbuffers connection or binary frames over a JSON connection.
5. **Downgrade INFO logs to DEBUG**: Change high-frequency WS request/connection logging to `tracing::debug!`.
6. **Optional Colors Presence Flags**: Store presence boolean flags `has_foreground` and `has_background` inside `TerminalStyle` struct to preserve defaulting semantics vs explicit black (0,0,0).
7. **Pacing rate validation**: Validate rate > 0 and clamp duration interval to avoid panic inside `stress_client.rs`.
8. **Unit tests for FlatBuffers message loop**: Add tests inside `triage-transport-ws` verifying round-trip and error handling in `handle_binary_message`.

## Plan
- [ ] Update `triage.fbs` schema to add `has_foreground: bool` and `has_background: bool` inside `TerminalStyle` struct.
- [ ] Update `crates/triage-core/src/flatbuffers_proto.rs` to set the presence flags based on whether color is `Some`.
- [ ] Refactor `crates/triage-transport-ws/src/flatbuffers_proto.rs` to make `parse_client_message` return a `Result<ClientMessage, ProtocolError>`. Avoid all untrusted `unwrap()`s and handle optional fields.
- [ ] Update `crates/triaged/src/ws.rs` and `stress_client.rs` to propagate the new `Result` parsing format correctly.
- [ ] Scope `stress-client` dependencies in `crates/triage-transport-ws/Cargo.toml` as optional and gate the `stress_client` bin behind the `"stress-client"` feature.
- [ ] Refactor subprotocol negotiation in `crates/triaged/src/http.rs` to parse list tokens and match exactly, respecting preference.
- [ ] Add mismatched frame type errors inside `crates/triaged/src/ws.rs`.
- [ ] Downgrade high-frequency logs to `tracing::debug!` inside `crates/triaged/src/ws.rs` and `http.rs`.
- [ ] Add rate input validation and clamp rates inside `crates/triage-transport-ws/src/bin/stress_client.rs`.
- [ ] Add FlatBuffers unit tests inside `crates/triage-transport-ws/src/lib.rs` for `handle_binary_message`.
- [ ] Verify everything compiles, lint checks pass, and tests execute correctly locally.
