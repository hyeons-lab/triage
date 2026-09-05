# 000135: Safe Multi-Line Paste and Bracketed Paste Synchronization

- **Agent:** Antigravity (gemini-3-8-flash) @ triage branch fix/safe-multiline-paste
- **Intent:** Prevent terminal wedging and accidental multi-command execution when pasting multi-line text by properly synchronizing DEC Mode 2004 (bracketed paste) across Flutter web, native desktop, and mobile touch IME clients, and adding a safety confirmation dialog when pasting multi-line text into sessions without bracketed paste.

## What Changed

- **2026-09-04T20:18-0700** Rebased worktree onto latest origin/main (`655b7d3`) and initialized plan file (`devlog/plans/000135-01-safe-multiline-paste.md`).
- **2026-09-04T20:25-0700** flutter/triage_client/lib/terminal/terminal_paste.dart: Added `isMultiLine`, `flattenToSingleLine`, and `lineCount` utility functions to inspect and normalize multi-line paste payloads.
- **2026-09-04T20:25-0700** flutter/triage_client/lib/widgets/multiline_paste_dialog.dart: Added `showMultiLinePasteDialog` confirmation modal with line count preview and options to Cancel, Paste as Single Line, or Paste (Execute Commands).
- **2026-09-04T20:25-0700** flutter/triage_client/lib/widgets/terminal_pane_stub.dart: Added `bracketedPasteEnabled` property, `_isBracketedPasteEnabled()`, and `_handlePaste()`. Intercepted multi-line IME input (`data.length > 1 && isMultiLine(data)`) in `_onTerminalOutput` so mobile Gboard clipboard pastes are bracketed or confirmed instead of executing line by line.
- **2026-09-04T20:25-0700** flutter/triage_client/lib/widgets/terminal_pane_web.dart: Added `bracketedPasteEnabled` property, synchronized initial bracketed paste mode to xterm.js, and integrated `_handlePaste()` with confirmation dialog.
- **2026-09-04T20:25-0700** flutter/triage_client/lib/main.dart: Forwarded `bracketedPasteEnabled: session.bracketedPasteEnabled` to `TerminalPane`.
- **2026-09-04T20:25-0700** flutter/triage_client/test/terminal/terminal_paste_test.dart: Added unit tests for multi-line utilities and widget tests for `showMultiLinePasteDialog`.
- **2026-09-04T20:25-0700** Built release APK with Flutter and installed directly to the connected Pixel 10 Pro Fold via ADB (`adb-58291FDCG001G8-b6KQdx._adb-tls-connect._tcp`).

## Decisions

- **Direct Bracketed Paste Mode Propagation**: Pass `bracketedPasteEnabled` directly as a typed boolean property from `SessionVm` into `TerminalPane` on both Web and Native platforms, eliminating reflection and `js_util.getProperty` failures on minified Dart objects.
- **Mobile Soft Keyboard (IME) Multi-Line Interception**: In `terminal_pane_stub.dart`, intercept `data.length > 1 && isMultiLine(data)` in `_onTerminalOutput` so multi-line text committed via Gboard or soft keyboard clipboard chips is routed through `_handlePaste` rather than leaked as raw unbracketed newlines that execute commands line by line.
- **Safety Intercept for Unbracketed Multi-Line Pastes**: When bracketed paste mode is inactive and pasted text contains newlines, present an inline confirmation dialog showing line count and snippet preview with options to "Paste (Execute Commands)", "Paste as Single Line", or "Cancel", matching modern terminal emulators.

## Commits

- HEAD: fix(client): synchronize bracketed paste and add safe multiline paste confirmation

## Progress

- [x] Worktree rebased onto origin/main and plan documented
- [x] Implement multi-line paste utilities and confirmation dialog
- [x] Update `terminal_pane_stub.dart` and `terminal_pane_web.dart`
- [x] Update `main.dart` to pass `bracketedPasteEnabled` to `TerminalPane`
- [x] Add unit and widget tests
- [x] Run flutter tests and verify clean workspace
- [x] Build Android APK and install to Pixel 10 Pro Fold
