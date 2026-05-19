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
- Added review fixes for manifest persistence failure handling: manifest replacement now works when `sessions.json` already exists on Windows, the previous manifest is restored if replacement installation fails, `start_session` rolls back and shuts down a spawned actor when manifest persistence fails, and `shutdown_session` keeps the session registered when manifest persistence fails.
- Collapsed the start-session rollback shutdown guard to satisfy the CI clippy configuration without changing rollback behavior.

## Commits

- c23e756 — feat: persist session histories
- 160903f — fix: roll back sessions on manifest failure
- HEAD — fix: satisfy clippy for session rollback

## Progress

- 2026-05-18T21:49-0700 — Created `feat/session-persistence` worktree from `origin/main`, unset upstream, and confirmed the persistence branch should not stack on the open MCP PR.
- 2026-05-18T22:09-0700 — Implemented manifest-backed historical session recovery and validated with `cargo fmt --all` and `cargo test -p argus-daemon`.
- 2026-05-18T23:25-0700 — Addressed review feedback that TUI startup subscribes to every listed session before attach. Verified the regression failed before the fix, then passed with `cargo test -p argus-daemon session_manager_restores_historical_sessions_from_manifest`, `cargo test -p argus-daemon`, and `cargo fmt --all -- --check`.
- 2026-05-18T23:42-0700 — Addressed PR review feedback for manifest persistence failures. Added regression tests for replacing an existing manifest, restoring the previous manifest when backup replacement fails, rolling back a spawned session when start persistence fails, and keeping a session registered when shutdown persistence fails; validated with `cargo test -p argus-daemon session_manager_`, `cargo test -p argus-daemon manifest_backup_replace_restores_existing_manifest_when_install_fails`, `cargo test -p argus-daemon`, and `cargo fmt --all -- --check`.
- 2026-05-18T23:50-0700 — Fixed the CI clippy failure in the start-session rollback path. Validated with `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings` and `cargo test -p argus-daemon`.

## Next Steps

- Add a follow-up shell-restore mode that can restart plain shell sessions in their last cwd while preserving recovered history.
- Decide whether true live-process recovery should use long-lived session workers before attempting process resurrection.
