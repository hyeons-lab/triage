# 000046 - fix/device-specific-pins

## Agent

- Codex
- Antigravity

## Intent

- 2026-05-29T09:21-0700: Make pairing pins device-specific and refreshable so expired stored pins do not silently break reconnects.
- 2026-05-29T21:40-0700: Fix stale Flutter web client caching so updated clients load without requiring users to clear browser cache manually.
- 2026-05-30T15:26-0700: Address follow-up pairing review findings around concrete LAN binds, remote approval URLs, and unauthenticated challenge slot exhaustion.
- 2026-05-30T19:32-0700: Address follow-up pairing review findings around FlatBuffers first-time pairing and disconnected pairing challenge loading state.
- 2026-05-30T20:04-0700: Address follow-up clippy blockers and complete borrowed FlatBuffers pairing result parsing.
- 2026-05-30T20:26-0700: Preserve the daemon WebSocket target when the Flutter app is served by a dev or static asset host.
- 2026-05-30T20:55-0700: Ensure clearing browser site data drops any in-memory bearer token and returns the running app to pairing.
- 2026-05-30T23:46-0700: Correct initial web terminal replay layout when shell prompt rows include stale leading terminal padding.
- 2026-05-31T12:39-0700: Resolve the infinite resizing and terminal flashing loop on active sessions by optimizing replay/reset handling when initial content is already written.
- 2026-05-31T12:47-0700: Resolve the live active cursor displacement issue where the cursor is placed too high due to aggressive scrollback prompt line clamping.
- 2026-05-31T13:01-0700: Resolve the terminal cursor misalignment on first load by synchronously updating lastFittedCols/lastFittedRows to prevent duplicate concurrent layout refreshes.

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
- 2026-05-30T20:55-0700: Changed Flutter reconnects to re-read the stored client id and bearer token before `hello`, clearing the in-memory token if browser storage was cleared.
- 2026-05-30T20:55-0700: Added a lightweight running-app credential storage watcher that reconnects into pairing when the stored client id or token no longer matches memory.
- 2026-05-30T20:55-0700: Added storage client-id clearing helpers and a widget regression test for clearing stored credentials while the app remains open.
- 2026-05-30T23:32-0700: Changed the Flutter pairing URL into a clickable button that opens `/pair?device_code=...` directly and added a copy button beside the device code.
- 2026-05-30T23:32-0700: Added a copy button to the daemon `/pair` PIN page, including a clipboard fallback that selects the PIN if browser clipboard access fails.
- 2026-05-30T23:32-0700: Made the web client's new-session shell menu explicit to Windows and changed non-Windows direct creation to launch the user's default POSIX shell through `/bin/sh -lc`.
- 2026-05-30T23:46-0700: Added terminal replay row normalization that removes leading padding only from shell-prompt-only rows before writing the initial xterm contents.
- 2026-05-30T23:46-0700: Added replay regression coverage for padded WSL-style prompt rows while preserving leading indentation in ordinary output.
- 2026-05-31T08:41-0700: Changed selected live session replay to resize the daemon snapshot to the current web viewport before applying initial history, preventing stale 80-column MOTD wrapping after refresh.
- 2026-05-31T08:41-0700: Applied daemon resize response snapshots from the terminal resize callback and only bumped replay revision when the snapshot size changes, so fitted xterm dimensions update without a replay/resize feedback loop.
- 2026-05-31T12:39-0700: Refactored `didUpdateWidget` in `terminal_pane_web.dart` to use a helper `_triggerFullReplayOrReset()`, which bypasses full stability timing, empty-fitting, and daemon resizing requests if the terminal has already finished writing initial content, preventing the scrollbar-presence layout feedback loop.
- 2026-05-31T12:47-0700: Disabled cursor clamping for live active sessions, added custom regression test coverage in `cursor_position_test.dart`, rebuilt and reinstalled all client and daemon components, and verified successful operation of the daemon.
- 2026-05-31T13:01-0700: Updated `_applySnapshotToSession` to update `session.lastFittedCols` and `session.lastFittedRows` synchronously before performing asynchronous history merging, ensuring subsequent concurrent WebSocket snapshot events resolve `sizeChanged` to `false` and skip duplicate history-replay cycles.

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
- 2026-05-30T20:55-0700: Treat browser storage as the source of truth once client-id storage is available. If the user clears site data while the app is running, the app must stop reusing stale in-memory credentials and re-enter pairing.
- 2026-05-30T23:32-0700: Keep `/pair?device_code=...` links visible only for local verification hosts; remote clients still get local-approval guidance instead of a unusable or unsafe remote approval URL.
- 2026-05-30T23:32-0700: Gate shell-submenu visibility by platform rather than the number of configured shells so future non-Windows shell options do not accidentally reintroduce a submenu.
- 2026-05-30T23:46-0700: Keep the normalization in the web replay path rather than daemon snapshots so command output and stored session logs remain unchanged.
- 2026-05-31T08:41-0700: Prefer current viewport sizing for the selected replay, preserve saved sizes for unselected historical session restore, and treat same-size resize responses as state updates rather than full replay triggers.
- 2026-05-31T12:39-0700: Avoid redundant terminal clearing, empty fitting, and layout-debounce timing when updating an already populated terminal, relying on standard ResizeObserver callbacks for actual viewport/window size changes rather than replay revision triggers.
- 2026-05-31T12:47-0700: Keep the prompt-line cursor clamping active *only* for exited/historical sessions (to prevent the cursor from floating on blank padding rows), while completely disabling it for active sessions where the live PTY coordinates must be trusted.
- 2026-05-31T13:01-0700: Update `lastFittedCols` and `lastFittedRows` synchronously to ensure any asynchronous task boundaries see the size state immediately without awaiting the full snapshot rendering frame.

