# Plan 000081-01 — Scrub inherited agent session env on spawn

## Thinking

Sessions launched by `triaged` in another repo (e.g. `pipette-clients`) never
appeared in Claude Code's `/resume`. Investigation showed the spawned `claude`
process had `CLAUDE_CODE_CHILD_SESSION=1` (plus a stale `CLAUDE_CODE_SESSION_ID`
from version `2.1.178`) in its environment, which makes Claude Code treat itself
as a nested child session and skip writing a resumable `<id>.jsonl` transcript —
so the project's session folder held only `subagents/`/`tool-results/` side-data
and `/resume` listed nothing.

Tracing the parent chain confirmed `~/.cargo/bin/triaged` is the launcher, and
inspecting the live daemon's environment (`ps eww`) showed it was itself polluted
with those markers — the daemon had at some point been (re)started from *inside*
a Claude Code session and captured them. `spawn_pty_runtime` builds the agent via
`portable_pty::CommandBuilder::new`, whose `new()` seeds the child environment
from `std::env::vars_os()` (verified in portable-pty 0.9.0 `get_base_env`). With
no scrubbing, every agent inherits the daemon's leaked markers.

"It used to work" because the daemon was previously started from a clean
environment (login/launchd); only this restart-from-within-claude polluted it.

Fix: strip the session-identity markers from the `CommandBuilder` before spawn so
each agent starts as a fresh top-level session regardless of how the daemon was
launched. `CommandBuilder::env_remove` deletes the seeded base-env entry, so this
works even though the markers come from the inherited environment. Leave user
preferences such as `CLAUDE_EFFORT` intact.

## Plan

1. Add `INHERITED_AGENT_SESSION_ENV` constant listing the markers to strip:
   `CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID`,
   `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_EXECPATH`, `AI_AGENT`.
2. Add `scrub_inherited_agent_session_env(&mut CommandBuilder)` helper.
3. Call it in `spawn_pty_runtime` after the command/args/cwd are configured.
4. Unit test: seed the markers + a preference, scrub, assert markers gone and
   `CLAUDE_EFFORT` preserved.
5. `cargo fmt`, `cargo clippy`, `cargo test` for `triaged`.
