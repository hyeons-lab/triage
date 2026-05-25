# Fix Newline Stair-Casing in Restored Sessions

## Thinking
1. **The Issue**:
   When restoring a historical session or displaying terminal history, lines of the terminal can suffer from stair-casing (shifting down one line without returning to column 0). This happens when a bare Line Feed (`\n`) is encountered in the logs or PTY output without a preceding Carriage Return (`\r`). The daemon's internal `wezterm_term::Terminal` advances its cursor down but keeps the same column offset, resulting in misaligned visual lines (e.g. padding spaces prefixing later lines).
   
2. **The Root Cause**:
   Unlike standard virtual terminal views where local or remote clients can configure `convertEol: true` (which xterm.js supports), the backend daemon's `wezterm_term::Terminal` instance parses the log exactly as-is. PTY output may contain bare `\n` characters which then cause stair-casing in `wezterm_term`'s internal memory state. When the client gets a session snapshot, it receives pre-rendered rows with these stair-cased prefix spaces, corrupting the layout of restored sessions.
   
3. **The Solution**:
   To resolve newline formatting issues, we can translate bare `\n` characters (which are not preceded by `\r`) to `\r\n` before feeding them to the `wezterm_term::Terminal` emulator's `advance_bytes` method. This ensures that the daemon's internal screen model correctly aligns the cursor to column 0 on every line feed, mirroring the visual behavior of standard client views.
   - We will write a helper `translate_newlines(bytes: &[u8]) -> Vec<u8>` in `crates/triaged/src/session.rs`.
   - We will use it in `OutputState::ingest` and `OutputState::replay` when calling `self.terminal.advance_bytes(&translated)`.
   - We will keep the original log-writing and size tracking intact (i.e. we still write the original raw bytes to the persistent PTY log, so logs are uncorrupted and authentic).

4. **Testing**:
   We will update `visible_rows_preserve_raw_bare_line_feed_columns` test case since it explicitly asserted the old stair-cased behavior. The new behavior will correctly align line feeds without stair-casing offsets. We will assert that the lines are formatted correctly starting at column 0.

## Plan
1. Create a helper function `translate_newlines(bytes: &[u8]) -> Vec<u8>` in `crates/triaged/src/session.rs` that replaces bare `\n` (not preceded by `\r`) with `\r\n`.
2. Update `OutputState::ingest` in `crates/triaged/src/session.rs` to pass the translated bytes to `self.terminal.advance_bytes`.
3. Update `OutputState::replay` in `crates/triaged/src/session.rs` to pass the translated bytes to `self.terminal.advance_bytes`.
4. Update the test `visible_rows_preserve_raw_bare_line_feed_columns` in `crates/triaged/src/session.rs` to assert that bare newlines no longer cause stair-cased column offsets and instead align to column 0.
5. Validate with `cargo test --workspace` to ensure all tests pass.
