# 000149-01 default flatbuffers compressed json

## Thinking

When connecting to a remote `triaged` daemon, intermediate reverse proxies, tunnels,
and cloud load balancers (e.g. Nginx, Caddy, Traefik, Cloudflare, AWS ALB) frequently
strip or fail to preserve the `Sec-WebSocket-Protocol` header during the RFC 6455
WebSocket upgrade handshake.

Today, this causes two critical failure modes:
1. **Fallback to JSON instead of FlatBuffers:**
   - In `crates/triaged/src/http.rs`, `selected_format` initializes to `ProtocolFormat::Json`.
     If `Sec-WebSocket-Protocol` is missing or stripped, the daemon defaults to JSON.
   - In `flutter/triage_client/lib/services/triage_websocket_client.dart`, `isFlatBuffersNegotiated`
     checks `_channel?.protocol == flatBuffersSubprotocol`. If the proxy strips the response
     header, `_channel?.protocol` is empty string (`""`), so the client also defaults to JSON.
   - Even though both sides support FlatBuffers, a stripped header silently degrades the
     entire connection to JSON.
2. **Connection timeouts on large JSON payloads:**
   - On session attach (`attach_session`), the daemon sends `AttachSessionResponse` containing
     `SessionSnapshot`.
   - `SessionSnapshot` contains `raw_output: Vec<u8>` (raw PTY scrollback history). In JSON,
     `serde_json` serializes `Vec<u8>` as an array of individual integer numbers (`[27, 91, 51, ...]`).
     A 500 KB raw terminal log expands into several megabytes of comma-separated numeric tokens.
   - Parsing hundreds of thousands of JSON tokens in the single-threaded Dart client blocks
     execution and exceeds the 10-second `requestTimeout`, breaking remote session attachment.

To solve this:
1. **Default to FlatBuffers everywhere:**
   - The daemon must default to `ProtocolFormat::Flatbuffers` when no subprotocol header is
     provided. It should only select `ProtocolFormat::Json` if the client explicitly requested
     `triage-json` and omitted `triage-flatbuffers`.
   - The client must default to FlatBuffers unless the server explicitly negotiated `triage-json`
     (`_channel?.protocol == jsonSubprotocol`).
2. **Field-level snapshot compression for JSON:**
   - In `SessionSnapshot`, `raw_output` must be compressed with gzip and encoded in base64 when
     serialized to JSON.
   - Deserialization in Rust must support both the compressed base64 string format and legacy
     integer arrays for backwards compatibility.
   - In Flutter, `_rawOutputFromSnapshot` must decode base64 and decompress gzip when `raw_output`
     is a string, while retaining backwards compatibility for `Uint8List` and `List<dynamic>`.
   - Add `archive` package to `flutter/triage_client/pubspec.yaml` so gzip decompression works
     consistently across both native platforms and Flutter Web.

## Plan

1. **Rust Core (`crates/triage-core`):**
   - Add `flate2.workspace = true` and `base64.workspace = true` to `crates/triage-core/Cargo.toml`.
   - Ensure `flate2 = "1"` is declared in workspace dependencies in the root `Cargo.toml`.
   - In `crates/triage-core/src/session.rs`, add a serde helper module `compressed_bytes` for
     `raw_output`:
     - Serialization: If empty, serialize as empty string `""`. Otherwise, compress with gzip
       (`flate2::write::GzEncoder`) and encode with standard base64.
     - Deserialization: Accept either a base64 string (with gzip decompression, falling back to
       raw base64 bytes if uncompressed) or an integer sequence (`visit_seq`) for legacy payloads.
   - Add comprehensive unit tests in `crates/triage-core/src/session.rs` testing compression,
     decompression, empty payload handling, and legacy integer array backward compatibility.

2. **Rust Daemon & Transport (`crates/triaged`, `crates/triage-transport-ws`):**
   - In `crates/triaged/src/http.rs`:
     - Update `handle_ws_upgrade` subprotocol negotiation: default `selected_format` to
       `ProtocolFormat::Flatbuffers`.
     - Check requested tokens: if `triage-flatbuffers` is present, select `ProtocolFormat::Flatbuffers`
       and return `Sec-WebSocket-Protocol: triage-flatbuffers`.
     - Only if `triage-json` is present and `triage-flatbuffers` is absent, select
       `ProtocolFormat::Json` and return `Sec-WebSocket-Protocol: triage-json`.
     - If no subprotocol was requested, default format is `ProtocolFormat::Flatbuffers` with no
       response header (per RFC 6455).
   - In `crates/triage-transport-ws/src/lib.rs`:
     - Update default format in `WebSocketSessionConnection::new` and `with_authenticator` to
       `ProtocolFormat::Flatbuffers`.
   - Add tests verifying the inverted subprotocol negotiation rules in `crates/triaged/src/http_tests.rs`
     or `crates/triaged/src/ws.rs`.

3. **Flutter Client (`flutter/triage_client`):**
   - In `flutter/triage_client/pubspec.yaml`:
     - Add `archive: ^4.0.0` to `dependencies:`.
   - In `flutter/triage_client/lib/services/triage_websocket_client.dart`:
     - Update `isFlatBuffersNegotiated`:
       `bool get isFlatBuffersNegotiated => _channel?.protocol != jsonSubprotocol;`
     - Update `writeInput` check:
       `final isFb = channel.protocol != jsonSubprotocol;`
   - In `flutter/triage_client/lib/main.dart`:
     - In `_rawOutputFromSnapshot`, check if `raw is String`: base64-decode and decompress with
       `GZipDecoder().decodeBytes(...)`.
   - In `flutter/triage_client/test/triage_websocket_client_test.dart` and widget tests:
     - Add unit tests for `_rawOutputFromSnapshot` with compressed strings, uncompressed fallback,
       and legacy number lists.
     - Update transport tests to verify that omitting `Sec-WebSocket-Protocol` defaults to FlatBuffers.

4. **Validation:**
   - Run `cargo fmt --all -- --check`.
   - Run `cargo clippy --all-targets --all-features -- -D warnings`.
   - Run `cargo test --workspace`.
   - Run `flutter test` in `flutter/triage_client`.
   - Update branch devlog with all changes, decisions, and commit info.
