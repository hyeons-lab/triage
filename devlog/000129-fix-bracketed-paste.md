# Fix: Support Terminal Bracketed Paste in Flutter Client

Multi-line paste in terminal sessions (shells, REPLs, agent CLI tools like Claude Code and Antigravity) entered lines one by one as if Return was hit for each newline because the Flutter client never wrapped pasted text in DEC Mode 2004 Bracketed Paste escape sequences (`\x1b[200~` and `\x1b[201~`).

## Agent

- Claude 3.7 Sonnet / Antigravity

## Intent

- Enable seamless, safe multi-line pasting in both the Flutter web and native clients without executing intermediate lines upon paste.
- Ensure bracketed paste mode is synchronized from `SessionSnapshot` and dynamically updated during terminal sessions.
- Support standard platform paste chords (`Cmd+V` on macOS, `Ctrl+Shift+V` / `Ctrl+V` / `Shift+Insert` on Linux and Windows).

## What Changed

- Created `flutter/triage_client/lib/terminal/terminal_paste.dart` with `formatPasteInput(String text, bool bracketedPasteEnabled)` to sanitize embedded `\x1b[201~` and wrap in bracketed paste markers when enabled.
- Synchronized `bracketed_paste_enabled` from `SessionSnapshot` onto `SessionVm.terminal.setBracketedPasteMode(...)` and `SessionVm.bracketedPasteEnabled`.
- Updated `terminal_pane_web.dart`'s `pasteListener` to check bracketed paste mode and format pasted text with `formatPasteInput`.
- Updated `terminal_pane_stub.dart`'s `_handleTerminalKeyEvent` to intercept platform paste chords (`Cmd+V`, `Ctrl+Shift+V`, `Ctrl+V`, `Shift+Insert`) and paste clipboard text through bracketed paste encoding.
- Added comprehensive unit and widget tests for `formatPasteInput` and terminal paste handling.

## Decisions

2026-08-24T02:25-0700 Use DEC Mode 2004 bracketed paste encoding in client paste handlers:
- When bracketed paste mode is active on a session, paste operations wrap the clipboard text in `\x1b[200~` and `\x1b[201~`, stripping any embedded `\x1b[201~` to prevent escape injection attacks.
- If bracketed paste mode is disabled, pasted text is passed verbatim as raw text.

## Commits

- HEAD — fix(terminal): support bracketed paste mode in flutter web and native clients

## Progress

- 2026-08-24T02:25-0700 Created branch worktree `worktrees/fix-bracketed-paste` and devlog plan.
- 2026-08-24T02:32-0700 Implemented bracketed paste support across web and native Flutter views, synchronized snapshot state, added platform paste chords, and verified all 276 Rust tests and 351 Dart tests pass cleanly.
