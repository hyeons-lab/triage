# Zero-Downtime Daemon upgrades via Process Handover

## Thinking

1. **Objective:**
   We want the daemon `triaged` to be upgradable with true zero-downtime. This means:
   - Existing active shell PTY sessions are not terminated or killed.
   - The new daemon inherits/adopts the active PTYs and their descriptors.
   - The TCP listener socket is also passed, preventing "address in use" binding conflicts and dropped connections.
   - This premium feature is targeted specifically at Unix-like systems (Linux, WSL) via standard Unix domain socket `SCM_RIGHTS` descriptor passing. On native Windows, it falls back gracefully to standard Session Restore (spawning a new shell in the same directory and replaying history).

2. **The Handover Protocol:**
   To guarantee race-free concurrency where PTY reader threads do not overlap, we use a **Three-Phase Sync Protocol**:
   - **Phase 1 (Transfer):** New daemon starts with `--handover` (or connects to the existing active socket). The old daemon serializes session metadata (SessionId, SessionSize, Cwd, output sequence) to JSON and sends it over the Unix socket alongside raw descriptors (PTY Master and TCP listener sockets) using `SCM_RIGHTS`.
   - **Phase 2 (Adoption & Sync):** New daemon adopts the descriptors, parses the JSON state, uses `OutputState::replay` to reconstruct each session's virtual terminal screen and scrollback in memory, and writes `SYNC_ADOPTED` (`0x01`) back to the Unix socket.
   - **Phase 3 (Teardown & Exit):** Old daemon receives `0x01`, drops all internal PTY session references (terminating PTY reader threads and closing its copies of the descriptors), writes `SYNC_CLOSED` (`0x02`) back, unlinks its Unix socket file, and exits.
   - **Phase 4 (Activation):** New daemon receives `0x02` (or socket EOF), unlinks the Unix socket path and binds to it, spawns its own background PTY reader threads, and begins active supervision.
   - **Fail-Safe Timeout:** The old daemon runs a timeout (e.g. 5 seconds) during Phase 1. If the connection drops or times out before receiving `SYNC_ADOPTED`, it aborts the handover, resumes its active PTY reader loops, and continues supervising without interruption.

3. **Technical Implementations:**
   - **Unix File Descriptor Passing (`SCM_RIGHTS`):**
     We can use standard Rust crates or native platform bindings. Since Triage already has a Unix socket implementation in `crates/triaged/src/ipc.rs` using `tokio::net::UnixStream`, we can use `nix` or `sendmsg` / `recvmsg` from `tokio::net::UnixStream` via `std::os::unix::net::UnixStream` to pass descriptors.
     Let's see: we can cast `tokio::net::UnixStream` to `std::os::unix::net::UnixStream` via `into_std()` or `as_raw_fd()` and use `send_ancillary_data` / `recv_ancillary_data` from Rust's std library (`std::os::unix::net::AncillaryData` and `std::os::unix::net::SocketAncillary`), which natively supports `SCM_RIGHTS` (descriptor passing) out of the box on stable Rust since 1.54!
     This is exceptionally clean, standard, and requires ZERO external crates!
   - **PTY Adoption:**
     `portable_pty`'s Unix implementation typically uses a file descriptor for the PTY Master.
     We will write a platform-specific wrapper `AdoptedPtyMaster` that implements the `MasterPty` trait and standard `Read` / `Write` traits using the inherited file descriptor, or we can reconstruct a `PtyMaster` if `portable_pty` supports it. If not, implementing the `MasterPty` trait ourselves on Unix is extremely straightforward because a PTY Master is just an open file descriptor that supports standard read, write, and simple ioctl resizes (`TIOCSWINSZ`)!

## Plan

1. **Define CLI Options:**
   Modify `crates/triaged/src/main.rs` to parse `--handover` / `-U`.
2. **Implement Descriptor Passing (`SCM_RIGHTS`):**
   Create `crates/triaged/src/handover.rs` on Unix targets. Use Rust's standard `std::os::unix::net::SocketAncillary` and `AncillaryData::scm_rights` to send and receive raw file descriptors (PTY Master and TCP listener) over the Unix socket.
3. **Implement Session Serialization & Sync Protocol:**
   Update `crates/triaged/src/session.rs` to serialize active sessions and orchestrate the Three-Phase Sync Protocol on both sender and receiver sides.
4. **Implement PTY Descriptor Adoption:**
   In `crates/triaged/src/handover.rs`, implement `AdoptedPtyMaster` implementing the `MasterPty` and `Read` / `Write` traits using `RawFd` so it can be seamlessly passed into Triage's standard supervision pipeline.
5. **Add Automated Integration Test:**
   Add `crates/triaged/src/handover_tests.rs` to verify full handover execution, parent graceful teardown, and session continuity.
6. **Verify and Compile:**
   Verify with `cargo test --workspace`, format check, clippy checks, and prepare push.
