# Plan: Fix Terminal Indicator Stair-Casing and Filter Emulator Query Echo

## Thinking

Two critical issues were identified in terminal rendering and session input:

1. **Loading/Processing Indicator and Prompt Cursor Misalignment**:
   In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`, `xterm.js` was initialized with `convertEol: true`.
   - When interactive tools (like `antigravity` / `agy` CLI) render their loading spinners, "Thinking...", "Generating...", or status lines, they emit vertical cursor movements using raw `\n\n` (Line Feed) followed by relative horizontal movements (e.g. `\x1b[13D` or `\x1b[52D`).
   - With `convertEol: true`, `xterm.js` forcibly translated `\n` to `\r\n`, resetting the cursor column to 0 on every linefeed.
   - Consequently, relative horizontal moves clamped at column 0 instead of returning to their calculated column offsets, leading to mispositioned lines, erratic backspacing, and screen jittering during loading indicators.
   - *Fix*: Remove `convertEol: true` from `terminal_pane_web.dart`.

2. **Phantom Random Characters and Input Freezing from Terminal Query Auto-Responses**:
   - Modern interactive CLI tools (`agy`, `claude`, `vim`, etc.) emit terminal capability and mode queries (such as Kitty keyboard queries `\x1b[?u`, mode queries `\x1b[?2026$p`, cursor position reports `\x1b[6n`, device attributes `\x1b[c` / `\x1b[>c`, and OSC color queries `\x1b]10;?\x07`).
   - When these query sequences arrive at `xterm.js` / `xterm.dart`, the emulator automatically produces response escape strings on its output channel (`\x1b[24;1R`, `\x1b[?1;2c`, `\x1b[?0u`, `\x1b[>0;276;0c`, etc.).
   - In `main.dart` and `terminal_store.dart`, `isSuppressingHostInput` only guarded a 50ms window after history replay. When live chunks containing queries were written (or when history replay exceeded 50ms), the emulator's auto-responses were passed straight to `writeInput`, injecting them into the remote PTY stdin as fake user keystrokes.
   - The shell/CLI received these raw escape responses as user input, printing garbage strings (like `24;1R?1;2c?0u`) to the command prompt and corrupting the line editor buffer into an unrecoverable frozen state.
   - *Fix*:
     - Add `isEmulatorQueryResponse` filter to `main.dart` and `terminal_store.dart` matching all standard ANSI/VT/Kitty/OSC query responses (`CPR`, `DA1`, `DA2`, `DA3`, `DSR`, Kitty flags, DECRPM, OSC 10/11 color reports, window size reports).
     - Ensure any synthetic emulator output is filtered and never sent to `writeInput` as user keyboard input.

## Plan

1. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Remove `js_util.setProperty(options, 'convertEol', true);` so xterm.js preserves raw `\n` cursor column positions.
2. In `flutter/triage_client/lib/terminal/terminal_store.dart`:
   - Define `isEmulatorQueryResponse` utility to match terminal-generated auto-responses.
   - Filter emulator query responses in `UserInput` handling.
   - Guard `_writeDecoded` so synchronous sink output during writes is ignored.
3. In `flutter/triage_client/lib/main.dart`:
   - Filter query responses in `_setupSessionInputListener` so no terminal auto-responses are ever sent to `_client.writeInput`.
4. Update unit tests in `flutter/triage_client/test/terminal/terminal_store_test.dart` to verify that all emulator query responses are dropped while user keystrokes are preserved.
5. Validate formatting (`cargo fmt`), clippy (`cargo clippy`), workspace tests (`cargo test --workspace`), and Flutter tests (`flutter test`).
