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
- **2026-09-04T21:07-0700** devlog/plans/000135-02-address-review-feedback.md: created implementation plan for addressing PR #157 review feedback.
- **2026-09-04T21:11-0700** flutter/triage_client/lib/terminal/terminal_paste.dart: added library directive, exported newlinePattern, and converted lineCount to zero-allocation character scan with trailing command newline handling.
- **2026-09-04T21:11-0700** flutter/triage_client/lib/widgets/multiline_paste_dialog.dart: lazily extracted first 6 preview lines, bounded preview line width to 200 characters, and added MB threshold formatting.
- **2026-09-04T21:11-0700** flutter/triage_client/lib/widgets/terminal_pane_stub.dart: added _isPasteDialogShowing re-entrancy lock, exempted single CRLF from multi-line interception in _onTerminalOutput, added post-await session exit checks, and synchronized bracketedPasteEnabled in didUpdateWidget.
- **2026-09-04T21:11-0700** flutter/triage_client/lib/widgets/terminal_pane_web.dart: added _isPasteDialogShowing re-entrancy lock, intercepted multi-line IME data in onDataCallback, restored DOM focus via _activateTerminal post-dialog, and synchronized bracketedPasteEnabled in didUpdateWidget.
- **2026-09-04T21:11-0700** flutter/triage_client/lib/main.dart: simplified SessionVm.setBracketedPasteEnabled to key TerminalPane.setBracketedPasteMode by session title only.
- **2026-09-04T21:11-0700** flutter/triage_client/test/terminal/terminal_paste_test.dart: added unit tests for lineCount edge cases and widget tests for truncated snippet and KB size formatting.

## Decisions

- **Direct Bracketed Paste Mode Propagation**: Pass `bracketedPasteEnabled` directly as a typed boolean property from `SessionVm` into `TerminalPane` on both Web and Native platforms, eliminating reflection and `js_util.getProperty` failures on minified Dart objects.
- **Mobile Soft Keyboard (IME) Multi-Line Interception**: In `terminal_pane_stub.dart`, intercept `data.length > 1 && isMultiLine(data)` in `_onTerminalOutput` so multi-line text committed via Gboard or soft keyboard clipboard chips is routed through `_handlePaste` rather than leaked as raw unbracketed newlines that execute commands line by line.
- **Safety Intercept for Unbracketed Multi-Line Pastes**: When bracketed paste mode is inactive and pasted text contains newlines, present an inline confirmation dialog showing line count and snippet preview with options to "Paste (Execute Commands)", "Paste as Single Line", or "Cancel", matching modern terminal emulators.
- **Re-entrancy Guard on Multi-Line Dialogs**: Track an active dialog lock via `_isPasteDialogShowing` across Web and Native, dropping or ignoring duplicate paste requests until the active confirmation dialog resolves.
- **Post-Await Session Exit Validation**: Verify `!widget.isExited` both at the entry of `_handlePaste` and after the asynchronous confirmation dialog resolves, preventing writes to terminated sessions or closed PTYs.
- **Exemption of Single CRLF Keystrokes**: Exclude `data == '\r\n'` in multi-line IME interception so standard Enter keystrokes from mobile or Bluetooth keyboards execute immediately without warning dialogs.
- **Reactive Bracketed Mode Propagation in didUpdateWidget**: Synchronize `bracketedPasteEnabled` to the underlying emulator and static session maps during `didUpdateWidget`, preventing stale modes from locking permanently.
- **Zero-Allocation Character Scanning for Line Counts**: Replace regular expression `allMatches` matching in `lineCount` with a single-pass ASCII code unit scan over `text.codeUnitAt(i)`, reducing heap allocations to zero and eliminating UI GC spikes on large clipboard buffers.

## Commits

- 19ed977: fix(client): synchronize bracketed paste and add safe multiline paste confirmation
- HEAD: fix(client): address PR #157 review feedback for safe multiline paste

## Progress

- [x] Worktree rebased onto origin/main and plan documented
- [x] Implement multi-line paste utilities and confirmation dialog
- [x] Update `terminal_pane_stub.dart` and `terminal_pane_web.dart`
- [x] Update `main.dart` to pass `bracketedPasteEnabled` to `TerminalPane`
- [x] Add unit and widget tests
- [x] Run flutter tests and verify clean workspace
- [x] Build Android APK and install to Pixel 10 Pro Fold
- [x] Address PR #157 code review feedback
- [x] Add re-entrancy guards and session exit checks
- [x] Exempt single CRLF from multi-line interception
- [x] Implement multi-line IME interception and DOM refocus on Web
- [x] Synchronize bracketedPasteEnabled in didUpdateWidget on Web and Native
- [x] Optimize lineCount with zero-allocation character scan
- [x] Extend test suite with edge cases and widget test coverage
