# feat/shell-session-restore

## Agent

- Codex, 2026-05-18T23:59-0700

## Intent

- Add a narrow restore path for recovered plain shell sessions.
- Preserve historical terminal output while allowing eligible shell sessions to restart in their last known working directory.

## Decisions

- Keep arbitrary process resurrection out of scope. Restoring editors, running agents, or foreground programs requires a different process-ownership design.
- Treat shell restore as an explicit action, not the default daemon startup behavior, so restart side effects are client controlled.
- Preserve the original session id during restore so clients do not need a historical-to-live mapping layer.
- Replay the existing raw PTY log into the restarted actor and append future output to the same log so recovered history is not destroyed.
- Keep replay-generated terminal responses isolated from the new shell by replaying history before the restored terminal writer is connected to the live PTY.
- Mark a historical session as restoring before spawning the replacement shell so concurrent restore requests cannot create duplicate PTYs.
- Treat the OSC 7 working directory as advisory and fall back to the original launch cwd when the latest path is no longer usable.

## What Changed

- Added `RestoreSessionRequest` and a default `SessionApi::restore_session` method.
- Forwarded restore requests through the Unix socket transport.
- Added daemon restore logic that transitions eligible historical shell sessions back to live sessions with the same id.
- Restarted shells in the last OSC 7 working directory when available, falling back to the original launch cwd.
- Kept non-shell historical sessions and already-live sessions rejected by restore.
- Added daemon and Unix socket tests for shell restore, cwd selection, log preservation, and rejection behavior.
- Delayed live PTY writer installation until after restored log replay and covered terminal capability query replay with a regression test.
- Added restore in-progress state handling and stale cwd fallback coverage from PR review.

## Progress

- 2026-05-18T23:59-0700 — Created `feat/shell-session-restore` worktree from `origin/main`, unset upstream, and started from the session persistence follow-up.
- 2026-05-19T00:06-0700 — Implemented explicit historical shell restore through the shared session API and Unix socket transport. Validated with `cargo test -p argus-daemon restore`, `cargo test -p argus-daemon`, `cargo fmt --all -- --check`, `cargo check --workspace`, `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`, and `cargo test --workspace`.
- 2026-05-19T00:42-0700 — Fixed restored log replay so terminal replies emitted by historical capability queries are discarded before connecting the terminal sink to the new PTY. Validated with `cargo test -p argus-daemon replay_with_delayed_writer_suppresses_historical_terminal_replies`, `cargo test -p argus-daemon restore`, `cargo test -p argus-daemon`, and `cargo fmt --all -- --check`.
- 2026-05-19T22:54-0700 — Prepared the branch for PR publication after confirming there was no existing PR for `feat/shell-session-restore`.
- 2026-05-20T18:57-0700 — Addressed PR review comments by preventing concurrent restore calls from spawning duplicate shells and by falling back when the last OSC 7 cwd is stale. Validated with `cargo fmt --all -- --check`, `cargo test -p argus-daemon restore`, `cargo test -p argus-daemon`, and `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`.

## Commits

- HEAD — feat: restore historical shell sessions

## Next Steps

- Define the minimal API for restarting an eligible historical shell session.
- Implement daemon-side eligibility checks and restart behavior.
- Validate that non-shell historical sessions stay read-only.
