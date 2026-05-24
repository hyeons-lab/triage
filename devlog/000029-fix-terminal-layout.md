# fix/terminal-layout

## Agent
- Antigravity (Gemini 3.5 Flash) @ triage branch fix/terminal-layout

## Intent
- Resolve the terminal session text wrapping coordinate mismatches and restore historical ANSI styling/colors.

## What Changed
- 2026-05-24T11:51-0700 Created git worktree and branch fix/terminal-layout.
- 2026-05-24T11:51-0700 Restored uncommitted layout, color scrollback, and EOL conversion changes.
- 2026-05-24T12:35-0700 Refactored event listener registration in terminal_pane_web.dart into _bindContainerEvents and handled proper stream subscription disposal during session switching.
- 2026-05-24T12:51-0700 Addressed PR review comments by eliminating the caching of xterm onData/onResize subscriptions and ResizeObservers to prevent memory leaks and callback routing mismatches, cleaning up redundant DOM property queries, and capping the daemon-wide styled scrollback history fetch to a maximum of the last 200 lines to avoid high latency and memory overhead on session load/attach.
- 2026-05-24T13:36-0700 Refactored and hardened terminal pane lifecycle event handling to fully address second-round PR review comments: validated cache integrity on cached attachment, moved attachCustomKeyEventHandler into per-widget subscriptions, reduced minimum fitting layout boundaries, and consolidated styled scrollback history fetch/merge into a shared helper method.

## Decisions
- Wrap xterm.js container inside a native HTML outer and inner nested DivElement wrapper to separate padding margins from xterm.js column coordinate calculations.
- Bind click, keydown, and paste listeners dynamically during session attachment and ensure their subscriptions are cleanly disposed on session switch or unmount.
- Cleanly register and dispose xterm event subscriptions and ResizeObservers during the widget mount lifecycle to ensure no callbacks leak when unmounting or switching cached terminal sessions.
- Cap styled scrollback history loading to the last 200 lines to balance visual color richness and transport latency.
- Validate cache integrity upon container reuse, discarding broken or incomplete caches, and falling back to a fresh init.
- Re-attach custom key event handlers on every session attach to ensure key events are routed to the active widget/controller rather than capturing outdated states in cached terminal closures.
- Allow fitting on legitimately small or responsive split-pane layouts by lowering the minimum dimension check from 50px to 0px.
- Extract the visible/styled scrollback rows merge and history fetch logic into a unified shared helper in main.dart to eliminate code duplication and prevent path drift.

## Commits
- 0fda0f6 — fix: resolve terminal session text wrapping coordinate mismatches and restore colored history
- 52d7113 — fix: add clientWidth and clientHeight > 50 checks inside _onFit
- e04c9f5 — fix: register native JS ResizeObserver on terminal wrapper for real-time fitting
- df9d2d8 — fix: bind container event listeners properly and handle disposal on switch
- e9206b7 — fix: address PR review comments for subscription leaks, client bounds, and capped styled rows
- HEAD — fix: address second-round PR review comments for cache validation, custom key handler closure, small layouts, and shared helper refactoring
