# Plan: HTTP Session History & Fast Delta Resume

## Thinking

Currently, `triaged` and `triage_client` multiplex both real-time terminal I/O and bulk session history transfers over a single WebSocket stream:
1. `handle_upgraded_ws` in `crates/triaged/src/ws.rs` processes incoming RPCs and outgoing 10ms `drain_events()` ticks on one serialized loop. When `AttachSession` runs, the session actor thread reads/decompresses `.tlog.zst` segments and scrollback journals (`overlay_raw_output_history`), walks up to 3,500 lines in `wezterm-term` to build `visible_rows` and `styled_rows`, and serializes 64 KiB to 1 MiB onto the WebSocket.
2. When loading a session for the first time, `_loadDaemonSession` in `flutter/triage_client/lib/main.dart` performs four sequential WebSocket round-trips (`snapshotSession` -> `restoreSession`/`resizeSession` -> `subscribeSessionEvents` -> `attachSession`), three of which compute and ship 3,500 `visible_rows` and `styled_rows` that production rendering discards.
3. Resuming a session on reconnect (`_resubscribeAndRefreshHistory`), recovering from subscriber lag (`ResyncRequired`), or paging scrollback (`_pageHistoryUp`) re-fetches full windows (`64 KiB` up to `1 MiB`) over WebSocket instead of fetching only the missing byte range over HTTP.
4. Native clients connect to `triaged` over plain `ws://` / `http://` without SSL (relying on loopback or Tailscale/WireGuard encryption), so both platform ATS manifests (`Info.plist` on iOS/macOS, `AndroidManifest.xml` on Android) and the Dart HTTP client (`dart:io` `HttpClient`) must support cleartext `http://` connections.

## Plan

1. **Daemon History State & HTTP Endpoint (`crates/triage-core`, `crates/triaged`)**:
   - Add `SessionHistoryQuery` and `SessionHistoryResponse` types in `crates/triage-core/src/session.rs` (or `crates/triaged/src/session.rs`) and a non-blocking `ActorCommand::HistoryState` in `crates/triaged/src/session.rs` that snapshots in-memory log coordinates (`log_path`, `logged_tail_bytes`, `logged_output_seq`, `size`, `bracketed_paste_enabled`, `exited`, `current_working_directory`, and `scrollback` clone/reader) without blocking the actor on disk reads.
   - Implement `SessionManager::read_session_history` supporting:
     - Tail window mode (`window_bytes`),
     - Forward delta mode (`after_byte` + `after_seq`, returning 0 bytes when unchanged, the delta slice `log[after_byte..logged_tail_bytes]` when within `window_bytes` and unregressed, or falling back to a full tail window + `raw_output_prefix` if the log was trimmed or the sequence regressed), and
     - Backward range mode (`before_byte` + `max_bytes`, returning the older log slice `[start..before_byte]` plus any journal prefix at or older than `start`).
   - Add `GET /api/sessions/{session_id}/history` (and `OPTIONS` CORS preflight) in `crates/triaged/src/http.rs`:
     - Validate bearer token (`Authorization: Bearer <token>` + `X-Triage-Client-Id: <client_id>`) when `manager.require_pairing()` is enabled, returning `401 Unauthorized` on failure.
     - Execute the disk/zstd read and optional gzip encoding inside `tokio::task::spawn_blocking`.
     - Return JSON or binary payload with single HTTP `Content-Encoding: gzip` compression and `Cache-Control: no-store`.

2. **Slim WebSocket Control RPCs & Live Events (`crates/triaged/src/session.rs`)**:
   - Make `AttachSession` with `history_bytes == Some(0)` a true zero-history control attach: skip `overlay_raw_output_history` (`raw_output = []`, `raw_output_prefix = []`, `raw_output_start = logged_tail_bytes`, `output_seq = logged_output_seq`) and skip computing `visible_rows` and `styled_rows`.
   - Make `SessionEvent::ResyncRequired` carry a lightweight zero-history snapshot (`snapshot_without_rows`) so lagging subscribers do not receive an unsolicited 1 MiB snapshot on the WebSocket.

3. **Native Cleartext HTTP Support & Client History Fetcher (`flutter/triage_client`)**:
   - Add `NSAppTransportSecurity` (`NSAllowsArbitraryLoads = true`) to `flutter/triage_client/ios/Runner/Info.plist` and `flutter/triage_client/macos/Runner/Info.plist`.
   - Create platform-conditional HTTP history fetcher (`lib/services/history_http.dart`, `lib/services/history_http_io.dart`, `lib/services/history_http_web.dart`):
     - Native (`dart:io`): Uses persistent `HttpClient` (`autoUncompress = true`) over plain `http://` (when `ws://`) or `https://` (when `wss://`).
     - Web (`dart:js_interop` / `web`): Uses browser `fetch` with `Authorization` and `X-Triage-Client-Id` headers.
   - Expose `fetchSessionHistory` on `TriageWebSocketClient` with `ws://` -> `http://` URI derivation (preserving host, port, and path prefix before `/ws`), `401` -> `TriageAuthException` mapping, and fallback to `attachSession` when running under fake-channel unit/widget tests where no HTTP endpoint is listening.

4. **Client Session Load, Delta Resume, and Paging (`flutter/triage_client/lib/main.dart`, `terminal_store.dart`)**:
   - Update `TerminalStore._reduceHistory` to handle authoritative 0-byte deltas (`rawStart == currentLogBytes` with `bytes.isEmpty`) by advancing `historyHighWaterSeq` and `_appliedLiveSeq` and flushing `_pendingLive` without clearing the terminal or double-applying live chunks.
   - Track the active session's retained raw history tail in `TerminalStore` so backward paging (`before_byte`) can prepend older slices without re-downloading the newer tail.
   - Update `_loadDaemonSession`, `_refreshSessionSnapshot`, `_resubscribeAndRefreshHistory`, `ResyncRequired` event handling, and `_pageHistoryUp` to use `AttachSession(historyBytes: 0)` on the WebSocket and `fetchSessionHistory` over HTTP.
   - Validate with `cargo fmt`, `cargo clippy`, `cargo test`, and `flutter test`.
