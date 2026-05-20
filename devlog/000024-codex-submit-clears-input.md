# codex-submit-clears-input

## Agent
- Codex

## Intent
- Fix stale submitted Codex text remaining visible in the Argus TUI input area after the child TUI scrolls.

## Progress
- 2026-05-19T19:51-0700 — Created a focused bugfix worktree from `origin/main` and started tracing the terminal snapshot/rendering path for stale input cells after submit.
- 2026-05-19T19:54-0700 — Added a styled-row consistency guard in the TUI and normalized daemon styled cells beyond the logical line width to spaces, preventing stale submitted prompt text from being rendered from outdated cell contents.
- 2026-05-19T20:22-0700 — Addressed PR review feedback by measuring logical row width in terminal columns and sharing the styled-row text matcher between TUI app state and rendering.
- 2026-05-19T20:22-0700 — Re-ran focused daemon/TUI regressions plus workspace check, clippy, tests, and diff whitespace validation after the review fixes.

## What Changed
- Rejected styled row slices in the TUI when their text no longer matches the plain visible rows for the same range.
- Preserved terminal cell styles while converting cells beyond a row's logical text width to spaces in daemon styled-row snapshots.
- Measured daemon logical row width with terminal display columns so combining characters and wide glyphs do not leave stale cells visible.
- Moved the styled-row/visible-row consistency check to the TUI library and made it compare across spans without constructing a row string.
- Added regression coverage for stale styled prompt text after line clear and for TUI fallback when styled rows disagree with visible rows.

## Commits
- HEAD — fix: clear stale styled terminal input
