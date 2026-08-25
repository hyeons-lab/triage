# Plan: Support Terminal Bracketed Paste in Flutter Client

## Thinking

When pasting multi-line text into a terminal session (e.g. bash, zsh, fish, REPLs, Claude Code, Antigravity CLI), each newline in the pasted text is immediately interpreted by the shell / PTY line discipline as pressing the Return/Enter key (`accept-line`), executing each line one by one as a separate command rather than inserting a multi-line snippet into the editor buffer.

Modern terminal emulators solve this via DEC Private Mode 2004 (Bracketed Paste Mode):
1. When an interactive program (shell, readline, zsh, vim, micro, etc.) starts, it sends `\x1b[?2004h` to the terminal emulator to enable bracketed paste mode.
2. When bracketed paste mode is active, when the user pastes text, the terminal emulator wraps the pasted payload in `\x1b[200~` (paste start) and `\x1b[201~` (paste end), stripping any embedded `\x1b[201~` to prevent escape sequence injection.
3. The shell buffers all incoming lines as literal newlines within the editor line buffer instead of executing them immediately.
4. When the program exits or suspends, it sends `\x1b[?2004l` to disable bracketed paste mode.

### Diagnosis

In the Triage codebase:
- `triaged` (Rust daemon) already tracks `bracketed_paste_enabled` via `output.terminal.bracketed_paste_enabled()` and broadcasts it in `SessionSnapshot`.
- `crates/triage` (Ratatui TUI) already implements `paste_input` using `snapshot.bracketed_paste_enabled`.
- In `flutter/triage_client`:
  - Web client (`terminal_pane_web.dart`): The container's DOM `pasteListener` caught browser paste events and called `_sendInput(text)`, bypassing `xterm.js`'s `term.paste(text)` and directly sending raw unbracketed text with newlines.
  - Native client (`terminal_pane_stub.dart`): When attaching to a session or restoring from a snapshot, `SessionVm.terminal` was never synchronized with `snapshot.bracketed_paste_enabled`, so `terminal._bracketedPasteMode` remained `false`. When paste shortcuts ran, `terminal.paste(text)` saw `_bracketedPasteMode == false` and fell back to `textInput(text)` (unbracketed raw text). Furthermore, key chord handling in `_handleTerminalKeyEvent` did not intercept platform paste chords (`Cmd+V` on macOS, `Ctrl+Shift+V` / `Ctrl+V` / `Shift+Insert` on Linux & Windows).

### Solution

1. In `flutter/triage_client/lib/terminal/terminal_paste.dart`:
   - Provide a shared helper `formatPasteInput(String text, bool bracketedPasteEnabled)` that sanitizes embedded `\x1b[201~` and wraps in `\x1b[200~...` and `...\x1b[201~` when enabled.
2. In `flutter/triage_client/lib/main.dart` & `SessionVm`:
   - Synchronize `session.terminal.setBracketedPasteMode(snap.bracketedPasteEnabled)` on session snapshot attach, restore, and resync events.
3. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - In `pasteListener`, check `term.modes.bracketedPasteMode` (or `widget.bracketedPasteEnabled`) and format the paste input with bracketed paste wrappers before sending to `_sendInput` (or invoke `_term.paste(text)`).
4. In `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
   - In `_handleTerminalKeyEvent`, intercept platform paste chords (`Cmd+V` on macOS/iOS, `Ctrl+V` / `Ctrl+Shift+V` / `Shift+Insert` on Linux/Windows), read the clipboard text, and paste via `_terminal.paste(text)` / `widget.controller.sendInput(formatted)`.
5. Add unit and widget tests verifying:
   - `formatPasteInput` formatting with bracketed paste enabled vs disabled.
   - `terminal_pane_web` paste event handling with bracketed paste mode.
   - `terminal_pane_stub` key handling and snapshot sync.

## Plan

1. Create `devlog/000129-fix-bracketed-paste.md`.
2. Implement `formatPasteInput` helper in `flutter/triage_client/lib/terminal/terminal_paste.dart`.
3. Wire bracketed paste synchronization in `flutter/triage_client/lib/main.dart` on snapshot reception.
4. Update `terminal_pane_web.dart` and `terminal_pane_stub.dart` paste handling.
5. Add unit and widget tests for bracketed paste in Flutter client.
6. Verify with `cargo test --workspace` and `flutter test`.
7. Update devlog, commit, and prepare PR.
