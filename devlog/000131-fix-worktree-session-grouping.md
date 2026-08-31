# 000131 — fix/fix-worktree-session-grouping

**Agent:** Antigravity (gemini-3.1-pro) @ triage branch fix/fix-worktree-session-grouping

## Intent

Fix the bug where navigating/cding into a git worktree places the session in the `<other>` group instead of grouping it under its parent repository on the session rail.

## Research & Discoveries

- 2026-08-31T13:25-0700 Traced `triaged` daemon session actor CWD tracking in `crates/triaged/src/session.rs`.
- When a shell session spawns, `default_shell_request` injects a wrapper (`/bin/sh -lc '... PROMPT_COMMAND=...; exec "${SHELL:-/bin/sh}"'`).
- The wrapper evaluates `PROMPT_COMMAND` at spawn and emits an initial OSC 7 sequence for `$HOME` (e.g. `/Users/dberrios`).
- `triaged` receives this initial OSC 7 and sets `self.shell_reports_cwd = true`.
- However, when the user's interactive shell (macOS default `zsh` or `fish`) starts via `exec`, it ignores `PROMPT_COMMAND` and never emits OSC 7 on subsequent `cd` commands.
- Because `self.shell_reports_cwd` was set to `true`, both `handle_output` and `refresh_idle_cwd` bypassed OS-level CWD polling (`poll_child_cwd` / `child_cwd` via `proc_pidinfo` on macOS and `/proc/<pid>/cwd` on Linux).
- Consequently, when the user ran `cd worktrees/...`, `triaged` never detected the directory change, never re-resolved `SessionContext`, and never broadcast `SessionContextUpdated`.
- The session was permanently stranded in the daemon's initial `$HOME` directory (outside any git repository) and remained in `<other>` indefinitely.
- Furthermore, `git_repository_root` relied strictly on finding `.git` or `worktrees` components in `git rev-parse --git-common-dir` output; making path canonicalization and bare repository detection resilient ensures all worktree layouts resolve to their parent repository root.

## What Changed

- `crates/triaged/src/session.rs`:
  - Fixed CWD tracking so idle polling and throttled output polling continue to read OS child CWD when no OSC 7 is reported on `cd`.
  - Ensured `refresh_idle_cwd` detects CWD changes for non-OSC-7 shells (zsh/fish) and broadcasts context updates.
  - Hardened `git_repository_root` to handle relative common directories, bare repositories, and diverse worktree layouts.
  - Added unit and integration tests for worktree CWD updates and repository grouping.
- `flutter/triage_client/`:
  - Verified and added unit tests in `session_grouping_test.dart` for worktree session grouping under parent repository.

- **2026-08-31T13:48-0700** Hardened `git_repository_root` to support worktrees created from bare repositories (`repo.git`) while preserving submodule boundary separation (`.git/modules/...`), and added `session_context_resolves_bare_repository_worktree` unit test.

## Decisions

- Retain OSC 7 as the primary immediate CWD reporter when emitted, but do not allow a one-time OSC 7 emission to permanently disable idle OS polling.
- Ensure `apply_polled_cwd` skips expensive `git` context re-resolution when `child_cwd` is unchanged, maintaining microsecond-level performance while accurately tracking directory changes.

## Commits

- 10080c9 — fix(triaged): keep OS CWD polling active for shells and group worktrees with parent repository
- HEAD — fix(triaged): support worktrees created from bare repositories in git_repository_root
