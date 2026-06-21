# 000081 — fix/scrub-claude-session-env-on-spawn

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/scrub-claude-session-env-on-spawn

## Intent

Sessions launched by `triaged` in other repos never showed up in Claude Code's
`/resume`. Find out why and fix it in triage.

## Research & Discoveries

- 2026-06-21T09:30-0300 The current Claude session had `CLAUDE_CODE_CHILD_SESSION=1`
  in its environment. Claude Code treats that (and the presence of `CLAUDECODE` /
  a session id) as "I am a nested child session" and does **not** write a
  resumable `<id>.jsonl` transcript — only `subagents/`/`tool-results/` side-data.
  With no transcript, `/resume` (which lists `<id>.jsonl` for the cwd) shows nothing.
- Parent process chain: `claude` ← spawned by `~/.cargo/bin/triaged` (the daemon).
- `ps eww` on the live `triaged` daemon showed its own environment already carried
  `CLAUDECODE=1`, `CLAUDE_CODE_CHILD_SESSION=1`, a stale
  `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`, and
  `AI_AGENT=claude-code_2-1-178_agent` — fingerprint of an older Claude version
  (`2.1.178`) than the running client (`2.1.185`). The daemon had been
  (re)started from inside a Claude session and captured those markers.
- `spawn_pty_runtime` (`crates/triaged/src/session.rs`) builds the agent with
  `portable_pty::CommandBuilder::new`. In portable-pty 0.9.0, `new()` seeds the
  child environment from `std::env::vars_os()` (`get_base_env`), so with no
  scrubbing every spawned agent inherits the daemon's leaked markers.
- "Used to work": the daemon was previously started from a clean environment;
  only the restart-from-within-claude polluted it.

## What Changed

- 2026-06-21T09:47-0300 `crates/triaged/src/session.rs` — added
  `INHERITED_AGENT_SESSION_ENV` (the agent session-identity markers) and
  `scrub_inherited_agent_session_env(&mut CommandBuilder)`, and call it in
  `spawn_pty_runtime` after command/args/cwd setup. Strips the markers so each
  spawned agent starts as a fresh top-level session regardless of how `triaged`
  itself was launched. `CLAUDE_EFFORT` (a user preference) is intentionally kept.
  Added a unit test asserting the markers are removed and `CLAUDE_EFFORT` survives.

## Decisions

- 2026-06-21T09:40-0300 Scrub at spawn time rather than relying on a clean daemon
  environment — reasoning: makes the fix robust to the daemon being started from
  anywhere (including from inside a Claude session), which is exactly the failure
  mode observed.
- 2026-06-21T09:40-0300 Keep `CLAUDE_EFFORT` — it's a user preference, not a
  session-identity marker, and is not what triggers child-session detection.

## Issues

- `CommandBuilder::env_remove` only works because `new()` pre-seeds `envs` from
  the base environment; verified in the portable-pty 0.9.0 source before relying
  on it.

## Commits

- HEAD — fix(triaged): scrub inherited agent session env before spawning agents
