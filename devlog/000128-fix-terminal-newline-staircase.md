# 000128 fix/terminal-newline-staircase

**Agent:** Antigravity (Gemini 3.7 Flash) @ triage branch fix/terminal-newline-staircase

## Intent

Fix terminal newline staircasing for CLI tool and command output in raw-mode sessions while preserving relative cursor movement escape sequences (`\x1b[...D`, `\x1b[...C`) for `agy` logo banners and spinner animations.
Plan: [plans/000128-01-fix-terminal-newline-staircase.md](plans/000128-01-fix-terminal-newline-staircase.md).

## What Changed

- 2026-08-21T10:05-0700 Created branch, worktree, and plan to implement smart newline translation in `triaged` and `triage_client`.
- 2026-08-21T10:09-0700 Implemented `is_followed_by_relative_cursor_movement` and `translate_newlines` in `crates/triaged/src/session.rs` for `OutputState::ingest` and `OutputState::advance_replayed_bytes`.
- 2026-08-21T10:09-0700 Implemented `_isFollowedByRelativeCursorMovement` and `_translateNewlines` in `flutter/triage_client/lib/terminal/terminal_store.dart` with cross-chunk `_pendingCarriageReturn` tracking and Mode 2026 synchronized output passthrough.
- 2026-08-21T10:09-0700 Added unit tests in Rust and Flutter and verified the entire workspace test suite passes (276 Rust tests, 341 Flutter tests).

## Decisions

2026-08-21T10:05-0700 Use pattern-based relative cursor movement detection:
- If `\n` is followed by CSI cursor horizontal relative moves (`\x1b[<N>D` / `\x1b[<N>C`), preserve `\n` as bare `\n` to keep the current cursor column index intact for relative adjustments (`agy` logo / spinner).
- For all other `\n` (followed by text, whitespace, digits, newlines, or non-relative escape sequences like SGR colors `\x1b[...m`), translate `\n` to `\r\n` so CLI output (e.g. `cera-cli`, `llama-cli`, `println!`, JSON) starts at column 0 without staircasing.

## Commits

- HEAD — fix(triaged): eliminate terminal newline staircasing while preserving relative cursor movements
