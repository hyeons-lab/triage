# Suppress JSON broken pipe warning

## Thinking

The daemon warning shows a client disconnect while writing a one-shot Unix socket response:

`writing response -> encoding JSON line -> Broken pipe`.

The existing `is_closed_socket_error` helper suppresses direct `std::io::Error` roots for subscription flushes, but `serde_json::to_writer` can surface the same broken pipe as a `serde_json::Error` with an I/O kind. That should still be treated as an expected client disconnect, not a daemon warning.

## Plan

1. Update `crates/argus-daemon/src/ipc.rs` so closed-socket detection recognizes both direct `std::io::Error` causes and `serde_json::Error` causes carrying closed socket I/O kinds.
2. Add regression coverage for the JSON encoding broken-pipe shape from the observed warning while keeping the string-only false-positive test.
3. Run the daemon IPC tests and format check.
