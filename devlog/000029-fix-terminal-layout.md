# fix/terminal-layout

## Agent
- Antigravity (Gemini 3.5 Flash) @ triage branch fix/terminal-layout

## Intent
- Resolve the terminal session text wrapping coordinate mismatches and restore historical ANSI styling/colors.

## What Changed
- 2026-05-24T11:51-0700 Created git worktree and branch fix/terminal-layout.
- 2026-05-24T11:51-0700 Restored uncommitted layout, color scrollback, and EOL conversion changes.

## Decisions
- Wrap xterm.js container inside a native HTML outer and inner nested DivElement wrapper to separate padding margins from xterm.js column coordinate calculations.

## Commits
- 0fda0f6 — fix: resolve terminal session text wrapping coordinate mismatches and restore colored history
- HEAD — fix: add clientWidth and clientHeight > 50 checks inside _onFit
