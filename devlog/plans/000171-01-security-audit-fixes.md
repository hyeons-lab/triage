# Plan: 000171-01-security-audit-fixes

## Thinking

Following the security audit of the HTTP session history branch (`feat/http-session-history`) and surrounding daemon/transport/client code, we need to remediate the identified vulnerabilities:

1. **Path Traversal in `WebAssetCache::load_override_file` (`crates/triaged/src/http.rs`)**:
   - `load_override_file` previously used `path.replace("..", "")`, which is non-recursive and collapses `....//` into `../`. Because static asset serving is unauthenticated, an attacker could traverse out of `override_dir` (`~/.local/share/triage/web`) and read arbitrary files owned by the daemon user.
   - We should percent-decode the asset path, reject backslashes and NUL bytes, validate that every `std::path::Path::components()` entry is `Component::Normal`, and verify via `std::fs::canonicalize` that the resolved file starts with the canonical `override_dir`.

2. **Cross-Origin / CSWSH Protection When `require_pairing = false` (`crates/triaged/src/http.rs`)**:
   - When `require_pairing = false`, neither `/ws` nor `GET /api/sessions/{id}/history` requires bearer credentials. Without `Origin` validation, any malicious webpage visited by the user can hijack `/ws` or read session history cross-origin via `Access-Control-Allow-Origin: *`.
   - When `require_pairing = false`, validate any present `Origin` header on `/ws` and `/api/sessions/{id}/history` so only loopback origins (`localhost`, `127.0.0.1`, `[::1]`) or origins matching the `Host` header are permitted, and omit wildcard CORS headers when `require_pairing = false`.

3. **Unauthenticated WebSocket Resource Hardening (`crates/triaged/src/http.rs`, `crates/triaged/src/ws.rs`, `crates/triage-transport-ws/src/lib.rs`)**:
   - Pass an explicit `WebSocketConfig` (`max_message_size: Some(4 * 1024 * 1024)`, `max_frame_size: Some(1024 * 1024)`) to `WebSocketStream::from_raw_socket` instead of `None` (64 MiB default).
   - Defer `manager.register_global_receiver()` until `conn.is_authenticated()` becomes true so unauthenticated idle WebSocket connections cannot accumulate undrained `SyncSender` channels in `manager.global_senders`.

4. **Brute-Force Attempt Limit on Pairing PIN Verification & Constant-Time Comparison (`crates/triaged/src/session.rs`)**:
   - Add a `failed_attempts` counter to `PendingPairingPin` and invalidate `challenge.pin` once `MAX_PAIRING_PIN_ATTEMPTS` (5) failed attempts are reached.
   - Use constant-time byte comparison when comparing SHA-256 token hashes in `SessionManager::authenticate` and PIN codes in `SessionManager::pair`.

5. **State Directory & File Permissions on Unix (`crates/triaged/src/session.rs`, `crates/triaged/src/scrollback.rs`)**:
   - Harden `log_dir` and session subdirectories to `0o700` on Unix, and harden `paired_devices.json`, `sessions.json`, session segment logs, and scrollback journals to `0o600`.

6. **Path Separator / Traversal Validation on `SessionId` (`crates/triage-core/src/session.rs`)**:
   - Reject `/`, `\`, `\0`, `.`, and `..` in `SessionId::new` so no filesystem helper can construct a traversal path from a `SessionId`.

7. **Decompressed Response Size Cap in Native HTTP History Client (`flutter/triage_client/lib/services/history_http_io.dart`, `flutter/triage_client/lib/services/triage_websocket_client.dart`)**:
   - Cap buffered HTTP history responses in `history_http_io.dart` and `decodeHistoryFrame` at 16 MiB (`16 * 1024 * 1024` bytes) to prevent OOM from oversized or gzip-bomb responses over cleartext HTTP.

## Plan

1. Update `crates/triage-core/src/session.rs`:
   - Enforce path-segment safety in `SessionId::new` (reject `/`, `\`, `\0`, `.`, and `..`).
2. Update `crates/triaged/src/http.rs`:
   - Replace `path.replace("..", "")` in `WebAssetCache::load_override_file` with strict component validation and `std::fs::canonicalize` containment checks.
   - Add `Origin` validation for `require_pairing == false` on `/ws` and `/api/sessions/{id}/history`, and omit wildcard CORS headers when `require_pairing == false`.
   - Configure explicit `WebSocketConfig` size bounds (`4 MiB` message / `1 MiB` frame) on WebSocket upgrades.
   - Add unit tests for override-dir traversal rejection and unpaired cross-origin rejection.
3. Update `crates/triage-transport-ws/src/lib.rs` and `crates/triaged/src/ws.rs`:
   - Add `is_authenticated()`, `has_global_receiver()`, and `set_global_receiver()` to `WebSocketSessionConnection`.
   - Register the global broadcast receiver in `handle_upgraded_ws` only once `conn.is_authenticated()` is true.
4. Update `crates/triaged/src/session.rs` and `crates/triaged/src/scrollback.rs`:
   - Add constant-time comparison helper `constant_time_eq`.
   - Track `failed_attempts` on `PendingPairingPin` and burn the PIN after 5 failed attempts; add unit test coverage.
   - Harden Unix permissions (`0o700` for directories, `0o600` for `paired_devices.json`, `sessions.json`, session logs, and `scrollback.journal`).
5. Update `flutter/triage_client/lib/services/history_http_io.dart` and `flutter/triage_client/lib/services/triage_websocket_client.dart`:
   - Cap decompressed HTTP history response buffering and `decodeHistoryFrame` payloads at 16 MiB; add unit test coverage.
6. Format, lint, test, update `devlog/000171-fix-security-audit-hardening.md`, commit, push, and reload local `triaged`.
