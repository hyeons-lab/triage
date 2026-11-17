# Plan: Server-Side Terminal Cell Sync and Unified Flutter GPU Grid Renderer

## Thinking

Triage's remote client currently suffers severe latency on session attach, backward scrollback paging, and active TUI redraws over high-RTT or bandwidth-constrained networks for four structural reasons:

1. **Append-only client VT emulation requires top-to-bottom replay**:
   - Client terminal emulators (`xterm2`, `xterm.js`) only expose sequential `write(bytes)` at the bottom of the buffer.
   - Attaching a session downloads 64 KiB of raw PTY output plus an SGR scrollback prefix and parses every byte top-to-bottom before painting the visible screen.
   - Scrolling up (`_pageHistoryUp` in `main.dart`) doubles the window (`64 -> 128 -> 256 KiB` / `1 MiB`), calls `_sink.clear()`, and replays the entire combined byte stream from top to bottom on every page boundary.

2. **Five sequential round-trips before first paint**:
   - `_loadDaemonSession` waits for layout, calls `snapshotSession`, calls `subscribeSessionEvents`, calls `resizeSession`, calls `attachSession`, and then fetches `/api/sessions/{id}/history` over HTTP before staging output. On a 200ms cellular/VPN link, handshake latency alone exceeds 1 second before byte replay even starts.

3. **Uncompressed, uncoalesced raw byte streaming causes TCP bufferbloat**:
   - `ws.rs` drains up to 256 `Output` chunks every 10ms and sends every raw PTY chunk over WebSocket without frame coalescing or client acknowledgment backpressure. When an AI coding CLI (`claude`, `codex`, `gemini`) redraws spinners or full-screen panels at 60-200 Hz, every intermediate frame queues in TCP on slow links, making input and display lag by seconds.

4. **Three divergent client terminal stacks**:
   - Desktop/Android native attempts `dart:ffi` to `libtriage_term` (`wezterm-term`) synced into `xterm2` `BufferLine`s; iOS never linked `libtriage_term.a` and falls back to slower pure-Dart `xterm2`; Web uses DOM `HtmlElementView` + `xterm.js` without WebGL (`terminal_pane_web.dart` ~3,900 lines vs `terminal_pane_stub.dart` ~3,100 lines).

### Target Architecture (Direction 1)

`triaged` already maintains a canonical `tattoy_wezterm_term::Terminal` and an on-disk `ScrollbackJournal` (`<= 210,000` lines across `.slog`/`.slog.zst` segments) for every `Live` and `Historical` session, and `crates/triage-term` already packs `wezterm-term` `Line`s into 4-word (`16-byte`) cells (`fg`, `bg`, `attrs`, `content`) with sideband DEC private mode tracking. Moving cell packing and diffing onto the server unlocks:

1. **Binary Packed Cell Payload (`TCG1` + zlib compression)**:
   - Compact little-endian `u32` binary format (`TCG1` magic, `line_count`, `combining_count`, per-row `(row_index, stored_cols | logical_cols<<12 | flags<<24)` headers where trailing blank cells are omitted via `stored_cols`, `4 x u32` cell words per stored cell, and `(line_entry_idx, col, codepoint)` combining triples).
   - `flags` bit `0` (`LINE_FLAG_WRAPS_NEXT`) records `line.last_cell_was_wrapped()` (`!sgr_bytes.ends_with(b"\r\n")` for journaled rows) directly on the row itself so random-access scrollback pages are completely self-contained for text selection/copy without needing row `r - 1`.
   - Compressed with `flate2` zlib (`Compression::fast()`) when beneficial (`compression = 1` vs `0` raw) and decoded in Dart with `dart:io` `zlib.decode` on native / `ZLibDecoder` (`package:archive`) on Web.

