# Fix Handover Socket Buffer EMSGSIZE and Add Legacy Protocol Fallback

## Thinking

During daemon handover on macOS (Darwin), executing `triaged reload` failed with:
`IPC client handler failed: sending handover state and FDs via SCM_RIGHTS: Caused by: Message too long (os error 40)`.

Investigation into Darwin XNU socket buffer mechanics revealed the following:
1. Unix domain stream sockets on Darwin have default `SO_SNDBUF = 8192` bytes and `SO_RCVBUF = 8192` bytes.
2. In `HandoverV2`, the server calls `send_data_frame(&stream, &response_bytes)` followed immediately by `send_fd_chunks(&stream, &fds_to_send.0)`.
3. With 29 live sessions, serialized `HandoverState` is ~10 KB. When `send_data_frame` writes data into an 8 KB socket buffer, the unread bytes fill or nearly fill the kernel buffer.
4. On Darwin XNU, `sendmsg` with control data (`SCM_RIGHTS`) checks whether `so_snd.sb_cc + clen > so_snd.sb_hiwat`. If the remaining buffer space is smaller than the control message buffer, `sendmsg` fails immediately with `EMSGSIZE` (`os error 40`), even when the socket is blocking!
5. When `send_fd_chunks` fails on the server with `EMSGSIZE`, the server drops the client connection. On the client side, `recv_remaining_fds` fails with EOF or closed socket while `fds.is_empty()` is true.
6. Currently, the client only falls back to legacy `Handover` if `recv_data_frame` fails. But because `recv_data_frame` succeeded, the failure in `recv_remaining_fds` caused the client to abort handover and attempt a fresh bind, which failed because the old daemon (PID 30413) was still running.
7. In the legacy protocol (`{"Handover":null}`), `send_handover_fds` calls `send_initial_frame`, which sends descriptors via `sendmsg` *first* while the send buffer is completely empty (0 bytes used), and only then streams the state bytes. This avoids `EMSGSIZE` entirely.
8. The existing running daemon (PID 30413) supports both `Handover` and `HandoverV2`. Because its handler for the failed `HandoverV2` request dropped its lock cleanly, PID 30413 remains healthy and will gladly accept a `Handover` request.

To permanently resolve this and ensure clean zero-downtime handovers:
1. In `crates/triaged/src/handover.rs`:
   - Add `configure_unix_stream(stream: &UnixStream)` that sets `SO_SNDBUF` and `SO_RCVBUF` to 2 MiB (`2 * 1024 * 1024`) on Unix.
   - Call `configure_unix_stream` in `connect` and throughout handover socket establishment.
   - In `perform_handover_client`: if `metadata_first` is true and `recv_remaining_fds` fails when `fds.is_empty()`, catch the error and fall back to the legacy `Handover` request (`{"Handover":null}\n`). Re-connect and receive via `recv_fds_guarded`, ensuring compatibility with existing daemons running with default 8 KB buffers.
   - In `handover_owner_blocks_adoption`: apply the same fallback if `received_fds.is_empty()`.
2. In `crates/triaged/src/ipc.rs`:
   - In the Unix listener accept loop, call `configure_unix_stream(&stream)` so accepted connections have 2 MiB buffer space.
3. Validate with unit tests and ensure all workspace tests pass.
4. Build release binary, install to `~/.cargo/bin/triaged` with ad-hoc signing, and execute `~/.cargo/bin/triaged reload`. Verify the zero-downtime handover in `$HOME/.local/state/triage/triaged.log`.

## Plan

1. In `crates/triaged/src/handover.rs`:
   - Implement `configure_unix_stream(stream: &UnixStream)`.
   - Call `configure_unix_stream` in `connect`, `handover_owner_blocks_adoption`, and related helpers.
   - Update `perform_handover_client` so that if `recv_remaining_fds` fails while `fds.is_empty()` during a `metadata_first` attempt, it logs a warning and falls back to connecting with `b"{\"Handover\":null}\n"` via `recv_fds_guarded`.
   - Update `handover_owner_blocks_adoption` with matching fallback.
2. In `crates/triaged/src/ipc.rs`:
   - In `serve()`, call `configure_unix_stream(&stream)` on accepted Unix stream sockets.
3. Verify test suite:
   - Run `cargo test -p triaged`.
   - Run `cargo test --workspace`.
   - Run `cargo fmt --all -- --check` and `cargo clippy --all-targets --all-features -- -D warnings`.
4. Devlog & Git commit:
   - Update `devlog/000147-fix-session-resume-render-refit.md`.
   - Update previous HEAD commit hash and set new commit as HEAD.
   - Commit changes with Conventional Commit format.
5. Deployment & Zero-Downtime Reload:
   - Run `cargo build --release -p triaged`.
   - Install binary: `cp target/release/triaged ~/.cargo/bin/triaged`.
   - Re-sign binary: `codesign -s - -f ~/.cargo/bin/triaged`.
   - Execute reload: `~/.cargo/bin/triaged reload` with 10s wait.
   - Inspect `$HOME/.local/state/triage/triaged.log` to confirm adoption sync and clean teardown.
