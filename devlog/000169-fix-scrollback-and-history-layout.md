# 000169: Fix Scrollback Loss and Older History Layout Corruption

## Agent
Antigravity @ triage branch fix/scrollback-and-history-layout

## Intent
Fix issues where session updates wipe or starve scrollback so the user cannot scroll back to view earlier history, and fix layout corruption in older scrollback history (overlapping/erased prefix lines at the history seam, torn CSI sequences, soft-wrapped lines converted into hard breaks, and trailing foreground-colored blank padding).

## What Changed
- `2026-10-23T20:31-0700` `crates/triaged/src/scrollback.rs`: Updated `encode_line` to drop trailing blank cells that carry only invisible foreground or intensity SGR attributes (such as full-width blanks stamped by `CSI K` while a foreground color is active), while still keeping blanks with non-default backgrounds, reverse video, or underlines. Omitted the trailing `\r\n` when `line.last_cell_was_wrapped()` is `true` (and preserved a single trailing word-wrap space when present) so soft-wrapped lines rejoin into a single logical line and reflow cleanly across client widths. Added unit tests covering both behaviors.
- `2026-10-23T20:31-0700` `flutter/triage_client/lib/terminal/terminal_store.dart`, `flutter/triage_client/lib/main.dart`: Updated `trimHistoryTailWithOffset` to ignore `0x0A` bytes balanced by preceding `CSI Ps A` cursor-up sequences or followed by relative horizontal cursor moves (`CSI Ps C` / `CSI Ps D`), preventing inline-TUI spinner frames from consuming the `maxLines` budget and starving `rawOutputPrefix`. Added `trimHistoryReplay` so `rawOutputPrefix` and `rawOutput` share `(maxLines, maxBytes)` without `rawOutput` starving `rawOutputPrefix`. Updated `_completePrivateCsi` to strip `\x1b[3J` (Erase Saved Lines) across `HistoryBytes` and `LiveBytes` so full-screen session redraws do not wipe client scrollback. Updated `TerminalStore._reduceHistory` to push `rawOutputPrefix` off the active screen into scrollback before replaying `rawOutput` and strip leading torn UTF-8/CSI fragments at `raw_output_start > 0`.
- `2026-10-23T20:31-0700` `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`: Updated `_saveScrollOffset`, `_scrollToCursor`, `_onTerminalChanged`, and `_onTerminalResize` so scrolling all the way to the top of scrollback (`pixels <= 0.0`, `target == 0.0`) preserves the scrolled-up state at offset `0.0` instead of clearing saved scroll state and snapping to `maxScrollExtent`.
- `2026-10-23T20:31-0700` `flutter/triage_client/test/terminal/history_trim_test.dart`, `flutter/triage_client/test/terminal/terminal_store_test.dart`: Added unit tests covering inline-TUI spinner line counting, `trimHistoryReplay` budget sharing, `\x1b[3J` stripping in history and live chunks, and pushing `rawOutputPrefix` into scrollback while stripping leading torn CSI fragments at `raw_output_start`.

## Decisions
- `2026-10-23T20:31-0700` Push `rawOutputPrefix` into scrollback on the client before replaying `rawOutput`: Writing `'\r\n' * (rows - 1) + '\x1b[H\x1b[0m'` after `rawOutputPrefix` moves all prefix lines above visible row 0 into scrollback and homes the cursor to `(0, 0)` on a clean active screen. Whether `rawOutput` clears the screen (`\x1b[2J`), uses cursor addressing (`\x1b[3A`, `\x1b[H`), or streams scrolling text, `rawOutputPrefix` cannot be overwritten or erased and zero blank gap lines enter scrollback.
- `2026-10-23T20:31-0700` Strip `\x1b[3J` in `_stripUnsupportedPrivateCsi`: Extending `_completePrivateCsi` to match `\x1b\[(?:>[0-9;]*m|3J)` leverages the existing `_escapeCarry` partial-CSI buffer so `CSI 3 J` is stripped even when split across live chunks or wrapped in Mode 2026 synchronized output, while leaving explicit `sink.clear()` calls intact.

## Commits
- `HEAD`: `fix: preserve scrollback across session updates and fix history layout`

## Progress
- [x] Investigate live sessions (`session-245`, `session-293`, `session-241`, `session-312`) and trace scrollback pipeline across `triaged` and `triage_client`
- [x] Create branch devlog and implementation plan
- [x] Fix `encode_line` in `crates/triaged/src/scrollback.rs`
- [x] Fix `trimHistoryTailWithOffset`, `trimHistoryReplay`, `\x1b[3J` filtering, and history seam replay in `flutter/triage_client/lib/terminal/terminal_store.dart` and `flutter/triage_client/lib/main.dart`
- [x] Fix top-of-scrollback (`pixels <= 0.0`) scroll preservation in `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`
- [x] Validate Rust and Flutter test suites, reload live `triaged` daemon, and open PR