2. **1-RTT `SyncTerminal` Attach + Windowed `AckTerminalSync` Diff Streaming**:
   - `SyncTerminalRequest` combines optional live PTY resize (`rows`, `cols`, `pixel_width`, `pixel_height`, `dpi`, `resize_pty`), event subscription (`subscribe: true`), and initial compressed viewport cell snapshot (`known_frame_seq: 0`, or delta reconnect when `known_frame_seq > 0`) into a single WebSocket RTT (~700 bytes compressed for a typical 80x24 screen).
   - `OutputState` owns a `TerminalModeTracker` with monotonic `u64` generation counters (`erase_scrollback_gen`, `erase_display_gen`, `bell_gen`, `title_gen`) plus DEC Mode 2026 (`?2026h`..`?2026l`) synchronized-frame tracking and Kitty keyboard encoding read from `Terminal`. Mode flags and title are also persisted in `HandoverSession` (`#[serde(default)]`) so `triaged reload` preserves active TUI modes even past the 16 MiB raw log tail.
   - Each WS terminal subscriber owns a `ClientSyncBaseline` (`synced_seqno`, `stable_offset`, `rows`, `cols`, `alt_screen`, mode generations, `last_sent_frame_seq`, `last_acked_frame_seq`).
   - While `last_sent_frame_seq - last_acked_frame_seq < 2`, `drain_events` emits `SessionEvent::TerminalSync` frames containing only changed viewport rows (`line.changed_since(synced_seqno)`) plus up to `MAX_INLINE_PUSHED_SCROLLBACK_ROWS = 64` newly scrolled boundary rows so normal live scrolling requires zero extra RPCs. When a slow network has 2 unacknowledged frames in flight (or Mode 2026 is mid-frame within a 40ms guard), `drain_events` withholds intermediate frames and computes one coalesced diff from `baseline` as soon as `AckTerminalSync` arrives.
   - Legacy `SessionEvent::Output`, `SessionSnapshot`, `StyledRows`, and `/api/sessions/{id}/history` remain intact for the local Ratatui `triage` TUI, `triage-mcp`, and daemon tests.

3. **Unified Virtual Scrollback (`[0 .. total_scrollback_rows)`) & `FetchTerminalRows`**:
   - Upgrade `ScrollbackJournal` (`crates/triaged/src/scrollback.rs`) with an in-memory `Vec<SegmentIndex>` (`file_index`, `base_seq`, `record_count`, `min_log_offset`) built on `open()` and maintained across `append`, `rotate_active_file`, `enforce_retention`, and `rebase`, plus a 2-segment decoded record slice LRU cache and a fast stateless SGR-record-to-packed-cell decoder (`encode_line` emits only `\x1b[0m`, `1`, `2`, `3`, `4`, `7`, `38;2;r;g;b`, `48;2;r;g;b`, UTF-8, and optional `\r\n`).
   - `OutputState` tracks `journal_clear_floor: u64` (set to `journal.next_seq()` on `CSI 3J` while keeping on-disk records intact) and `mirrored_journal_records: u64` (seeded on `replay_tail` from records with `log_offset > raw_start` capped to `in_mem_scrollback`, incremented on `journal_scrolled_lines` capped to `in_mem_scrollback`, preserved across width reflows).
   - Virtual scrollback row `r` in `[0 .. archived_prefix_count + in_mem_scrollback)` resolves to `ScrollbackJournal` record `effective_floor + r` when `r < archived_prefix_count`, and to `Terminal` physical row `r - archived_prefix_count` otherwise, for both `Live` and `Historical` sessions.

