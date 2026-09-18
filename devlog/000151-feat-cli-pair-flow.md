# Devlog: Secure CLI Pairing Flow and Multi-User Verification

## Agent

Antigravity (gemini-2.5-pro) @ triage branch feat/cli-pair-flow

## Intent

Remove the unauthenticated HTTP `/pair` web endpoint from the daemon to eliminate local multi-user and network security vulnerabilities, implement the device code approval flow in the `triage` CLI over local IPC with kernel-enforced peer UID authentication, and update the Flutter web/mobile pairing screen to show the exact CLI command to run on the daemon host.

## What Changed

- `2026-09-16T10:20-0400 devlog/plans/000151-01-cli-pair-flow.md`: Authored plan for removing `/pair` web endpoint, implementing `triage pair <DEVICE_CODE>` over secure IPC, adding peer credential checks, and updating client UI.
- `2026-09-16T12:20-0400 crates/triaged/src/session.rs`: Added `Serialize, Deserialize, PartialEq, Eq` derives to `PairingPinInfo`.
- `2026-09-16T12:20-0400 crates/triaged/src/ipc.rs`: Added `ApprovePairingDeviceCode` to `WireRequest`, `PairingPin` to `WireSuccess`, `approve_pairing_device_code` method to `IpcClient`, and kernel peer credential verification (`libc::getpeereid` on macOS/BSD, `SO_PEERCRED` on Linux) to enforce same-UID access on incoming IPC connections.
- `2026-09-16T12:20-0400 crates/triaged/src/http.rs`: Removed `/pair` route dispatch and pairing HTML page rendering helpers.
- `2026-09-16T12:20-0400 crates/triaged/src/ws.rs`: Removed web pairing approval gate, tailscale whois lookups, and cached login structures.
- `2026-09-16T12:20-0400 crates/triaged/src/main.rs`: Simplified `start_websocket_server` call signature.
- `2026-09-16T12:20-0400 crates/triaged/src/http_tests.rs`: Updated test cases to verify `/pair` falls back to the SPA bundle instead of serving an unauthenticated pairing form.
- `2026-09-16T12:20-0400 crates/triage/src/main.rs`: Implemented `StartupMode::Pair` for `triage pair [device-code]`, interactive stdin fallback, error handling for user mismatches, and unit tests.
- `2026-09-16T12:20-0400 flutter/triage_client/lib/main.dart`: Removed `/pair` URL generation helpers and updated pairing UI to show the `triage pair <DEVICE_CODE>` CLI command with a copy button alongside the device code and PIN input form.
- `2026-09-16T12:20-0400 flutter/triage_client/test/widget_test.dart`: Updated pairing widget tests to assert CLI command display and copy functionality without `/pair` URLs.
- `2026-09-16T12:20-0400 crates/triaged/README.md, docs/remote-access.md, docs/configuration.md`: Updated documentation to describe CLI pairing, multi-user IPC security, and mark legacy `/pair` config options as deprecated.
- `2026-09-16T12:35-0400 crates/triaged/src/ipc.rs`: Removed redundant uid_t to u32 cast in `peer_euid` on Linux to satisfy clippy warnings.
- `2026-09-16T12:54-0400 crates/triaged/src/ipc.rs`: Logged warning on unsupported Unix platforms when peer UID verification fallback is used, and asserted simulated UID mismatch in unit tests.
- `2026-09-16T12:54-0400 crates/triage/src/main.rs`: Checked `is_terminal` before reading stdin to fail immediately in non-interactive environments, avoided temporary allocation during trimming, and added unit test.
- `2026-09-17T20:06-0400 devlog/000151-feat-cli-pair-flow.md, devlog/plans/000151-01-cli-pair-flow.md`: Rebased onto origin/main and renumbered sequence from 000150 to 000151 to resolve collision with merged PR #172.
- `2026-09-17T20:18-0400 crates/triaged/src/main.rs`: Added startup diagnostics warning when deprecated configuration options (`remote.pair_approval_tailnet_users` or `remote.pair_approval_trust_local_peers`) are detected.
- `2026-09-17T20:18-0400 crates/triaged/src/ipc.rs`: Factored out and hardened `verify_peer_uid` helper with dedicated unit test asserting unauthorized peer UID rejection.
- `2026-09-17T20:18-0400 flutter/triage_client/lib/main.dart`: Guarded clipboard copy operations in `_copyText` with `unawaited` and `.catchError(...)` to survive restrictive browser environments, and added `messenger.hideCurrentSnackBar()` for immediate feedback.
- `2026-09-17T20:18-0400 flutter/triage_client/test/widget_test.dart`: Added widget test coverage for copy button interactions and snackbar presentations.
- `2026-09-17T20:27-0400 crates/triage/src/main.rs`: Formatted remaining expiry seconds with two-digit zero padding (`{secs:02}s`).

