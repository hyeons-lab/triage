# fix/terminal-layout

## Agent
- Antigravity (Gemini 3.5 Flash) @ triage branch fix/terminal-layout

## Intent
- Resolve the terminal session text wrapping coordinate mismatches and restore historical ANSI styling/colors.

## What Changed
- 2026-05-24T11:51-0700 Created git worktree and branch fix/terminal-layout.
- 2026-05-24T11:51-0700 Restored uncommitted layout, color scrollback, and EOL conversion changes.
- 2026-05-24T12:35-0700 Refactored event listener registration in terminal_pane_web.dart into _bindContainerEvents and handled proper stream subscription disposal during session switching.

## Decisions
- Wrap xterm.js container inside a native HTML outer and inner nested DivElement wrapper to separate padding margins from xterm.js column coordinate calculations.
- Bind click, keydown, and paste listeners dynamically during session attachment and ensure their subscriptions are cleanly disposed on session switch or unmount.

## Commits
- 0fda0f6 — fix: resolve terminal session text wrapping coordinate mismatches and restore colored history
- 52d7113 — fix: add clientWidth and clientHeight > 50 checks inside _onFit
- e04c9f5 — fix: register native JS ResizeObserver on terminal wrapper for real-time fitting
- HEAD — fix: bind container event listeners properly and handle disposal on switch