4. **Unified Flutter Sparse Buffer & GPU `RenderBox` Cell-Grid Renderer**:
   - `TerminalCellBuffer` (`lib/terminal/terminal_cell_buffer.dart`): holds the live `rows x cols` viewport `Uint32List`, mode/cursor/title state, `totalScrollbackRows`, `eraseGen`, `trimmedTopTotal`, and sparse `128`-row `ScrollbackPage`s (`Map<int, ScrollbackPage>` with LRU eviction skipping visible/selected pages).
   - `RenderTerminalGrid` (`lib/widgets/terminal_grid_render_box.dart`): custom `RenderBox` painting only visible rows intersecting the ancestor `ScrollPosition` viewport:
     - Merged background color rect runs;
     - Crisp GPU vector box-drawing and block elements (`U+2500..U+259F`);
     - Bounded LRU cache of shaped `TextPainter` glyph/style entries with bundled `JetBrains Mono` + platform CJK/symbol/emoji fallbacks, plus underline (single, double, curly, dotted, dashed), strikethrough, and overline vector decorations;
     - Selection highlight, dim skeleton placeholder bars for in-flight sparse scrollback pages, and block/underline/bar cursor (filled when focused, hollow block when unfocused).
   - Single cross-platform `TerminalPane` (`lib/widgets/terminal_pane.dart`): unifies desktop, mobile, and Web (`CanvasKit`/`Wasm`) around `SingleChildScrollView` + `TerminalScrollbar` + `RenderTerminalGrid` + `TextInputClient` (`MobileAutoSpaceTracker`, `softKeyboardEnabled`, 80ms keyboard animation resize settle) + hardware `KeyEvent` encoder (`DECCKM`, `DECKPAM`, Kitty flags, sticky `ctrl`, copy/paste/select-all shortcuts) + mouse encoder (`?1000`/`?1002`/`?1003` + SGR `?1006`, `TouchScrollTakeover`) + desktop drag / mobile long-press selection with floating `_CopyButton` + `MultiLinePasteDialog` + `TerminalAccessoryBar` + `NoOlderScrollbackPill`.
   - Retire `xterm2`, `web/index.html` `xterm.js` scripts/styles, `terminal_pane_stub.dart`, `terminal_pane_web.dart`, `triage_term_ffi*.dart`, Android `buildTriageTermRust` Gradle task, and CI Rust FFI steps.

## Plan

1. **Safe Server-Side `triage-term` Engine (`crates/triage-term`)**:
   - Convert `crates/triage-term/Cargo.toml` to `crate-type = ["rlib"]`, add `flate2.workspace = true`, and remove `#![allow(unsafe_code)]` and `extern "C"` exports.
   - Implement `TerminalModeTracker` (sideband escape scanner with monotonic `u64` generation counters for bell, `2J`, `3J`, title, plus DEC `?2026` synchronized update state and mode serialization/restoration for handover).
   - Implement `TCG1` binary cell batch encoder/decoder (`pack_wezterm_line`, `pack_sgr_journal_line`, zlib compression threshold) and `ClientSyncBaseline::diff_terminal(...)` producing `TerminalSyncPatch` (viewport dirty rows + inline pushed scrollback rows up to 64 + cursor/modes/title/scrollback metadata).
   - Add unit tests in `crates/triage-term/src/lib.rs` covering `TCG1` round-trip, SGR journal row decoding, wide CJK + combining marks, DEC mode tracking, Mode 2026 guard, `CSI 3J`, and multi-client independent baselines.

2. **Protocol, Indexed `ScrollbackJournal`, Daemon Sync & WS Pacing (`crates/triage-core`, `crates/triaged`, `crates/triage-transport-ws`)**:
   - Add `SyncTerminalRequest`, `SyncTerminalResponse`, `FetchTerminalRowsRequest`, `FetchTerminalRowsResponse`, `AckTerminalSyncRequest`, `TerminalSyncFrame`, and `SessionEvent::TerminalSync` to `crates/triage-core/src/session.rs`, `crates/triage-core/schema/triage.fbs` (appending at the end of tables/unions), and `crates/triage-core/src/flatbuffers_proto.rs`.
   - Run `./scripts/generate-dart-flatbuffers.sh` to update checked-in Dart FlatBuffers bindings.
   - Extend `ScrollbackJournal` (`crates/triaged/src/scrollback.rs`) with monotonic sequence indexing (`first_retained_seq`, `next_seq`), segment index binary search, 2-segment LRU decompression cache, and `read_record_range(start_seq, count)`.
   - Wire `TerminalModeTracker`, `journal_clear_floor`, and `mirrored_journal_records` into `OutputState` (`crates/triaged/src/session.rs`) across `ingest`, `replay_tail`, `resize`, `reset_stale_mouse_tracking_after_output`, `HistoricalSession`, and `HandoverSession` (`crates/triaged/src/handover.rs`), and enable `enable_kitty_keyboard() -> true` on `TriageTerminalConfig`.
   - Implement `sync_terminal` and `fetch_terminal_rows` on `SessionApi` / `SessionManager` / `IpcClient`, and implement per-subscription `TerminalSyncSubscriptionState` (`MAX_IN_FLIGHT_FRAMES = 2` + `AckTerminalSync` + Mode 2026 coalescing) in `crates/triage-transport-ws/src/lib.rs` and `crates/triaged/src/ws.rs`.
   - Validate Rust workspace with `TRIAGE_SKIP_FLUTTER_BUILD=1 cargo test --workspace` and `cargo clippy --workspace --all-targets --all-features -- -D warnings`.

