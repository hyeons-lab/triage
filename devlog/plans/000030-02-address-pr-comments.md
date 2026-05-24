# 000030-02-address-pr-comments

## Thinking
We need to address all PR #36 comments systematically:
1. **Stateful Translation**:
   The initial stateless `translate_newlines` implementation would treat the start of every chunk as independent. In case of a CRLF sequence split across PTY read chunks (e.g. `\r` at the end of chunk 1, `\n` at the start of chunk 2), it would translate the `\n` as bare, creating `\r\r\n`.
   To solve this, we must track the last ingested byte state dynamically inside `OutputState` using a `last_ingested_byte` field, passing it by mutable reference to the translation helper.
2. **Test Naming Alignment**:
   Rename `visible_rows_preserve_raw_bare_line_feed_columns` to `visible_rows_align_raw_bare_line_feed_to_column_0` to align with the new column-0 alignment behavior.
3. **Chunk-Boundary Verification**:
   Add a unit test `translate_newlines_stateful_across_chunk_boundaries` verifying that `\r` at the end of chunk 1 followed by `\n` at the start of chunk 2 is not incorrectly translated into a double-carriage return.

### Stateless Boundary Correction
Stateful chunk boundary tracking introduced an unexpected layout bug under ConPTY due to pre-wrapped command prompts (like the Antigravity CLI). When ConPTY wraps a prompt, the trailing byte in chunk 1 is tracked as `\r` (carriage return). When the command outputs a bare `\n` as the first byte of chunk 2, the stateful logic erroneously treats it as part of a CRLF sequence and skips translating it to `\r\n`. 

Since `wezterm_term::Terminal` has Line Feed Mode (LNM) disabled by default, a bare `\n` moves the cursor down without returning it to column 0. Consequently, the command's first line of output is rendered on the same line as the prompt, shifted by the prompt's final column offset.

To solve this permanently and robustly, we reverted the boundary tracking to a stateless model. Treating each chunk as independent ensures every bare `\n` is reliably translated to `\r\n` (moving the cursor to column 0 of the next line). The resulting harmless duplicate carriage return (`\r\r\n` instead of `\r\n` in case of chunk splits) is fully ignored by the terminal emulator and has zero visual impact.

## Plan
1. Add `last_ingested_byte: u8` to `OutputState` struct in `crates/triaged/src/session.rs`.
2. Refactor `translate_newlines` to accept `last_byte: &mut u8` and update the tracked byte state during parsing.
3. Update `OutputState::ingest` and `OutputState::replay` to pass `&mut self.last_ingested_byte` to the translation helper.
4. Rename `visible_rows_preserve_raw_bare_line_feed_columns` to `visible_rows_align_raw_bare_line_feed_to_column_0`.
5. Add `translate_newlines_stateful_across_chunk_boundaries` test case to verify CRLF splitting across chunk buffers.
6. Verify and compile the changes via `cargo check --workspace` and `cargo test --workspace`.
7. Revert cross-chunk stateful boundary tracking to robust stateless mode to fix ConPTY pre-wrapping alignment bugs.
8. Retain the optimized zero-reallocation `Vec::with_capacity` buffer pre-sizing.
9. Simplify and rename the unit tests accordingly, and verify all 36 active unit tests pass cleanly.
