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

2026-08-24T13:45-0700 Terminal chord disambiguation and defense-in-depth sanitization:
- On Linux/Windows, capture `Ctrl+Shift+V` and `Shift+Insert` for paste while allowing unshifted `Ctrl+V` to pass through as `0x16` (SYN / LNEXT / Vim visual block mode).
- Strip 8-bit C1 escape terminator `\x9b201~` alongside standard 7-bit `\x1b[201~` to prevent paste injection on 8-bit terminals.
2026-08-24T13:56-0700 Multiplatform terminal key and cache synchronization:
- Corrected session title key routing to `TerminalPane.setBracketedPasteMode` so Web DOM `_sessionTerms` cache is updated properly.
- Added initial bracketed paste mode sync during terminal creation and container event binding on Web.
- Added uppercase `V` matching for `Ctrl+Shift+V` in web window keydown listener.
- Compiled `_pasteEscapeInjectionPattern` regex in `formatPasteInput` and added `.contains()` fast-path.
- Added `_isPasting` serialization lock and `unawaited` in native paste key handler, plus Android `Ctrl+V`/`Meta+V` paste chords.

2026-08-24T15:29-0700 DOM re-binding reset and KeyRepeat event handling:
- Unconditionally synchronized `bracketedPasteMode` in `_syncInitialBracketedPasteMode` on Web DOM container re-binding so switching to sessions with bracketed paste disabled cleanly resets the state.
- Allowed `KeyRepeatEvent` alongside `KeyDownEvent` in native key handler so held paste chords execute reliably.
- Eliminated redundant regex capture group in `_pasteEscapeInjectionPattern`.

2026-08-24T17:55-0700 Unbracketed paste newline normalization and Windows paste chord:
- Normalized CRLF and bare LF to CR (`\r`) in `formatPasteInput` when bracketed paste is disabled so the PTY line discipline translates line endings correctly without staircasing.
- Added `TargetPlatform.windows` to `_isPasteChord` in `terminal_pane_stub.dart` supporting standard `Ctrl+V`.

## Commits

- ec6c300 — fix(terminal): support bracketed paste mode in flutter web and native clients
- 046553c — fix(terminal): address pr review comments for mounted safety, c1 escapes, and linux paste chords
- 5864582 — fix(terminal): address review refinements for web terminal key routing and regex optimization
- 20db49d — fix(terminal): address review comments for dom mode reset and keyrepeat handling
- HEAD — fix(terminal): normalize unbracketed paste newlines to cr and support windows ctrl+v

## Progress

- 2026-08-24T02:25-0700 Created branch worktree `worktrees/fix-bracketed-paste` and devlog plan.
- 2026-08-24T02:32-0700 Implemented bracketed paste support across web and native Flutter views, synchronized snapshot state, added platform paste chords, and verified all 276 Rust tests and 351 Dart tests pass cleanly.
- 2026-08-24T13:45-0700 Addressed PR #148 review comments: added mounted safety check across async clipboard fetch, disambiguated Linux/Windows paste chords (`Ctrl+Shift+V`/`Shift+Insert`) from `Ctrl+V`, added C1 `\x9b201~` sanitization, added unit tests, and updated review refinements.
- 2026-08-24T13:56-0700 Addressed local and CI review refinements: fixed web terminal title key routing, synchronized initial mode on late terminal mount, handled uppercase V on web keydown, optimized regex in formatPasteInput, added paste concurrency latch, and verified all 276 Rust and 356 Dart tests pass cleanly.
- 2026-08-24T15:29-0700 Addressed CI review feedback: unconditionally reset DOM bracketed paste mode on session re-binding, handled KeyRepeatEvent for native paste chords, simplified regex pattern, and verified all 276 Rust and 356 Dart tests pass cleanly.
- 2026-08-24T17:55-0700 Addressed CI review feedback: normalized unbracketed paste newlines to CR, supported Windows Ctrl+V paste chord, added Unicode grapheme tests, and verified all 276 Rust and 357 Dart tests pass cleanly.
