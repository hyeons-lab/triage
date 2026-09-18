# Plan: Secure CLI Pairing Flow and Multi-User Verification

## Thinking

The HTTP `/pair` endpoint in `triaged` exposed a web route for approving device pairing requests. On multi-user systems, binding an unauthenticated HTTP endpoint to loopback or local network addresses allows any local user or network actor with access to the port to approve device pairing codes or manipulate pairing state without proving system identity. Even Tailscale whois authorization cannot distinguish between different Unix users executing commands or browsing on the same host machine.

The robust solution is:
1. Remove the HTTP `/pair` web endpoint and its server-rendered HTML pages from `triaged`.
2. Move device code approval to a dedicated CLI command: `triage pair <DEVICE_CODE>` (or interactive prompt when the code is omitted).
3. Enforce multi-user security over the local IPC channel (`triage.sock` / Named Pipe):
   - On Unix, enforce strict socket permissions (`0o700` parent directory, `0o600` socket).
   - In addition to filesystem permissions, verify peer credentials on incoming IPC connections using kernel-authenticated peer UID (`libc::getpeereid` on macOS/BSD, `SO_PEERCRED` on Linux). Connections originating from a peer UID different from the running daemon's effective UID are immediately rejected.
4. Update the Flutter web and client UI:
   - Retain the PIN entry input and challenge lifecycle.
   - Replace `/pair` URL links and instructions with the exact CLI command to run on the daemon host: `triage pair <DEVICE_CODE>`.
   - Provide a one-click copy button for the CLI command, as well as for the device code.
5. Clean up obsolete Tailscale whois pair approval logic that existed solely to protect the now-removed `/pair` HTTP route, and update documentation and tests.

## Plan

1. **Daemon IPC Protocol and Multi-User Security (`crates/triaged/src/ipc.rs`, `crates/triaged/src/session.rs`)**:
   - Add `Serialize, Deserialize, PartialEq, Eq` to `PairingPinInfo` in `crates/triaged/src/session.rs`.
   - Add `WireRequest::ApprovePairingDeviceCode { device_code: String }` to `WireRequest`.
   - Add `WireSuccess::PairingPin(PairingPinInfo)` to `WireSuccess`.
   - In `handle_request`, handle `WireRequest::ApprovePairingDeviceCode` by delegating to `manager.approve_pairing_device_code(&device_code)`.
   - Add `IpcClient::approve_pairing_device_code(&self, device_code: &str) -> Result<PairingPinInfo>`.
   - On Unix, implement `peer_euid(&UnixStream) -> Result<u32>` using `libc::getpeereid` on macOS/BSD and `SO_PEERCRED` on Linux.
   - At the beginning of `handle_connection` on Unix, check `peer_euid(&stream) == libc::geteuid()`. If mismatched, reject the connection with an unauthorized peer UID error.

2. **Remove HTTP `/pair` Route and Tailscale Authorizer (`crates/triaged/src/http.rs`, `crates/triaged/src/ws.rs`)**:
   - In `crates/triaged/src/http.rs`:
     - Remove the `/pair` and `/pair/` route dispatch from `serve_http`.
     - Remove `pairing_page_response`, `render_pairing_form_page`, `render_pairing_pin_page`, `render_pairing_error_page`, and associated HTML rendering helpers.
     - Simplify `serve_http` signature by removing the unused `authorize_pairing` closure parameter.
   - In `crates/triaged/src/ws.rs`:
     - Remove `PairApproval`, `CachedLogin`, `allow_pairing_approval_with_resolver`, `tailscale_whois_login`, and whois cache machinery.
     - Simplify `start_listener` to remove the unneeded pairing approval parameters.
     - Update call sites in `crates/triaged/src/main.rs`.
   - In `crates/triaged/src/http_tests.rs`:
     - Remove obsolete tests verifying the HTML `/pair` web page.
     - Update `serve_http` test invocations to match the simplified signature.

3. **CLI Pair Command (`crates/triage/src/main.rs`)**:
   - Update `StartupMode` to accept `StartupMode::Pair { socket_path: Option<PathBuf>, device_code: Option<String> }`.
   - Support `triage pair <DEVICE_CODE>` and allow `--socket <path>`.
   - In `run_pair`:
     - If `device_code` is not passed as an argument, prompt interactively on stdin.
     - Connect to `IpcClient::new(socket_path)`.
     - Call `client.approve_pairing_device_code(&code)`.
     - Print the approved PIN and remaining expiration time cleanly.
   - Update `triage --help` text to document `triage pair [device-code]`.

4. **Flutter Client Pairing UI (`flutter/triage_client/lib/main.dart`)**:
   - Remove obsolete `_pairingVerificationUri` and `_pairingDaemonHostUri` helpers.
   - In `_PairingView`, show:
     - Clear instructions: "To pair this device, run this command on the machine running triaged:".
     - Code block / container showing `triage pair <DEVICE_CODE>` with a "Copy command" button.
     - Device Code tile with a "Copy code" button.
     - Expiry label (e.g. "Expires at 10:25").
     - PIN entry text field and "Pair Device" button.
   - Update widget tests in `flutter/triage_client/test/widget_test.dart` to verify the new CLI command display and copy interaction.

5. **Validation and Verification**:
   - Run `cargo test --workspace`.
   - Run `flutter test` and `flutter analyze`.
   - Run `cargo clippy --all-targets --all-features -- -D warnings`.
   - Run `cargo fmt --all -- --check`.
