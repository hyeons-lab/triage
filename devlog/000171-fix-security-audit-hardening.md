# Devlog: 000171-fix-security-audit-hardening

## Agent
Antigravity @ triage branch fix/security-audit-hardening

## Intent
Remediate findings from the security audit across HTTP static asset override serving, `SessionId` path component validation, unpaired cross-origin request protection, WebSocket frame limits and broadcast registration, pairing PIN brute-force lockout, Unix state file permissions, and HTTP history response size limits.

## What Changed
- 2026-10-25T08:01-0700 `crates/triage-core/src/session.rs`: Hardened `SessionId::new` to reject path separators (`/`, `\`), NUL bytes (`\0`), and relative traversal components (`.` and `..`).
- 2026-10-25T08:01-0700 `crates/triaged/src/http.rs`, `crates/triaged/src/ws.rs`, `crates/triage-transport-ws/src/lib.rs`: Replaced `path.replace("..", "")` in `WebAssetCache::load_override_file` with strict `Path::components` validation (`Component::Normal` only) plus `std::fs::canonicalize` containment checks; added `Origin` header validation and omitted wildcard CORS headers when `require_pairing == false` to prevent Cross-Site WebSocket Hijacking (CSWSH) and cross-origin HTTP history reads; set explicit `WebSocketConfig` frame/message size caps (1 MiB / 4 MiB); and deferred `register_global_receiver` until a WebSocket connection completes authentication.
- 2026-10-25T08:01-0700 `crates/triaged/src/session.rs`, `crates/triaged/src/scrollback.rs`, `crates/triaged/src/storage.rs`: Added `MAX_PAIRING_PIN_ATTEMPTS` (5) lockout on failed pairing PIN attempts, constant-time byte comparisons for token hashes and pairing PINs, and Unix owner-only filesystem permissions (`0o700` on state/session directories and `0o600` on `paired_devices.json`, `sessions.json`, session logs, and scrollback journals).
- 2026-10-25T08:01-0700 `flutter/triage_client/lib/services/history_http_io.dart`, `flutter/triage_client/lib/services/triage_websocket_client.dart`, `flutter/triage_client/test/triage_websocket_client_test.dart`: Added a 16 MiB decompressed response size cap (`maxHistoryResponseBytes` / `maxHistoryFramePayloadBytes`) on HTTP history responses and `THS1` frame decoding.

## Decisions
- 2026-10-25T08:01-0700 Security audit remediation: Enforce path-component and canonical-path containment in `WebAssetCache::load_override_file`, validate `SessionId` against path separators, enforce same-host/loopback `Origin` checks when `require_pairing = false`, cap WebSocket frame/message sizes and HTTP history payload sizes, lock out pairing PINs after 5 failed attempts with constant-time comparisons, defer global broadcast registration until authenticated, and set `0o700`/`0o600` Unix permissions on state directories and files.

## Commits
- HEAD: fix(security): harden HTTP asset serving, WebSocket auth, pairing PIN lockout, and file permissions