## Issues

- 2026-05-29T20:19-0700: On Windows, `cargo test -p triaged ...` intermittently hit `link.exe` LNK1104 while the test executable was still locked. Retrying with `--lib` after a short wait completed successfully.
- 2026-05-29T20:19-0700: `git diff --check` treats CRLF line endings in modified Dart files as trailing whitespace in this worktree. Validation used `git -c core.whitespace=blank-at-eof,space-before-tab,cr-at-eol diff --check` so CRLF is allowed while actual whitespace errors are still checked.
- 2026-05-29T21:40-0700: The HTTP test group hit the same transient Windows `link.exe` LNK1104 lock on the first run; rerunning passed without source changes.
- 2026-05-29T22:34-0700: The default Cargo target dir again hit Windows `link.exe` LNK1104 on `triaged` test binaries; reran `cargo test --target-dir target\codex-test -p triaged`, which passed.
- 2026-05-29T22:46-0700: After the final loopback helper change, `target\codex-test` also held locked test binaries; reran `cargo test --target-dir target\codex-test-final -p triaged`, which passed.
- 2026-05-30T15:26-0700: The `code-review-graph` CLI/tooling was unavailable in this environment, so follow-up review work used direct targeted source inspection.
- 2026-05-30T19:32-0700: The default Cargo target dir hit Windows `link.exe` LNK1104 when running the focused transport test; reran in `target\codex-test-flatbuffers`, which passed.
- 2026-05-30T20:04-0700: `cargo clippy --all-targets --all-features -- -D warnings` also exposed `items_after_test_module` in `ws.rs` and `let_and_return` in `triage/src/main.rs`; both were corrected and the rerun passed.
- 2026-05-30T23:32-0700: The in-app browser backend was unavailable, so UI verification used widget tests and local HTTP checks against the restarted daemon.
- 2026-05-30T23:32-0700: The focused `triaged` test initially hit Windows `link.exe` LNK1104 on test executable output; rerunning the library target passed.
- 2026-05-31T08:41-0700: The first `cargo install --path crates\triaged --force` rebuilt successfully but could not replace the running Windows executable; stopping the old daemon and rerunning install succeeded.
- 2026-05-31T12:39-0700: The terminal flashing bug occurred due to a layout feedback loop where empty terminals fitted to one column more (without scrollbars), sent a resize to the daemon, received a Snapshot, triggered a full replay revision reset which cleared the terminal, showing the scrollbar on replay and fitting to one column less (with scrollbar), starting the loop again.
- 2026-05-31T12:47-0700: The active session cursor was misplaced too high because the scrollback prompt clamping logic was aggressively forcing the cursor row back to the last line containing `$` or `>` if intermediate lines were blank (e.g., after empty log outputs or interactive layout shifts).

