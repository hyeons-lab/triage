# 000084-01 — Handover restores live session cwd

## Thinking

Bug report: the `triage` side rail shows the repo's default branch ("main") as
the branch for *every* session.

Investigation (the detection pieces all work in isolation):

- `git -C <worktree> branch --show-current` returns the correct per-worktree
  branch; `resolve_session_context` runs it against the session's tracked cwd.
- `child_cwd(pid)` reads another live process's cwd fine on this macOS (verified
  with a `proc_pidinfo`/`PROC_PIDVNODEPATHINFO` probe against a separate pid).
- All cwd/context unit tests pass; the side rail renders per-session
  `context.branch`.
- The running daemon is current (built today, after the #94 cwd-tracking fix) and
  is running with `--handover`.

So the branch is wrong because the session's *tracked cwd* is wrong, and the
common factor is **handover**. In `spawn_adopted_pty_runtime`, an adopted
session's cwd was restored as:

```
restorable_cwd(replayed_working_directory, h_sess.cwd)
```

- `replayed_working_directory` = the last cwd seen by replaying **OSC 7** reports
  in the session log. zsh/fish (macOS default is zsh) never emit OSC 7, so this
  is `None`.
- `h_sess.cwd` = the **original launch directory**.

Nothing reads the adopted process's *actual* cwd — even though its pid is alive
and `child_cwd` works. Result: after a handover, every non-OSC-7 session comes
back pinned to its launch directory, so the rail shows the launch branch
("main") for all of them, and stays there while the session is idle (no output ⇒
the on-output cwd poll never runs).

Fix: at adoption, read the live process cwd via `child_cwd(h_sess.pid)` and
prefer it over the OSC 7 replay and the launch cwd. Falls back gracefully if the
process has since exited.

## Plan

1. Add `adopted_session_cwd(pid, replayed, launch)` next to `restorable_cwd`:
   `restorable_cwd(child_cwd(pid).or(replayed), launch)` — live cwd wins, then
   OSC 7 replay, then launch dir.
2. Use it in `spawn_adopted_pty_runtime` in place of the direct `restorable_cwd`.
3. Regression test with a real live process: a `sleep` in `live/` must win over
   distinct `replayed/` and `launch/` dirs; after the process is killed, the
   resolver falls back to `replayed/`.
4. Validate: `cargo clippy --workspace --all-targets --all-features -- -D warnings`
   (the documented lint command) + `triaged` test suite.

Out of scope: the normal (non-handover) start path already spawns the shell at
`config.cwd`, so its initial cwd is correct and the on-output poll keeps it
fresh.
