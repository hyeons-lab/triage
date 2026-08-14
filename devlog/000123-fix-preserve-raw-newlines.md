# 000123 — fix/preserve-raw-newlines

**Agent:** Antigravity (Gemini 3.6 Flash) @ triage branch fix/preserve-raw-newlines

## Intent

Fix `antigravity` (`agy` CLI) logo banner and prompt rendering corruption caused by forced `\n` -> `\r\n` newline translation in the daemon and web client terminal pipeline. Filter synthetic terminal emulator query auto-responses to prevent phantom keystroke injection and session freezes. Remove competing DOM window keydown dispatch to prevent double-keystroke race conditions.

## Research & Discoveries

- 2026-08-13T11:56-0700 — Analyzed PTY raw byte streams emitted by `agy` CLI:
  - `agy` outputs banner rows using raw `\n` (Line Feed) without `\r` (Carriage Return) to preserve cursor column position (~40), followed by relative cursor movement (`\x1b[35D`, Cursor Back 35 columns) to position column 5 for drawing the body of the logo.
  - In VT100/ANSI terminal emulation, raw `\n` in raw TTY mode advances the row while leaving the cursor column index unchanged.
  - `triaged` (`crates/triaged/src/session.rs` via `translate_newlines`) and `triage_client` (`flutter/triage_client/lib/terminal/terminal_store.dart` via `_normalizeNewlines`) forcibly translated bare `\n` to `\r\n`.
  - The injected `\r` reset the cursor column to 0 before `\x1b[35D` executed, causing `\x1b[35D` to clamp at column 0 instead of moving to column 5. Subsequent logo rows rendered 5 columns to the left of row 1, causing severe visual corruption and prompt misalignment.
  - Cooked-mode shell commands naturally emit `\r\n` via the kernel PTY driver's `ONLCR` flag; raw-mode applications explicitly turn off `ONLCR` to emit raw `\n`. Forcing `\r\n` violated TTY raw-mode contracts.
- 2026-08-13T16:16-0700 — Analyzed web terminal emulator options and terminal query auto-response feedback loops:
  - Found `convertEol: true` in `flutter/triage_client/lib/widgets/terminal_pane_web.dart` (line 474) which caused `xterm.js` to convert `\n` to `\r\n`, resetting the cursor column on web even after Dart store normalization was removed. This corrupted `agy` spinner/loading indicator ("Thinking...", "Generating...") animations and interactive prompt cursor positioning (`\x1b[13D`, `\x1b[52D`).
  - Traced session freezes and random characters (`24;1R?1;2c?0u...`) to terminal capability query auto-responses. When `agy` or other interactive TUIs emit terminal queries (CPR `\x1b[6n`, DA `\x1b[c`, Kitty query `\x1b[?u`, DECRQM mode queries), `xterm.js`/`xterm.dart` automatically produces answer escape sequences. Because `isSuppressingHostInput` only checked a 50ms window during history replay, live query answers were forwarded via `writeInput` into PTY stdin as user keystrokes.
- 2026-08-13T19:15-0700 — Traced fast-typing input scramble (`for ` -> `orf`) and misplaced prompt characters:
  - `terminal_pane_web.dart` had two competing input mechanisms active at the same time:
    1. `_windowKeyDownListener` on `html.window` with `useCapture = true` manually mapping keys via `_keyboardEventToInput` and sending them to `_sessionInputRouter.sendInput`.
    2. `_onDataSubscription` on `_term.onData` forwarding xterm.js's native input.
  - On fast typing or IME/composition, both handlers raced to dispatch keystrokes, resulting in out-of-order delivery (`for ` -> `orf`) and dropped Ctrl/Option navigation shortcuts (which `_keyboardEventToInput` returned `null` for).
  - Removing `_keyboardEventToInput` and duplicate `_sendInput` from `_windowKeyDownListener` allows `xterm.js` to natively own all keyboard input, IME, and shortcut encoding via `onData` in exact FIFO sequence.

## Decisions

- 2026-08-13T11:56-0700 — Remove forced newline translation (`_normalizeNewlines` in Flutter client `TerminalStore` and `translate_newlines` in daemon `OutputState`).
- Pass raw PTY bytes directly to terminal emulators (`xterm.js` and `wezterm_term`), preserving authentic ANSI cursor positioning behavior for raw-mode applications while leaving cooked-mode PTY `\r\n` streams intact.
- 2026-08-13T16:16-0700 — Remove `convertEol: true` from `terminal_pane_web.dart`.
- 2026-08-13T16:16-0700 — Introduce `isEmulatorQueryResponse` to identify and drop all synthetic terminal emulator responses (CPR, DA1, DA2, DA3, DSR, Kitty query answers, DECRPM mode reports, OSC 10/11 color reports, window size reports) before they can reach `writeInput`.
- 2026-08-13T16:16-0700 — Guard `TerminalStore._writeDecoded` with `_isWritingSink` so synchronous emulator output during writes is ignored.
- 2026-08-13T19:15-0700 — Delegate keyboard input entirely to `xterm.js`'s `onData` pipeline in `terminal_pane_web.dart` and remove manual keydown capture duplication.

## What Changed

- `flutter/triage_client/lib/terminal/terminal_store.dart` — Removed `_normalizeNewlines` and `_pendingCarriageReturn` carry state; added query filtering and write suppression guard.
- `flutter/triage_client/lib/widgets/terminal_pane_web.dart` — Removed `convertEol: true`; removed `_keyboardEventToInput` and duplicate window keydown dispatch so `xterm.js` owns keyboard input natively.
- `flutter/triage_client/lib/terminal/emulator_query_response.dart` — Added `isEmulatorQueryResponse` utility.
- `flutter/triage_client/lib/main.dart` — Added `isEmulatorQueryResponse` check in `_setupSessionInputListener`.
- `flutter/triage_client/test/terminal/emulator_query_response_test.dart` — Added tests for query response recognition.
- `flutter/triage_client/test/terminal/terminal_store_test.dart` — Updated store reducer tests to expect raw `\n` preservation and live query response filtering.
- `crates/triaged/src/session.rs` — Removed `translate_newlines` helper function and its invocations in `OutputState::ingest` and `OutputState::replay`. Updated unit tests.

## Commits

- 74abd4d — fix: preserve raw newlines in terminal pipeline to fix agy logo rendering
- 5f63f88 — fix(triage_client): remove convertEol and filter terminal query auto-responses
- HEAD — fix(triage_client): unify web keyboard input under xterm.js onData

## Progress

- 2026-08-13T11:56-0700 — Created worktree, plan, and devlog.
- 2026-08-13T16:16-0700 — Created plan 02, removed `convertEol: true`, added `emulator_query_response.dart`, updated `terminal_store.dart` and `main.dart`, validated all tests.
- 2026-08-13T19:15-0700 — Removed duplicate window keydown dispatch in `terminal_pane_web.dart`, re-built web bundle, updated triaged binary, and performed zero-downtime handover.

## Next Steps

- Commit and push to PR branch.