## Commits

- 81d48ea — fix: make pairing pins device-specific
- 5eae74c — fix: repair pairing UX and terminal replay
- bf7d68e — fix: repair terminal session restore and flashing loop
- 228b602 — fix: disable prompt line clamping for active session cursor
- a500cc4 — fix: prevent duplicate concurrent terminal layout refreshes on first load
- HEAD — fix: resolve terminal state inconsistency on asynchronous size updates

## Progress

- 2026-05-29T09:21-0700: Created `fix/device-specific-pins` worktree and started implementation planning.
- 2026-05-29T20:19-0700: Implemented daemon, transport, CLI, Flutter client, and focused tests for device-specific pairing challenges and expired PIN handling.
- 2026-05-29T21:40-0700: Implemented stale-client cache cleanup across daemon asset serving and Flutter web bootstrap, then validated HTTP cache behavior and widget tests.
- 2026-05-29T22:34-0700: Fixed review findings for remote self-pairing, unbounded challenge allocation, and PIN/device-code expiry mismatch; validated with focused pairing tests and the full `triaged` test suite.
- 2026-05-30T15:26-0700: Fixed follow-up review findings and validated with focused pairing tests, full `triaged` tests, full Flutter widget tests, formatting, and whitespace checks.
- 2026-05-30T19:32-0700: Fixed FlatBuffers pairing challenge support and the disconnected pairing loading state; validated with focused transport/UI tests, full relevant Rust crate tests, full Flutter tests, formatting, and whitespace checks.
- 2026-05-30T20:04-0700: Fixed the latest review findings and validated with `cargo fmt --all -- --check`, `cargo clippy --target-dir target\codex-clippy-review --all-targets --all-features -- -D warnings`, focused FlatBuffers and pairing Rust tests, and whitespace diff checks.
- 2026-05-30T20:26-0700: Fixed the Flutter dev/static host WebSocket default and validated with `dart format`, `flutter test test\widget_test.dart`, and whitespace diff checks.
- 2026-05-30T20:55-0700: Fixed the site-data-cleared reconnect behavior and validated with `dart format`, `flutter test test\widget_test.dart`, and whitespace diff checks.
- 2026-05-30T23:32-0700: Added clickable/copy pairing controls and Windows-only shell-menu gating; validated with `dart format`, `cargo fmt --all`, `flutter test test\widget_test.dart`, the focused `triaged` HTTP test, `flutter build web`, `cargo install --path crates\triaged --force`, and local HTTP bundle checks.
- 2026-05-30T23:46-0700: Fixed padded initial terminal prompt replay and validated with `dart format`, `flutter test test\cursor_position_test.dart`, `flutter test test\widget_test.dart`, `flutter build web`, `cargo install --path crates\triaged --force`, whitespace diff checks, and local HTTP bundle checks.
- 2026-05-31T08:41-0700: Fixed stale-width initial session replay after refresh and validated with `dart format`, `flutter test test\widget_test.dart`, `flutter test test\cursor_position_test.dart`, `flutter build web`, `cargo install --path crates\triaged --force`, and local HTTP checks against restarted `triaged`.
- 2026-05-31T12:39-0700: Fixed terminal flashing layout feedback loop by optimizing `replayRevision` updates in the web client, compiled the Flutter web client and Rust daemon, validated with the full workspace Rust and Flutter test suites, and verified the running daemon.
- 2026-05-31T12:47-0700: Disabled cursor clamping for live active sessions, added custom regression test coverage in `cursor_position_test.dart`, rebuilt and reinstalled all client and daemon components, and verified successful operation of the daemon.
- 2026-05-31T13:01-0700: Prevented duplicate concurrent history merges and terminal layout refreshes during first load by updating size state synchronously, compiled the web client, reinstalled and restarted the daemon, and successfully verified all tests.
- 2026-05-31T13:15-0700: Resolved potential state inconsistency on asynchronous size updates by tracking in-flight sizes synchronously on the session VM, staging, committing, compiling the web client, and reinstalling/restarting the daemon.

## Next Steps

- 2026-05-31T12:47-0700: Open a pull request via `gh pr create` and verify status checks.
