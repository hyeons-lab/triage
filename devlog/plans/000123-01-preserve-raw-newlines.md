# Plan: Preserve Raw Newlines in PTY Stream

## Thinking

`triage` renders `antigravity` (`agy` CLI) logo banner corruptly:
1. `agy` outputs a banner using linefeed `\n` to advance rows while preserving cursor column index (~40), then emits `\x1b[35D` (Cursor Back 35 columns) to position the cursor at column 5 for drawing the body of the logo.
2. In raw TTY mode, `\n` does NOT include carriage return `\r`. Standard VT100 terminals leave the cursor column unchanged on `\n`.
3. However, `triaged` (in `crates/triaged/src/session.rs` via `translate_newlines`) and `triage_client` (in `flutter/triage_client/lib/terminal/terminal_store.dart` via `_normalizeNewlines`) forcibly replaced every bare `\n` with `\r\n`.
4. As a result, `\r` moves the cursor to column 0, `\n` drops to the next line at column 0, and `\x1b[35D` attempts to move left 35 columns from column 0 (which stays at column 0). Row 2 of the logo is drawn at column 0 instead of column 5, causing the top piece of the logo (drawn at column 6) to float 5 columns to the right of the rest of the logo, and scrambling the prompt formatting.
5. Standard cooked-mode shell applications already have `ONLCR` enabled in the TTY kernel driver, which emits `\r\n` naturally for standard shell commands. Raw-mode applications (like `agy`, ratatui TUIs, vim) explicitly turn off `ONLCR` when they want raw `\n` cursor movement without `\r`.
6. Removing the artificial `\n` -> `\r\n` translation in both `triaged` and `terminal_store.dart` restores accurate VT100 raw-mode terminal emulation without breaking cooked-mode shell output.

## Plan

1. Remove `_normalizeNewlines` in `flutter/triage_client/lib/terminal/terminal_store.dart` and update `_writeDecoded` to pass sanitized text directly to `_sink.write`.
2. Remove `translate_newlines` in `crates/triaged/src/session.rs` and update `OutputState::ingest` and `OutputState::replay` to advance raw bytes directly to `self.terminal`.
3. Update Rust and Dart unit tests to verify that raw `\n` is preserved without forced `\r` injection.
4. Validate cargo workspace tests, clippy, fmt, and Flutter client tests.
