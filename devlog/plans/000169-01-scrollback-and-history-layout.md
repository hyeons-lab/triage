# 000169-01: Fix Scrollback Loss and Older History Layout Corruption

## Thinking

Investigating the live sessions and scrollback pipeline revealed four interacting root causes behind losing scrollback on session updates and corrupted layout in older history:

1. **Inline-TUI spinner frames starve `rawOutputPrefix` in `trimHistoryTailWithOffset`**:
   - Antigravity CLI (`session-245`) emits 50-byte synchronized spinner frames of the form `\x1b[?2026h\r\x1b[3A⠹  Running command...\n\n\n\x1b[19D\x1b[?2026l`. Each frame moves the cursor up 3 rows (`\x1b[3A`) and then uses three `0x0A` (`\n`) bytes to move the cursor back down 3 rows in place without advancing logical history.
   - `trimHistoryTailWithOffset` in `flutter/triage_client/lib/terminal/terminal_store.dart` previously counted every `0x0A` byte backward from the tail until reaching `maxLines` (`1000` on initial 64 KiB load). After ~27 seconds of spinner output (~334 frames, 16.7 KiB), `rawOutput` alone contains over 1,000 `0x0A` bytes, causing `trimHistoryTailWithOffset([rawOutputPrefix, rawOutput])` to hit `maxLines` inside `rawOutput` and drop 100% of `rawOutputPrefix` (`retainedPrefixBytes == 0`), leaving 0 scrollback lines.
   - Furthermore, when `rawOutputPrefix` and `rawOutput` are concatenated into a single tail trim, a dense `rawOutput` can consume the entire line/byte budget and starve `rawOutputPrefix`.

2. **`\x1b[3J` (Erase Saved Lines) in `rawOutput` and `LiveBytes` wipes client scrollback**:
   - Both Antigravity CLI and Muse Code emit `\x1b[2J\x1b[3J\x1b[H` during full-screen redraws.
   - When `rawOutput` is replayed after `rawOutputPrefix` in `HistoryBytes`, or when a live output chunk containing `\x1b[3J` arrives in `LiveBytes`, `xterm.js` and `xterm.dart` execute `CSI 3 J` and clear the entire scrollback buffer, preventing the user from scrolling back after a session update.

3. **Seam collision between `rawOutputPrefix` and `rawOutput`, torn escape sequences at `raw_output_start > 0`, soft-wrapped lines in `encode_line`, and invisible trailing spaces**:
   - Writing `rawOutputPrefix` (`K` lines ending in `\r\n`) to a fresh terminal of height `rows` leaves the last `min(K, rows - 1)` lines of `rawOutputPrefix` on the active visible screen (`0 .. rows - 2`) instead of in scrollback. Subsequent `\x1b[2J`, `\x1b[H`, or relative cursor movements (`\x1b[3A`) in `rawOutput` then erase or overwrite the tail of `rawOutputPrefix`. Pushing `rawOutputPrefix` into scrollback with `'\r\n' * (rows - 1) + '\x1b[H\x1b[0m'` before replaying `rawOutput` moves all `K` prefix lines above row 0 into scrollback with zero blank gap lines.
   - When `raw_output_start > 0` (or when `rawOutput` is tail-trimmed), the slice boundary can cut mid-UTF-8 or mid-CSI escape sequence (e.g. `0m`, `;219;49m`, `2;3H`), rendering literal CSI fragments at the seam.
   - In `crates/triaged/src/scrollback.rs`, `encode_line` previously treated any blank cell with non-empty `scratch` SGR state as significant. When a line cleared to end-of-line (`\x1b[K`) while a foreground color or bold attribute was active, `wezterm-term` stamped those attributes onto trailing blank cells up to `cols`, and `encode_line` emitted all `cols` trailing spaces. Those invisible spaces wrapped onto extra blank rows at narrower client widths.
   - `encode_line` also unconditionally appended `b"\r\n"` even when `line.last_cell_was_wrapped()` was `true`, converting soft wraps at the capture width into permanent hard line breaks.

