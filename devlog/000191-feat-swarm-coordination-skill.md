# Devlog 000191: feat/swarm-coordination-skill

**Agent:** Gemini @ triage branch `feat/swarm-coordination-skill`

## Intent

Update `skills/triage-coordination/SKILL.md` so it follows the coordinator pattern from AGY's `swarm` skill while covering the `triage-mcp` role templates, remote hosts, parent lifecycle tracking, and `wait_for_sessions` tools introduced in the stack.

## Progress

- [x] Write plan (`devlog/plans/000191-01-swarm-coordination-skill.md`)
- [x] Update `skills/triage-coordination/SKILL.md` (and local `~/.gemini/config/skills/triage-coordination/SKILL.md`)
- [x] Commit skill and devlog updates on `feat/swarm-coordination-skill`
- [ ] Push stacked branches, open PRs, and link the stack with `gh stack`

## What Changed

- `2026-11-16T16:44-0800 skills/triage-coordination/SKILL.md`: Refactored around the swarm-style coordinator workflow (delegate rather than doing worker edits inline, disjoint worktree ownership, lean author + independent verifier sizing, self-contained cold-start briefs, role templates via `list_templates`/`start_session`, remote `host` delegation via `list_hosts`, parent cascade lifecycle via `parent_session_id`/`outlive_parent`, multi-worker blocking via `wait_for_sessions`, stall/loop recovery, and integrate-before-shutdown cleanup).

## Decisions

- `2026-11-16T16:44-0800 Decision`: Place the skill update on a new top branch `feat/swarm-coordination-skill` stacked on `fix/smooth-resize-and-redraw` rather than rewriting earlier MCP branches whose artifacts and commit hashes are already packaged.

## Commits

- `HEAD`: `feat(skills): adopt swarm-style coordinator workflow in triage-coordination`
