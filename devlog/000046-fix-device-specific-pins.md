# 000046 - fix/device-specific-pins

## Agent

- Codex

## Intent

- 2026-05-29T09:21-0700: Make pairing pins device-specific and refreshable so expired stored pins do not silently break reconnects.
- 2026-05-29T21:40-0700: Fix stale Flutter web client caching so updated clients load without requiring users to clear browser cache manually.
- 2026-05-30T15:26-0700: Address follow-up pairing review findings around concrete LAN binds, remote approval URLs, and unauthenticated challenge slot exhaustion.
- 2026-05-30T19:32-0700: Address follow-up pairing review findings around FlatBuffers first-time pairing and disconnected pairing challenge loading state.
- 2026-05-30T20:04-0700: Address follow-up clippy blockers and complete borrowed FlatBuffers pairing result parsing.
- 2026-05-30T20:26-0700: Preserve the daemon WebSocket target when the Flutter app is served by a dev or static asset host.

## What Changed

- 2026-05-29T20:19-0700: Replaced daemon-startup global PIN generation with per-client pairing challenges requested over the WebSocket protocol.
- 2026-05-29T20:19-0700: Added the daemon `/pair` verification page, which accepts a device code and issues a short-lived PIN bound to that device's `ClientId`.
- 2026-05-29T20:19-0700: Updated the Flutter web client pairing view to show a verification URL, device code, expiry, refresh control, and clear pairing errors instead of leaving the socket silent.
- 2026-05-29T20:19-0700: Cleared stale stored web tokens after unauthenticated hello responses and kept browser identity/token storage in localStorage so tabs in one browser profile share a device identity.
- 2026-05-29T20:19-0700: Changed `triage pair` to print the verification URL and device-code workflow instead of reading a stale `pairing_code.json`.
- 2026-05-29T21:40-0700: Changed daemon web override assets to bypass the in-memory asset cache so files updated on disk are served on the next request.
- 2026-05-29T21:40-0700: Added `Clear-Site-Data: "cache"` for app shell/bootstrap responses and serve `/flutter_service_worker.js` as a cleanup worker that deletes CacheStorage entries and unregisters itself.
- 2026-05-29T21:40-0700: Added web bootstrap cleanup in `index.html` to unregister service workers and delete CacheStorage without touching localStorage pairing state.
- 2026-05-29T22:34-0700: Restricted daemon `/pair` approval to loopback TCP peers so network-reachable clients cannot approve their own device codes.
- 2026-05-29T22:34-0700: Added pending pairing challenge limits and pairing client-id length validation on the unauthenticated challenge path.
- 2026-05-29T22:34-0700: Clamped issued PIN expiry to the parent device-code expiry and covered the behavior with daemon tests.
- 2026-05-30T15:26-0700: Allowed `/pair` approval for loopback peers and same-host peers that connect through a concrete listener IP, while still rejecting remote peers on wildcard and concrete listeners.
- 2026-05-30T15:26-0700: Stopped the Flutter pairing view from displaying non-local `/pair` URLs that remote browsers cannot use; it now asks for approval from the daemon host instead.
- 2026-05-30T15:26-0700: Changed the pending challenge cap to evict the oldest unapproved challenge instead of returning `too many pending pairing challenges` to every new device after the cap is filled.
- 2026-05-30T19:32-0700: Added FlatBuffers schema/request/result support for `pairing_challenge`, including regenerated Dart bindings and Rust/Flutter serializers and parsers.
- 2026-05-30T19:32-0700: Cleared the Flutter pairing challenge loading state when the socket is already disconnected before the challenge request can be sent, and allowed reconnect scheduling from that pairing-disconnected state.
- 2026-05-30T20:04-0700: Removed the unused stored pairing PIN Unix expiry and flattened the `/pair` PIN page renderer so the documented clippy command passes with warnings denied.
- 2026-05-30T20:04-0700: Added borrowed FlatBuffers parsing for `PairingChallengeResult` and extended the FlatBuffers pairing challenge regression test to cover that parser.
- 2026-05-30T20:04-0700: Moved `ws.rs` tests after production items and simplified `triage pair` config loading to clear additional clippy-denied warnings.
- 2026-05-30T20:26-0700: Changed the Flutter default WebSocket URI helper to use same-origin only when the page is served on the daemon's default port, otherwise falling back to `ws://127.0.0.1:7777/ws`.
- 2026-05-30T20:26-0700: Added widget-test coverage for Flutter dev-server, daemon-served, and non-HTTP base URL WebSocket defaults.

## Decisions

