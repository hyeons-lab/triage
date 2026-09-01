# 000131-01 — Worktree Session Grouping Fix

## Thinking

1. When navigating into a git worktree, a session should be grouped with other sessions belonging to that repository.
2. Root Cause Analysis:
   - On macOS/Linux, `default_shell_request` wraps the shell in `/bin/sh` with `PROMPT_COMMAND` OSC 7 reporting.
   - At startup, the wrapper emits an OSC 7 sequence, which sets `self.shell_reports_cwd = true` in `triaged`.
   - When the user's interactive shell (`zsh` or `fish`) executes, it does not emit OSC 7 on `cd`.
   - `handle_output` and `refresh_idle_cwd` both had guards `if self.shell_reports_cwd { return; }` / `None if !self.shell_reports_cwd =>`.
   - Because `shell_reports_cwd` was `true`, `triaged` stopped reading the child process CWD from the OS.
   - Consequently, `cd` was ignored, `context` was never re-resolved, and `repository_root` remained `None`, causing the session to remain under `<other>`.
3. Solution:
   - Make idle CWD polling (`refresh_idle_cwd`) active whenever the child process is alive, comparing `child_cwd` against `current_working_directory` (a 2µs syscall).
   - Only call `apply_cwd` when the OS-reported `cwd` actually changes, preventing redundant `git` subprocess executions.
   - In `handle_output`, when OSC 7 is explicitly provided, update immediately; when not provided, allow throttled polling if CWD might have changed.
   - Harden `git_repository_root` in `crates/triaged/src/session.rs` to handle relative paths, bare repositories, and diverse worktree topologies.
   - Add unit tests verifying `refresh_idle_cwd` and `apply_cwd` for worktrees and non-OSC-7 shells.
   - Add unit tests in Flutter client `session_grouping_test.dart` to verify linked worktrees group under the parent repository.

## Plan

1. In `crates/triaged/src/session.rs`:
   - Update `refresh_idle_cwd()` and `handle_output()` so OS-level CWD polling is never permanently suppressed by a one-off OSC 7 event.
   - Ensure `apply_polled_cwd()` only triggers `apply_cwd()` when `cwd` has changed.
   - Harden `git_repository_root()` to support relative git common directories, bare repositories, and worktree layouts.
2. In `flutter/triage_client/test/session_grouping_test.dart`:
   - Add tests verifying linked worktree sessions group with the main repository sessions.
3. Validate:
   - Run `cargo fmt --all -- --check`
   - Run `cargo clippy --all-targets --all-features -- -D warnings`
   - Run `cargo test --workspace`
   - Run `flutter test`
4. Stage, commit, and prepare PR.