## Decisions

- 2026-09-16T10:20-0400 Peer credential validation on IPC: Filesystem socket permissions (`0o700` dir, `0o600` socket) provide basic protection, but multi-user systems require kernel-level authentication. Incoming IPC connections will be checked using `libc::getpeereid` on macOS/BSD and `SO_PEERCRED` on Linux, ensuring callers have the exact same effective UID as the daemon.
- 2026-09-16T10:20-0400 CLI pairing approval: The `triage pair <DEVICE_CODE>` command talks to `triaged` over local IPC. If `<DEVICE_CODE>` is omitted on interactive terminals, `triage pair` prompts the user for it on stdin.
- 2026-09-16T10:20-0400 Removal of `/pair` HTTP endpoint: Rather than maintaining a complex and incomplete network authorization layer (like Tailscale whois) for an HTTP pairing page, the HTTP server drops the `/pair` route entirely. The web client displays the CLI command to execute on the daemon host.
- 2026-09-17T20:06-0400 Renumber devlog from 000150 to 000151: PR #172 merged to main with sequence number 000150, so rebasing onto main requires incrementing this branch sequence number to 000151 per AGENTS.md conventions.
- 2026-09-17T20:18-0400 Resilient unawaited clipboard handling: In Flutter web environments or embedded frames where clipboard write permissions might be restricted or throw unhandled DOM exceptions, clipboard write operations should be wrapped with `.catchError(...)` so UI interactions never block or throw unhandled exceptions.
- 2026-09-17T20:18-0400 SnackBar queue clearing: Immediate snackbar clearing via `ScaffoldMessenger.of(context).hideCurrentSnackBar()` ensures responsive UI feedback when tapping multiple copy buttons in sequence.

## Progress

- [x] Design IPC request and peer UID authentication
- [x] Implement `ApprovePairingDeviceCode` wire request and peer UID check in `triaged` IPC server
- [x] Remove `/pair` route and HTML rendering from `triaged` HTTP server
- [x] Remove unused Tailscale whois pairing authorizer in `ws.rs`
- [x] Implement `triage pair [device-code]` CLI subcommand
- [x] Add CLI argument parsing and error handling unit tests
- [x] Update Flutter client pairing UI to show CLI command with copy button
- [x] Update Flutter widget tests and verify 100% test pass
- [x] Update documentation across README and docs
- [x] Validate workspace with clippy, formatting checks, and full test suites
- [x] Address CI review items: terminal check on stdin, safe trimming, and unsupported platform warning
- [x] Rebase onto origin/main and renumber devlog to 000151
- [x] Round 1 local review hardening: deprecated config warnings, verify_peer_uid unit test, unawaited clipboard copy, and widget tests
- [x] Round 2 local review: clean review (0 critical, 0 warnings, zero padding nitpick applied)

## Commits

- b3302d2: feat(security): secure cli pair flow with peer credential verification
- 7a5b74b: fix(ipc): remove redundant cast in peer_euid on linux
- aab20bf: fix(cli): guard non-interactive stdin and log warning on unsupported unix
- c54afa5: chore(devlog): renumber devlog to 000151 following rebase onto origin/main
- HEAD: fix(pairing): harden ipc peer credentials, clipboard handling, and cli formatting