- 2026-05-29T20:19-0700: Keep pairing challenges in daemon memory rather than persisting them to disk; clients can request a new device code whenever their stored credential is missing, invalid, or expired.
- 2026-05-29T20:19-0700: Treat the challenge endpoint as JSON-only for now and force the Flutter client to negotiate `triage-json`, avoiding FlatBuffers schema regeneration for a pairing-only control path.
- 2026-05-29T20:19-0700: Reuse the existing persisted `ClientId` as the device boundary. Web localStorage makes one browser profile one device; separate browsers and the TUI/local clients keep separate identities.
- 2026-05-29T21:40-0700: Keep embedded web assets cached in memory, but treat override-directory assets as mutable deployment files and read them fresh on each request.
- 2026-05-29T21:40-0700: Clear only browser cache state, not site storage, so web pairing credentials in localStorage survive a client update.
- 2026-05-29T22:34-0700: Use the accepted TCP peer address to decide whether `/pair` is local; a daemon bound to `0.0.0.0` still permits approval through `127.0.0.1` but rejects non-loopback peers.
- 2026-05-30T15:26-0700: Treat `peer_ip == listener_ip` as local only when the listener IP is concrete. This keeps `0.0.0.0` and `[::]` from becoming remote-approval aliases while supporting daemon-host browsers that connect to a LAN-bound listener address.
- 2026-05-30T15:26-0700: Preserve approved challenges when evicting at the cap; unauthenticated remote clients cannot approve their own challenges, so evicting unapproved entries removes the fixed-window denial without discarding already approved PINs.
- 2026-05-30T19:32-0700: Appended the FlatBuffers pairing challenge tables to request/result unions to avoid renumbering existing payload variants.
- 2026-05-30T20:04-0700: Removed `PendingPairingPin.expires_at_unix` instead of preserving the field because stored PIN validation only needs `Instant`; the approval response still returns the clamped Unix expiry computed at issuance.
- 2026-05-30T20:26-0700: Keep direct daemon serving useful through same-origin on port 7777, but treat other HTTP origins as asset hosts so local dev and static-host flows retain the daemon default target.

## Issues

- 2026-05-29T20:19-0700: On Windows, `cargo test -p triaged ...` intermittently hit `link.exe` LNK1104 while the test executable was still locked. Retrying with `--lib` after a short wait completed successfully.
- 2026-05-29T20:19-0700: `git diff --check` treats CRLF line endings in modified Dart files as trailing whitespace in this worktree. Validation used `git -c core.whitespace=blank-at-eof,space-before-tab,cr-at-eol diff --check` so CRLF is allowed while actual whitespace errors are still checked.
- 2026-05-29T21:40-0700: The HTTP test group hit the same transient Windows `link.exe` LNK1104 lock on the first run; rerunning passed without source changes.
- 2026-05-29T22:34-0700: The default Cargo target dir again hit Windows `link.exe` LNK1104 on `triaged` test binaries; reran `cargo test --target-dir target\codex-test -p triaged`, which passed.
- 2026-05-29T22:46-0700: After the final loopback helper change, `target\codex-test` also held locked test binaries; reran `cargo test --target-dir target\codex-test-final -p triaged`, which passed.
- 2026-05-30T15:26-0700: The `code-review-graph` CLI/tooling was unavailable in this environment, so follow-up review work used direct targeted source inspection.
- 2026-05-30T19:32-0700: The default Cargo target dir hit Windows `link.exe` LNK1104 when running the focused transport test; reran in `target\codex-test-flatbuffers`, which passed.
- 2026-05-30T20:04-0700: `cargo clippy --all-targets --all-features -- -D warnings` also exposed `items_after_test_module` in `ws.rs` and `let_and_return` in `triage/src/main.rs`; both were corrected and the rerun passed.

## Commits

- HEAD — fix: make pairing pins device-specific

## Progress

- 2026-05-29T09:21-0700: Created `fix/device-specific-pins` worktree and started implementation planning.
- 2026-05-29T20:19-0700: Implemented daemon, transport, CLI, Flutter client, and focused tests for device-specific pairing challenges and expired PIN handling.
- 2026-05-29T21:40-0700: Implemented stale-client cache cleanup across daemon asset serving and Flutter web bootstrap, then validated HTTP cache behavior and widget tests.
- 2026-05-29T22:34-0700: Fixed review findings for remote self-pairing, unbounded challenge allocation, and PIN/device-code expiry mismatch; validated with focused pairing tests and the full `triaged` test suite.
- 2026-05-30T15:26-0700: Fixed follow-up review findings and validated with focused pairing tests, full `triaged` tests, full Flutter widget tests, formatting, and whitespace checks.
- 2026-05-30T19:32-0700: Fixed FlatBuffers pairing challenge support and the disconnected pairing loading state; validated with focused transport/UI tests, full relevant Rust crate tests, full Flutter tests, formatting, and whitespace checks.
- 2026-05-30T20:04-0700: Fixed the latest review findings and validated with `cargo fmt --all -- --check`, `cargo clippy --target-dir target\codex-clippy-review --all-targets --all-features -- -D warnings`, focused FlatBuffers and pairing Rust tests, and whitespace diff checks.
- 2026-05-30T20:26-0700: Fixed the Flutter dev/static host WebSocket default and validated with `dart format`, `flutter test test\widget_test.dart`, and whitespace diff checks.

## Next Steps

- 2026-05-29T20:19-0700: Run broader CI-equivalent checks before opening a PR if time allows, especially full workspace tests and Flutter analysis.
- 2026-05-29T21:40-0700: Consider full `cargo test --workspace` and `flutter analyze` before PR if CI-equivalent confidence is needed beyond the focused checks run locally.
- 2026-05-29T22:34-0700: Full workspace Rust tests and Flutter analysis remain useful before PR; only the daemon crate was rerun for this review-fix pass.
- 2026-05-30T15:26-0700: Consider `cargo test --workspace` and `flutter analyze` before PR if broader CI parity is needed.
