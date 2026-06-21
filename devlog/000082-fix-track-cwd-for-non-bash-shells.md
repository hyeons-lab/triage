# 000082 — fix/track-cwd-for-non-bash-shells

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/track-cwd-for-non-bash-shells

## Intent

The TUI session side rail always displayed the same repo/branch (the triage
checkout on `main`) for every session, no matter which directory the session was
actually in. Find the cause and fix it.

## Research & Discoveries

- 2026-06-21T11:00-0300 The side rail's repo/branch comes from
  `resolve_session_context(cwd)`, which runs git in the session's tracked
  `current_working_directory`. That field is only updated when
  `OutputState::ingest` parses an OSC 7 escape.
- OSC 7 is emitted by a shell hook injected in `default_shell_request`
  (`crates/triage/src/lib.rs`) via `PROMPT_COMMAND`. `PROMPT_COMMAND` is
  **bash-only** — zsh/fish/etc. ignore it, so no OSC 7 is ever emitted and the
  cwd never updates from its initial value.
- The initial cwd falls back to the daemon's `std::env::current_dir()` (the
  triage checkout) when the create-session request carries no cwd — producing
  the constant "triage / main".
- Empirically confirmed: with the same `PROMPT_COMMAND` set, bash emits the
  OSC 7 sequence on every prompt while zsh emits nothing. The user's shell is
  zsh (the macOS default).
- `libc` is already a unix dependency of `triaged`, and the actor already holds
  the PTY child pid via `child.process_id()`, so reading the child's cwd from
  the kernel (the approach terminal multiplexers use) is the shell-agnostic fix.

## What Changed

- 2026-06-21T11:40-0300 `crates/triaged/src/session.rs` —
  - Added `child_cwd(pid)` (Linux `/proc/<pid>/cwd`; macOS
    `proc_pidinfo(PROC_PIDVNODEPATHINFO)`; `None` elsewhere).
  - Added `CWD_POLL_INTERVAL` (750ms), an `ActorState::apply_cwd` helper
    (extracted from the OSC 7 update path), and `ActorState::poll_child_cwd`
    (throttled OS read using the child pid).
  - `handle_output` now applies the OSC 7 cwd when reported, and otherwise falls
    back to the throttled OS poll — so zsh/fish sessions track their cwd too.
  - Added `last_cwd_poll` to `ActorState` (+ both constructors) and a unit test
    that `child_cwd(std::process::id())` resolves the test process's cwd.
- 2026-06-21T12:05-0300 `crates/triaged/src/session.rs` — gated the OS poll
  behind a new `ActorState::shell_reports_cwd` flag (set the first time a session
  emits OSC 7). OSC 7-capable shells (bash) now skip OS polling entirely after
  their first prompt, so they no longer re-resolve git context every 750ms during
  long command output; only shells that never emit OSC 7 keep polling. Addresses
  PR #94 review feedback.

## Decisions

- 2026-06-21T11:10-0300 Read cwd from the OS instead of fixing the prompt hook
  per shell — reasoning: a prompt-based fix needs a different mechanism for every
  shell (zsh ZDOTDIR precmd, fish, nushell, …) and stays fragile; the OS read is
  one code path that works for all of them.
- 2026-06-21T11:15-0300 Throttle the OS poll to 750ms — reasoning: `apply_cwd`
  shells out to git, and agents repaint their TUI continuously, so an unthrottled
  per-chunk poll would spawn git far too often. git only actually runs when the
  cwd changes, but the throttle bounds the resolve cadence regardless.
- 2026-06-21T12:05-0300 Gate the OS poll behind `shell_reports_cwd` rather than
  relying on the throttle alone — reasoning (from PR #94 review): `apply_cwd`
  re-resolves git on every call, and bash sessions still hit the no-OSC-7 branch
  during long command output, so even with the throttle they would run git every
  750ms. Once a session has proven it emits OSC 7, trusting it and skipping the
  poll removes that redundant work; shells that never emit OSC 7 are unaffected.

## Issues

- Verified the macOS `libc` symbols (`proc_pidinfo`, `proc_vnodepathinfo`,
  `PROC_PIDVNODEPATHINFO`, `vip_path` layout) against libc 0.2.186 before writing
  the FFI; `vip_path` is a flattened `[[c_char; 32]; 32]` NUL-terminated buffer.

## Commits

- HEAD — fix(triaged): track session cwd for shells that do not emit OSC 7
