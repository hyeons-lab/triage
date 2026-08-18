# 000125-01 Plan: Support Synchronized Output Mode (DEC Mode 2026) to Stop Cursor Jumping

## Thinking

1. **Problem Analysis:**
   - In `session-167.log` and `session-168.log`, `agy` renders thinking animations, spinner updates, and footer status bars concurrently with the user's interactive input box.
   - On every spinner tick (every ~50ms), `agy` wraps multi-line terminal redraws in Synchronized Output Mode escape sequences (`\x1b[?2026h` to start sync, `\x1b[?2026l` to end sync):
     `\x1b[?2026h\r\x1b[3A○ \n Runn\n\n\x1b[5D\x1b[?2026l`
   - In standard Synchronized Output (DEC Mode 2026, adopted across modern terminals like iTerm2, Alacritty, Kitty, WezTerm), the terminal emulator does not render intermediate cursor jumps or writes to the screen until `\x1b[?2026l` is received.
   - Because `xterm.js` does not natively support Mode 2026, writes arriving across separate WebSocket chunks are executed and painted incrementally.
   - On every spinner tick, the cursor jumps from the input box up to row -3 (drawing the spinner icon), down to row -2 (drawing the label), down to row 0, and back to the input row.
   - The user sees the cursor block jumping wildly across the footer area, and any keystrokes typed during those 50ms intervals land on the wrong line, overwriting previous text.

2. **Solution:**
   - Implement Synchronized Output (DEC Mode 2026) batching in `TerminalStore`:
     - When `\x1b[?2026h` is encountered in incoming stream chunks, buffer writes in `_synchronizedOutputBuffer`.
     - When `\x1b[?2026l` is encountered, flush the entire batch in a single atomic `_sink.write()` call.
     - Add a safety watchdog timer (50ms) to force-flush buffered output if a closing `\x1b[?2026l` is delayed or missing.
   - When written atomically to `_sink.write()`, `xterm.js` executes the entire frame synchronously within a single microtask, completely preventing the browser from rendering intermediate cursor jumps.

## Plan

1. Create worktree `fix/fix-cursor-synchronized-output` and devlogs.
2. Update `flutter/triage_client/lib/terminal/terminal_store.dart` to support Synchronized Output (Mode 2026) batching.
3. Add comprehensive unit tests in `flutter/triage_client/test/terminal/terminal_store_test.dart` for Synchronized Output mode (single chunk, split chunk, multi-frame, safety timeout).
4. Run `cargo fmt`, `cargo clippy`, `cargo check`, `cargo test`, and `flutter test`.
5. Build Flutter Web release client and compile updated `triaged` binary.
6. Perform zero-downtime daemon handover (`~/.cargo/bin/triaged --handover`).
7. Update branch devlog and open draft PR.
