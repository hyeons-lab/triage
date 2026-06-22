# 000084 — Handover restores live session cwd

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/handover-live-cwd

## Intent

Fix: the `triage` side rail shows the repo's default branch ("main") as the
branch for every session. Root cause is handover restoring the wrong cwd, so the
branch resolved from that cwd is wrong for all adopted sessions.

## What Changed

- 2026-06-21T22:24-0300 `crates/triaged/src/session.rs` — new
  `adopted_session_cwd(pid, replayed, launch)` helper that prefers the live
  adopted process's cwd (`child_cwd(pid)`) over the OSC 7 log replay and the
  launch cwd. `spawn_adopted_pty_runtime` now uses it instead of calling
  `restorable_cwd(replayed, launch)` directly. Added a regression test
  (`adopted_session_cwd_prefers_the_live_process_over_replay_and_launch`) that
  spawns a real process and asserts the live cwd wins, with fallback to the
  replayed cwd once the process exits.

## Decisions

- 2026-06-21T22:24-0300 **Read the live cwd at adoption, don't rely on the
  on-output poll.** Adopted sessions are frequently idle (sitting in an agent or
  at a prompt), so the existing `handle_output` cwd poll never fires for them.
  The pid is alive and known at adoption time, so reading it once there fixes the
  branch immediately for any shell, OSC 7 or not.
- 2026-06-21T22:24-0300 **Priority: live > OSC 7 replay > launch dir.** The live
  read is ground truth; the replay is a best-effort historical signal; the launch
  dir is the last resort. `child_cwd` returns `None` if the process has exited or
  its cwd is unreadable, so the chain degrades cleanly.
- 2026-06-21T22:24-0300 Scoped to the handover path only — normal start spawns
  the shell at `config.cwd`, so its initial cwd is already correct.

## Issues

- 2026-06-21T22:24-0300 Diagnosis was non-obvious: detection, `child_cwd`, OSC 7
  parsing, and rendering all work in isolation (unit tests green; verified
  `child_cwd` reads a *separate* live pid on macOS via a `proc_pidinfo` probe).
  The tell was the running daemon being current **and** launched with
  `--handover`, which pointed at `spawn_adopted_pty_runtime` never reading the
  adopted process's real cwd.
- 2026-06-21T22:24-0300 First draft of the test used `tempfile::tempdir()`, but
  `tempfile` is not a triaged dependency (only my new line referenced it).
  Switched to the existing `std::env::temp_dir().join(<unique>)` convention used
  elsewhere in the test module, with explicit `remove_dir_all` cleanup.
- 2026-06-22T00:50-0300 PR #98 review (Copilot): the fallback assertion reused
  the just-reaped child's pid, which a fast system could recycle into an
  unrelated live process — flaky. Switched the fallback call to `u32::MAX` (a pid
  that cannot exist on Linux/macOS), since the helper treats "exited" and
  "unknown pid" identically. Also corrected the plan's lint command to the
  documented `cargo clippy --workspace --all-targets --all-features -- -D warnings`
  (it was missing `--` and `--all-features`); re-ran that exact command — clean.

## Plan

See `devlog/plans/000084-01-handover-live-cwd.md`.

## Commits

- 92be05f — fix(triaged): restore the live cwd of sessions adopted across a handover
- HEAD — test(triaged): use a non-existent pid for the adopted-cwd fallback case
