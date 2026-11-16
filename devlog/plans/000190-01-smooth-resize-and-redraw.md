# Plan 000190-01: Smooth Keyboard Resize and Atomic Redraw Coalescing

## Thinking

When opening or closing the soft keyboard on mobile (and during rapid full-screen TUI repaints from Claude Code, Codex, or `zsh` after `SIGWINCH`), four issues combine to produce visible top-to-bottom layout jumps:

1. `TerminalCellBuffer.resize()` builds the resized `_viewportLines` starting from index `0`, so shrinking viewport height discards the bottom rows around the cursor and expanding viewport height pads blanks at the bottom until the daemon responds.
2. `TerminalPane.didChangeMetrics()` uses an `80 ms` settle timer, which can fire partway through a ~200-250 ms Android/iOS keyboard animation and send multiple `sendResizeOut` / `SIGWINCH` events, while `_onTerminalResize` defers `_snapToBottom` to `addPostFrameCallback`.
3. `triaged` holds DEC Mode 2026 (`?2026h..l`) updates for at most `40 ms` (`ActorCommand::PollTerminalSync`), immediately broadcasts `SessionEvent::Snapshot` on resize before the child handles `SIGWINCH`, and has no trailing hold when a TUI emits `CSI H`/`CSI 2J`/`CSI J`/`CSI A` repaints across multiple PTY reads without `?2026`.
4. `RenderTerminalGrid.paint()` issues one `TextPainter.paint()` call per individual cell (`O(rows * cols)` paragraph draws per frame), amplifying repaint latency during full-screen redraws on mobile.

## Plan

1. **Daemon / `triage-term` (`crates/triage-term/src/lib.rs`, `crates/triaged/src/session.rs`):**
   - Extend `TerminalModeTracker` to record recent repaint/erase burst timing (`CSI ... H/f`, `CSI ... A`, `CSI ... J`) alongside `sync_update_started_at` and expose `should_hold_sync_poll(now, sync_hold, burst_quiet, burst_max_hold)`.
   - Track a short `resize_hold_until` deadline on `OutputState` (set for `30 ms` on dimension-changing `apply_terminal_resize_and_broadcast`) so `PollTerminalSync` waits for the child's immediate post-`SIGWINCH` clear/repaint rather than emitting pre-redraw and mid-redraw frames.
   - Raise explicit `?2026h..l` max hold from `40 ms` to `150 ms`, with `8 ms` burst quiet / `35 ms` max hold for unwrapped repaints (still bypassing holds when `exited` or `force_full`).
2. **Client `TerminalCellBuffer` (`flutter/triage_client/lib/terminal/terminal_cell_buffer.dart`):**
   - In `resize()`, preserve bottom/cursor-anchored lines (`keepEnd = max(_cursorY + 1, ...)` capped to `oldLines.length`) when `rows` shrinks and pull resident scrollback lines down from `lineAtVirtualRow` when `rows` grows (updating `_cursorY` accordingly) rather than anchoring from row `0`.
3. **Client `TerminalPane` & `RenderTerminalGrid` (`terminal_pane.dart`, `terminal_grid_render_box.dart`):**
   - Use a `260 ms` metrics settle delay on mobile in `didChangeMetrics()` so Android/iOS keyboard slide animations trigger a single resize at rest, and apply synchronous bottom pinning in `_onTerminalResize` / `RenderTerminalGrid.performLayout` instead of letting an un-snapped frame paint first.
   - Batch contiguous single-width printable ASCII runs (`0x20..0x7E`) sharing `(fg, bold, italic)` per row in `RenderTerminalGrid.paint()`, keeping the per-cell path for wide glyphs, non-ASCII fallback glyphs, combining marks, and vector box-drawing/block characters.
4. **Tests & Verification:**
   - Add Rust tests in `triage-term` / `triaged` covering extended `?2026` hold, heuristic repaint burst hold/release, and post-resize hold release.
   - Add Flutter tests in `terminal_cell_buffer_test.dart`, `terminal_pane_ime_test.dart`, and/or a render/resize test covering bottom-anchored `resize()` shrink/grow and batched run painting + bottom pinning.
   - Run `flutter analyze`, `flutter test`, `cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo test --workspace` (with real Flutter web bundle), rebuild the release APK and update the served binary, and install/reload local `triaged` + `triage-mcp` if desired or report exact commands.
