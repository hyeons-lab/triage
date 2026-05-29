# 000043 fix/daemon-input-after-restart

## Agent

Codex

## Intent

Restore a native interactive prompt for Flutter-created daemon sessions on Windows after the merged session-loading changes.

## Progress

- 2026-05-28T19:51-0700 - Created the fresh post-merge worktree and confirmed daemon input works through direct WebSocket probes. Isolated the remaining prompt issue to Flutter creating `bash` before `cmd.exe` on Windows.
- 2026-05-28T21:21-0700 - Rebuilt and installed the updated client and daemon. Verified the served bundle contains the shell selector and a fresh WebSocket-created `cmd.exe` session snapshots with Windows prompt rows.
- 2026-05-28T21:41-0700 - Moved shell selection into the plus button menu, kept `cmd.exe` first only on Windows, rebuilt the web bundle, reinstalled `triaged`, and verified the restarted daemon serves the updated bundle.

## What Changed

- Added a Flutter new-session plus menu for `cmd.exe` and `bash`, ordering `cmd.exe` first on Windows and `bash` first on other platforms while retaining fallback behavior.
- Forced a post-create daemon snapshot refresh for new sessions so prompt bytes emitted during startup are replayed into the mounted terminal.
- Extended widget coverage for platform shell ordering, plus-menu shell selection, fallback command, and post-create snapshot refresh.

## Issues

- Browser automation was unavailable in this environment, so verification used Flutter widget tests, a rebuilt local web bundle, and direct WebSocket probes against the running daemon.

## Commits

- HEAD - fix: add shell menu for Flutter sessions
