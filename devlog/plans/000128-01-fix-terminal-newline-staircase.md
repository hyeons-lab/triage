# Plan: Fix Terminal Newline Staircasing While Preserving Relative Cursor Movements

## Thinking

When CLI tools (such as `cera-cli`, `llama-cli`, `cargo run`, `echo`, `cat`, compilers, or standard shell output) run inside raw-mode agent sessions (e.g. `agy` / Antigravity CLI), standard `\n` characters are emitted over pipes without kernel TTY `ONLCR` (map NL to CR-NL) translation.

In commit `60766b3` (#142), `translate_newlines` was removed to fix `agy`'s logo banner which emitted `\n\x1b[35D` (Line Feed followed by Cursor Back 35 columns). Because `\r` had been injected, `\r` reset the cursor column to 0 before `\x1b[35D` executed, clamping at column 0 and corrupting the logo by 5 columns.

However, completely removing newline translation caused all standard output lines without relative cursor movements to retain their horizontal column on `\n` (the classic Unix staircase effect). Banners like `cera-cli`, model stats, JSON strings, and help text staircase diagonally across the entire terminal.

### Solution

Implement selective, smart newline translation in both the daemon (`crates/triaged/src/session.rs`) and client (`flutter/triage_client/lib/terminal/terminal_store.dart`):
1. When `\n` is followed by a relative horizontal cursor movement (`\x1b[<N>D` for Cursor Back / `\x1b[<N>C` for Cursor Forward), preserve `\n` as bare `\n` without `\r` so relative cursor adjustments behave with authentic raw ANSI terminal semantics (`agy` logo and animations remain pixel-perfect).
2. For all other `\n` (followed by text, spaces, digits, newlines, or non-relative escape sequences like SGR colors `\x1b[...m` or line erasures `\x1b[...K`), translate `\n` to `\r\n` (or return to column 0 on the next line).
3. Add comprehensive unit tests in Rust and Dart covering:
   - Plain text / JSON / banner newline translation (`\n` -> `\r\n`)
   - Preservation of `\n` when followed by `\x1b[35D`, `\x1b[13D`, `\x1b[D`, `\x1b[C`
   - Preservation of existing `\r\n` without duplicate `\r`
   - SGR color sequences following `\n` receiving `\r\n`

## Plan

1. In `crates/triaged/src/session.rs`:
   - Implement `is_followed_by_relative_cursor_movement(slice: &[u8]) -> bool`.
   - Implement `translate_newlines(bytes: &[u8]) -> Cow<'_, [u8]>`.
   - Ingest translated bytes into `self.terminal.advance_bytes(&translated)` in `OutputState::ingest` and `OutputState::advance_replayed_bytes`.
   - Add unit tests for `translate_newlines` and `visible_rows`.
2. In `flutter/triage_client/lib/terminal/terminal_store.dart`:
   - Implement `_isFollowedByRelativeCursorMovement` and `_translateNewlines`.
   - Apply `_translateNewlines` in `_writeDirect`.
   - Add unit tests in `flutter/triage_client/test/terminal/terminal_store_test.dart`.
3. Verify with workspace tests (`cargo test --workspace` and `flutter test`).
4. Update devlog `devlog/000128-fix-terminal-newline-staircase.md`.
5. Commit and open PR.
