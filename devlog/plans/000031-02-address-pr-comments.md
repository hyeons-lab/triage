# Address PR comments on Zero-Downtime Process Handover

## Thinking

1. **Objective:**
   Address the two major PR comments on our zero-downtime process handover implementation:
   - **Serialization Failure Recovery Vulnerability:** Currently `serialize_active_sessions()` removes sessions from the map and stops actor loops before handshake confirmation. If the new daemon disconnects or fails to adopt during Phase 2, the old daemon aborts the handover but has lost all its active session supervisions. We should keep actors running in Phase 1 & 2, and cleanly shut them down only in Phase 3 after `0x01` adoption sync is received.
   - **SCM_RIGHTS Passing Hardening:** SCM_RIGHTS `sendmsg`/`recvmsg` was treated as all-or-nothing, which risks short write and payload truncation (with a fixed 64KiB buffer limit). We should pass the FDs and a 4-byte big-endian JSON length prefix in the ancillary `sendmsg`/`recvmsg` message, and then reliably read/write the full JSON data payload using standard socket stream `read_exact` and `write_all`.

2. **Refactoring Steps:**
   - **session.rs**:
     - Change `serialize_active_sessions()` to iterate and extract state using `ActorCommand::ExtractHandoverState` without calling `sessions.remove(&id)` or `actor.join_threads()`.
     - Update `ActorCommand::ExtractHandoverState` handling in `handle_command()` to return `false` instead of `true` so the command processing loop keeps running.
     - Update `clear_all_live_sessions()` to explicitly send `ActorCommand::Shutdown` and call `join_threads()` for each active session actor to ensure a clean Phase 3 teardown.
   - **handover.rs**:
     - Update `send_fds(socket, fds, data)`: pack `(data.len() as u32).to_be_bytes()` as a 4-byte prefix, send prefix and FDs via `sendmsg`, and then send the actual `data` bytes via `socket.write_all(data)`.
     - Update `recv_fds(socket, max_fds)`: read a 4-byte length prefix and FDs via `recvmsg`, parse length, dynamically allocate `vec![0u8; data_len]`, and read exactly `data_len` bytes via `socket.read_exact(&mut data_buf)`.
     - Adjust `perform_handover_client()` to consume the new `(Vec<u8>, Vec<RawFd>)` return type.
   - **ipc.rs**:
     - Adjust `handle_handover_server()` to use the refactored `clear_all_live_sessions()`.

## Plan

1. **Modify `crates/triaged/src/session.rs`**:
   - Change `ActorCommand::ExtractHandoverState` return value to `false`.
   - Update `serialize_active_sessions()` to iterate via `.iter()` and keep sessions in the map.
   - Implement clean explicit teardown in `clear_all_live_sessions()`.
2. **Modify `crates/triaged/src/handover.rs`**:
   - Rewrite `send_fds()` to pack the 4-byte big-endian length prefix and call `write_all()`.
   - Rewrite `recv_fds()` to read 4-byte length prefix first, then `read_exact()` for the rest.
   - Update `perform_handover_client()` signature matching.
3. **Verify compile and run tests**:
   - `cargo check --workspace`
   - `cargo test --workspace`
   - `cargo clippy --all-targets --all-features -- -D warnings`
