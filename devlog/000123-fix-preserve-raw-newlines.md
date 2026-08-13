# 000123 — fix/preserve-raw-newlines

**Agent:** Antigravity (Gemini 3.6 Flash) @ triage branch fix/preserve-raw-newlines

## Intent

Fix `antigravity` (`agy` CLI) logo banner and prompt rendering corruption caused by forced `\n` -> `\r\n` newline translation in the daemon and web client terminal pipeline.

## Research & Discoveries

- 2026-08-13T11:56-0700 — Analyzed PTY raw byte streams emitted by `agy` CLI:
  - `agy` outputs banner rows using raw `\n` (Line Feed) without `\r` (Carriage Return) to preserve cursor column position (~40), followed by relative cursor movement (`\x1b[35D`, Cursor Back 35 columns) to position column 5 for drawing the body of the logo.
  - In VT100/ANSI terminal emulation, raw `\n` in raw TTY mode advances the row while leaving the cursor column index unchanged.
  - `triaged` (`crates/triaged/src/session.rs` via `translate_newlines`) and `triage_client` (`flutter/triage_client/lib/terminal/terminal_store.dart` via `_normalizeNewlines`) forcibly translated bare `\n` to `\r\n`.
  - The injected `\r` reset the cursor column to 0 before `\x1b[35D` executed, causing `\x1b[35D` to clamp at column 0 instead of moving to column 5. Subsequent logo rows rendered 5 columns to the left of row 1, causing severe visual corruption and prompt misalignment.
  - Cooked-mode shell commands naturally emit `\r\n` via the kernel PTY driver's `ONLCR` flag; raw-mode applications explicitly turn off `ONLCR` to emit raw `\n`. Forcing `\r\n` violated TTY raw-mode contracts.

## Decisions

- 2026-08-13T11:56-0700 — Remove forced newline translation (`_normalizeNewlines` in Flutter client `TerminalStore` and `translate_newlines` in daemon `OutputState`).
- Pass raw PTY bytes directly to terminal emulators (`xterm.js` and `wezterm_term`), preserving authentic ANSI cursor positioning behavior for raw-mode applications while leaving cooked-mode PTY `\r\n` streams intact.

## What Changed

- `flutter/triage_client/lib/terminal/terminal_store.dart` — Removed `_normalizeNewlines` and `_pendingCarriageReturn` carry state.
- `flutter/triage_client/test/terminal/terminal_store_test.dart` — Updated store reducer tests to expect raw `\n` preservation.
- `crates/triaged/src/session.rs` — Removed `translate_newlines` helper function and its invocations in `OutputState::ingest` and `OutputState::replay`. Updated unit tests.

## Commits

- HEAD — fix: preserve raw newlines in terminal pipeline to fix agy logo rendering

## Progress

- 2026-08-13T11:56-0700 — Created worktree, plan, and devlog.

## Next Steps

- Apply changes to `terminal_store.dart`, `session.rs`, and test files.
- Run test suites and verify build.
