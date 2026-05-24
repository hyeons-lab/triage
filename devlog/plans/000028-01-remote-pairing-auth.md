# 000028-01-remote-pairing-auth

## Thinking
We need to design a cryptographically secure, user-friendly remote pairing flow for Triage daemon WebSocket connections, ensuring unauthenticated network access is securely blocked by default.

Key sequence of components:
1. Extend WebSocket protocol request/response messages in `triage-transport-ws` and `triage-core`:
   - `ClientRequest::Hello` accepts optional `token: Option<String>`.
   - `ClientRequest::Pair { code: String, client_id: ClientId }`.
   - `ServerResult::Hello { protocol_version: String, authenticated: bool }`.
   - `ServerResult::Paired { token: String }`.
2. Model a stateful `WebSocketSessionConnection` inside `triage-transport-ws` that tracks whether a connection has successfully authenticated, rejecting other requests with an `unauthorized` protocol error when unauthenticated.
3. In `triaged::session::SessionManager`, implement:
   - In-memory pairing code validation (with short-lived expiry e.g. 5 minutes).
   - Local state file `pairing_code.json` containing the pairing PIN and daemon host address, permitting secure, cross-platform CLI reads (on Unix and Windows).
   - Local device pairing database (`paired_devices.json` in `log_dir`) to persist SHA-256 hashes of client bearer tokens alongside their `ClientId`.
   - Generation of random 32-byte cryptographically secure tokens using `rand`.
4. Wrap in-daemon TLS capabilities to a future milestone. Rely on Tailscale, WireGuard, or reverse proxies to securely encapsulate connection traffic, keeping daemon code lightweight and 100% cross-platform.
5. In the `triage` CLI, add a `triage pair` command that reads the secure `pairing_code.json` file and displays the 6-digit PIN in the terminal.
6. In `triage_client` (Flutter), add a pairing interface prompting for the PIN, and persist the acquired token in secure local storage.

## Plan

### Phase 1: Protocol and Message Structures
- Add `rand` and `hex` to workspace dependencies.
- Update `triage-core` session structures to handle pairing requests.
- Add `Pair` and `Hello` message extensions in `triage-transport-ws`.
- Add unit tests verifying serialization and deserialization of the new message variants.

### Phase 2: Transport Security State Machine
- Enforce the connection authentication state in `WebSocketSessionConnection`.
- Return `unauthorized` error blocks for non-hello, non-pairing requests when unauthenticated.
- Verify behavior with focused transport-level unit tests.

### Phase 3: Daemon Pairing Storage & Management
- Implement transient pairing code generation in `SessionManager`.
- Write active pairing codes to secure local `pairing_code.json` files for CLI reading.
- Implement persistence for paired devices in a `paired_devices.json` file.
- Secure token validation by storing token hashes (SHA-256) rather than plaintext tokens.
- Add unit tests for registration, persistence recovery, and validation.

### Phase 4: CLI pairing UX
- Implement the local `triage pair` command that parses `pairing_code.json` and prints the PIN block.

### Phase 5: Client pairing UX (Flutter)
- Prompt users with a pairing setup view in the Flutter web client if the device has not been paired.
- Store the returned token securely and apply it to subsequent handshakes.
