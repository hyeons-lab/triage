## Thinking

The repository's `skills/triage-coordination/SKILL.md` and the installed `~/.gemini/config/skills/triage-coordination/SKILL.md` predate the newer `triage-mcp` coordinator tools (`wait_for_sessions`, `list_templates`, `list_hosts`, and `start_session` template/task/parent_session_id/outlive_parent/host support) and read like a low-level mail manual rather than a coordinator workflow. Meanwhile AGY's `swarm` skill gives strong operational discipline for parallel multi-agent coordination: keep the coordinator focused on splitting, dispatching, waiting, and judging rather than doing inline edits; keep ownership strictly disjoint per worktree/file; keep teams lean with independent verifiers; make initial briefs self-contained; run a cheap blocking coordinator loop (`wait_for_sessions` / `wait_for_session_message`); replace stuck workers; and integrate worktrees before shutdown.

## Plan

1. Rewrite `skills/triage-coordination/SKILL.md` in `worktrees/swarm-coordination-skill` using the coordinator structure inspired by AGY's `swarm` skill while documenting only the real, implemented `triage-mcp` tool suite (`list_sessions`, `list_templates`, `list_hosts`, `start_session`, `shutdown_session`, `send_session_message`, `receive_session_messages`, `wait_for_session_message`, `wait_for_sessions`, `ack_session_messages`, `snapshot_session`, `styled_rows`).
2. Keep existing worker contracts, security/trust boundaries, and limits intact, and avoid em dashes or unimplemented abstractions.
3. Sync the updated `SKILL.md` to `/Users/dberrios/.gemini/config/skills/triage-coordination/SKILL.md`, update devlog `000191`, and commit on `feat/swarm-coordination-skill`.
4. Push all 7 unpushed stacked branches with explicit refspecs (`HEAD:refs/heads/<branch>`), create PRs with chained `--base` branches, and link them as a GitHub stack via `gh stack link`.
