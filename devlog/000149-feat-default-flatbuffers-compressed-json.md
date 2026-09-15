# 000149: feat/default-flatbuffers-compressed-json

## Intent

Default to FlatBuffers binary protocol across the `triaged` daemon and Flutter client
for all WebSocket connections, only selecting JSON when explicitly negotiated via
`triage-json`. For JSON sessions, compress large snapshot payloads (specifically
`raw_output` via gzip and base64) at the field level to eliminate massive JSON arrays
and prevent session attach timeouts.

## Decisions

- 2026-09-15T11:42-0400: Default to FlatBuffers on both the server and client. When
  intermediate reverse proxies or load balancers strip `Sec-WebSocket-Protocol`,
  both sides will continue to use FlatBuffers instead of silently falling back to JSON.
- 2026-09-15T11:42-0400: Implement field-level compression for `SessionSnapshot.raw_output`
  using gzip and standard base64 encoding. Retain full backward compatibility in both
  Rust and Dart for uncompressed legacy integer arrays.
- 2026-09-15T11:42-0400: Use `package:archive` in Flutter to support gzip decompression
  across all platforms including Flutter Web without requiring `dart:io`.

## What Changed

2026-09-15T12:20-0400 Added `flate2` and `base64` dependencies to `crates/triage-core/Cargo.toml`
and declared `flate2 = "1"` in workspace dependencies in the root `Cargo.toml`.

2026-09-15T12:22-0400 Implemented `compressed_bytes` serde module in `crates/triage-core/src/session.rs`
annotating `SessionSnapshot.raw_output`. Compresses non-empty byte arrays with gzip and encodes
in base64 for JSON serialization. Deserialization accepts base64 strings (with gzip decompression
and raw base64 fallback) as well as legacy integer arrays via a sequence visitor. Added unit
tests verifying compression, empty payload, fallback, and legacy array deserialization.

2026-09-15T12:24-0400 Updated `handle_ws_upgrade` in `crates/triaged/src/http.rs` to default
the negotiated subprotocol to FlatBuffers. Only selects `ProtocolFormat::Json` when `triage-json`
is explicitly requested and `triage-flatbuffers` is absent. Updated default format in
`crates/triage-transport-ws/src/lib.rs` to `ProtocolFormat::Flatbuffers`. Added tests in
`crates/triaged/src/http_tests.rs` covering all subprotocol negotiation cases.

2026-09-15T12:25-0400 Added `archive: ^4.0.0` dependency to `flutter/triage_client/pubspec.yaml`.
Updated `TriageWebSocketClient.isFlatBuffersNegotiated` and `writeInput` to default to FlatBuffers
unless `triage-json` is explicitly negotiated. Implemented `rawOutputFromSnapshot` helper
supporting gzip decompression, uncompressed base64, and legacy integer list formats. Added
unit tests for negotiation defaults and snapshot decompression in `test/triage_websocket_client_test.dart`.

2026-09-15T13:35-0400 Hardened gzip decompression and protocol handling following local code review:
- Added RFC 1952 gzip magic byte check (`[0x1f, 0x8b]`) and bounded decompression ceiling (16 MiB via `.take(16 * 1024 * 1024 + 1)`) in `crates/triage-core/src/session.rs` to guard against zip bombs and avoid returning corrupted archives as raw terminal bytes.
- Switched compression to `Compression::fast()` with pre-allocated buffer sizing to minimize snapshot serialization latency.
- Added 16 MiB size guard and wrapped list element casting in `try / catch` in Flutter's `rawOutputFromSnapshot` to prevent unhandled `TypeError` crashes on malformed snapshot arrays.
- Removed fallthrough from FlatBuffers to JSON text frames in Flutter `_send` to ensure binary sockets never send invalid text frames to the daemon.
- Replaced heap allocations in `triaged/src/http.rs` subprotocol negotiation with single-pass token matching.
- Supported native raw byte buffers (`visit_bytes`, `visit_byte_buf`) and pre-allocated decompression capacity in `crates/triage-core/src/session.rs`.
- Added comprehensive unit tests in Rust and Dart for corrupted gzip stream rejection, oversized zip bomb defense, native byte buffer deserialization, and malformed list error handling.

## Commits

- f5ed488: feat(transport): default to flatbuffers and compress json snapshots
- 4595517: fix(transport): harden snapshot decompression and subprotocol handling
- HEAD: fix(core): add raw byte buffer support to snapshot deserializer

## Progress

- [x] Add `flate2` and `base64` dependencies to `crates/triage-core`
- [x] Implement `compressed_bytes` serde module for `SessionSnapshot.raw_output`
- [x] Add unit tests for `SessionSnapshot` compression and backward compatibility in `triage-core`
- [x] Update `triaged` WebSocket upgrade handler to default to FlatBuffers
- [x] Update `triage-transport-ws` default format to FlatBuffers
- [x] Add tests for FlatBuffers default negotiation in `triaged`
- [x] Update `flutter/triage_client` to default to FlatBuffers unless `triage-json` is negotiated
- [x] Add `archive` dependency and implement gzip base64 decompression in Flutter client
- [x] Add Flutter unit tests for snapshot decompression and protocol selection
- [x] Validate workspace formatting, lints, Rust tests, and Flutter tests
- [x] Execute Antigravity local review fix loop at max depth
- [x] Harden decompression bounding, corrupted stream defense, and text frame safety