3. **Flutter Transport, `TCG1` Decoder & Sparse `TerminalCellBuffer` (`flutter/triage_client`)**:
   - Add `syncTerminalSession`, `fetchTerminalRows`, `ackTerminalSync`, and `TerminalSync` event decoding/encoding (FlatBuffers + JSON) in `lib/services/triage_websocket_client.dart`, with transport tests in `test/triage_websocket_client_test.dart`.
   - Create `lib/terminal/terminal_cell_protocol.dart` (`TCG1` binary + zlib decoder) and `lib/terminal/terminal_cell_buffer.dart` (`TerminalCellBuffer`, sparse `128`-row `ScrollbackPage` cache, pushed-row shifting, `eraseGen` detachment, `lineText`, selection range extraction, and `fallbackRows` hydration for mock tests).
   - Create `lib/terminal/terminal_key_encoder.dart` and `lib/terminal/terminal_mouse_encoder.dart` with comprehensive unit tests.

4. **Unified GPU `RenderTerminalGrid`, `TerminalPane` & `main.dart` Cutover**:
   - Build `lib/widgets/terminal_grid_render_box.dart` (`RenderTerminalGrid` with viewport-culled row painting, background run merging, vector box-drawing/block elements, LRU `TextPainter` glyph cache, underlines/strikethrough/overline, selection overlay, sparse page skeleton bars, and cursor styles).
   - Replace `terminal_pane_stub.dart` + `terminal_pane_web.dart` with unified cross-platform `lib/widgets/terminal_pane.dart` supporting desktop/mobile/web scroll anchoring, demand-paged scrollback (`onFetchRows` / `onNearTop`), `NoOlderScrollbackPill`, hardware keyboard + mobile `TextInputClient` IME (`MobileAutoSpaceTracker`), mouse reporting, drag/long-press selection + `_CopyButton`, paste + `MultiLinePasteDialog`, `TerminalScrollbar`, and `TerminalAccessoryBar`.
   - Update `lib/main.dart` (`SessionVm`, `_loadDaemonSession`, `_refreshSessionSnapshot`, `_processWebSocketEvent`, scrollback page loader, and lockstep daemon upgrade prompt when `syncTerminalSession` returns unsupported request).
   - Remove `xterm2` from `pubspec.yaml`, strip `xterm.js` from `web/index.html`, delete `triage_term_ffi*.dart`, `terminal_pane_stub.dart`, and `terminal_pane_web.dart`, and clean up `android/app/build.gradle.kts` and `.github/workflows/ci.yml`.

5. **Full Test Suite Migration & End-to-End Validation**:
   - Migrate and expand unit/widget tests across `flutter/triage_client/test/` (`terminal_cell_buffer_test.dart`, `terminal_selection_test.dart`, `terminal_scroll_anchor_test.dart`, `scrollback_clear_test.dart`, `terminal_paste_test.dart`, `terminal_hardware_key_test.dart`, `session_history_window_test.dart`, `widget_test.dart`, `triage_websocket_client_test.dart`).
   - Run `./scripts/bump-version.sh --check`, `./scripts/generate-dart-flatbuffers.sh --check`, `flutter analyze`, `flutter test`, `flutter build web --release`, `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, `cargo doc --workspace --all-features --no-deps`, and `cargo test --workspace`.
   - Update `devlog/000181-feat-terminal-cell-sync.md`, commit, push with explicit `HEAD:refs/heads/feat/terminal-cell-sync`, and open the PR.
