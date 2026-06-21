# Plan 000082-01 — Track session cwd for non-bash shells

## Thinking

The TUI side rail always showed the same repo/branch (the triage checkout on
`main`) for every session, regardless of the directory the session was actually
working in.

`resolve_session_context(cwd)` derives the repo/branch by running git in the
session's tracked `current_working_directory`. That field is only updated when
`OutputState::ingest` parses an **OSC 7** escape (`ESC ]7;file://…`). Triage
emits OSC 7 from a shell hook it injects in `default_shell_request`:

```
export PROMPT_COMMAND='…printf "\033]7;file://…" …'; exec "${SHELL:-/bin/sh}"
```

`PROMPT_COMMAND` is a **bash-only** feature. zsh (the macOS default and this
user's shell), fish, and others ignore it entirely, so OSC 7 is never emitted
and the cwd never moves off its initial value. The initial value falls back to
the daemon's own `std::env::current_dir()` (the triage checkout) when the
create-session request carries no cwd — hence "always triage / main".

Confirmed empirically: bash emits the OSC 7 on every prompt; zsh emits nothing
with the same `PROMPT_COMMAND` set.

Rather than patch the prompt hook per-shell (fragile; zsh needs a ZDOTDIR
precmd hook, fish needs yet another, etc.), read the PTY child's working
directory directly from the kernel — the shell-agnostic approach terminal
multiplexers use. `libc` is already a unix dependency and the actor already has
the child pid via `child.process_id()`.

## Plan

1. Add `child_cwd(pid)`:
   - Linux: `read_link("/proc/<pid>/cwd")`.
   - macOS: `proc_pidinfo(PROC_PIDVNODEPATHINFO)` → `pvi_cdir.vip_path`.
   - other: `None`.
2. Add `ActorState::apply_cwd` (extract the existing OSC 7 update/broadcast
   logic) and `ActorState::poll_child_cwd` (throttled OS read,
   `CWD_POLL_INTERVAL = 750ms`, so git is not re-run on every output chunk).
3. In `handle_output`: when the shell reports a cwd via OSC 7, apply it; when it
   does not, fall back to the throttled OS poll.
4. Unit test: `child_cwd(std::process::id())` resolves the test process's cwd.
5. `cargo fmt`, `cargo clippy`, `cargo test` for `triaged`.

## Notes

- The PTY child is the interactive shell; its cwd reflects the user's `cd` even
  while an agent (e.g. claude) runs in the foreground, which is the directory the
  side rail should show.
- A separate fix (PR #93) stops triage leaking its own Claude session env into
  spawned agents; this change is independent of that one.