4. **Native scroll state cleared and yanked to bottom when scrolled to the very top (`pixels <= 0.0` / `target == 0.0`)**:
   - In `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`, `_saveScrollOffset` checked `if (!isAtBottom && position.pixels > 0.0)`, treating `pixels <= 0.0` (the top of scrollback, or iOS bounce overscroll) as "not scrolled up" and clearing both `_savedSessionScroll` and `_scrollAnchor`.
   - In `_scrollToCursor`, `if (target <= 0.0 && position.maxScrollExtent > 0) { target = position.maxScrollExtent; }` overwrote a legitimate top-of-history target (`0.0`) with `maxScrollExtent`, snapping the viewport back to the bottom.

## Plan

1. **Daemon (`crates/triaged/src/scrollback.rs`)**:
   - Update `encode_line` so blank trailing cells are only retained when they carry a visible background (`cell.attrs().background() != ColorAttribute::Default`), reverse video (`cell.attrs().reverse()`), underline (`cell.attrs().underline() != Underline::None`), or when `line.last_cell_was_wrapped()` is `true`.
   - Omit the trailing `b"\r\n"` in `encode_line` when `line.last_cell_was_wrapped()` is `true` so soft-wrapped lines rejoin into a single logical line and reflow cleanly across terminal widths.
   - Ensure `ScrollbackJournal::read_prefix_at_or_older_than` appends `b"\r\n"` if the joined prefix is non-empty and does not already end with `b'\n'`.
   - Add unit tests in `crates/triaged/src/scrollback.rs` verifying that foreground-only trailing blanks are trimmed and soft-wrapped lines rejoin without hard line breaks.

2. **Client (`flutter/triage_client/lib/terminal/terminal_store.dart`, `flutter/triage_client/lib/main.dart`)**:
   - Update `trimHistoryTailWithOffset` to ignore `0x0A` bytes balanced by preceding `CSI Ps A` (`\x1b[<N>A`) cursor-up sequences or followed by relative horizontal cursor movement (`\x1b[<digits>[DC]`).
   - Add `trimHistoryReplay` so `rawOutputPrefix` and `rawOutput` share `(maxLines, maxBytes)` without `rawOutput` starving `rawOutputPrefix`, and use it in `TerminalStore._reduceHistory` and `_pageHistoryUp` in `main.dart`.
   - In `TerminalStore._reduceHistory`, push `rawOutputPrefix` into scrollback using `'\r\n' * (rows - 1) + '\x1b[H\x1b[0m'` before writing `rawOutput`, strip leading torn UTF-8 / CSI fragments from `rawOutput` when `effectiveRawStart > 0`, and seed the active screen from `viewportSeed` when `effectiveRawStart > 0` and `rawOutput` is a partial cursor-addressed desert slice.
   - Update `_completePrivateCsi` to `RegExp(r'\x1b\[(?:>[0-9;]*m|3J)')` so `CSI 3 J` in `HistoryBytes` and `LiveBytes` does not wipe scrollback.
   - Add unit tests in `flutter/triage_client/test/terminal/terminal_store_test.dart`.

3. **Native Terminal Pane (`flutter/triage_client/lib/widgets/terminal_pane_stub.dart`)**:
   - Fix `_saveScrollOffset`, `_scrollToCursor`, and `_onTerminalResize` so scrolling to `pixels <= 0.0` (`target == 0.0`) preserves the scrolled-up state at the top of history instead of clearing it or jumping to `maxScrollExtent`.

4. **Validation & Deployment**:
   - Run `cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo test --workspace`.
   - Run `flutter analyze` and `flutter test` in `flutter/triage_client`.
   - Build release `triaged` with the updated web bundle, install and re-sign `~/.cargo/bin/triaged`, perform zero-downtime handover via `triaged reload`, commit, push, and open a PR.
