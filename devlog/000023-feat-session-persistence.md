# feat/session-persistence

## Agent

- Codex, 2026-05-18T21:49-0700

## Intent

- Persist enough daemon session metadata to recover terminal histories after daemon restart.
- Start with content recovery from raw PTY logs and manifest metadata, not live process resurrection.

## Decisions

- Store the manifest beside session logs in the daemon session state directory so the recovery path is local to `SessionManager`.
- Treat restored sessions as historical/exited sessions in this branch. Restarting plain shells is a follow-up because it changes process lifecycle semantics.
- Use a new `000023` devlog sequence even though this worktree's highest checked-in devlog is `000021`, because open PR #26 already uses `000022`.
- 2026-05-18T23:25-0700 — Support restored-session event subscriptions with an inert closed stream so clients that subscribe before attaching, including the TUI startup path, can still display recovered historical sessions.

## What Changed

- Added a daemon session manifest at `sessions.json` beside the existing raw PTY logs.
- Persisted live session launch metadata after `SessionManager::start_session` succeeds.
- Restored manifest entries as historical sessions by replaying raw PTY logs into the daemon terminal model on `SessionManager` startup.
- Kept restored sessions observable through `list_sessions`, `attach_session`, `snapshot_session`, `styled_rows`, and an inert event subscription, while rejecting input, lease acquisition, and resize for historical sessions.
- Added daemon tests for manifest creation, log replay recovery, historical input rejection, and session id allocation after restored ids.
- Added a review regression test covering event subscription for restored historical sessions, then changed historical subscriptions to return a closed receiver instead of an error.

## Commits

- HEAD — feat: persist session histories

## Progress

- 2026-05-18T21:49-0700 — Created `feat/session-persistence` worktree from `origin/main`, unset upstream, and confirmed the persistence branch should not stack on the open MCP PR.
- 2026-05-18T22:09-0700 — Implemented manifest-backed historical session recovery and validated with `cargo fmt --all` and `cargo test -p argus-daemon`.
- 2026-05-18T23:25-0700 — Addressed review feedback that TUI startup subscribes to every listed session before attach. Verified the regression failed before the fix, then passed with `cargo test -p argus-daemon session_manager_restores_historical_sessions_from_manifest`, `cargo test -p argus-daemon`, and `cargo fmt --all -- --check`.

## Next Steps

- Add a follow-up shell-restore mode that can restart plain shell sessions in their last cwd while preserving recovered history.
- Decide whether true live-process recovery should use long-lived session workers before attempting process resurrection.
