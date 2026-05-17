# Phase 4 — Session Context

## Thinking

The daemon already owns the canonical current working directory through OSC 7 tracking, and snapshots are already the cross-transport state object. The next product slice should extend that existing path instead of making the TUI inspect local process state independently. Keeping context in the snapshot also gives later WebSocket and MCP surfaces the same source of truth.

This first slice should not classify agents, infer needs-response state, or build grouping/navigation. It should provide the metadata those features need: session cwd, git repository root, git branch, and git worktree when discoverable.

## Plan

1. Add shared session context types to `argus-core` and include optional context on `SessionSnapshot`.
2. Resolve git context in `argus-daemon` from the observed session cwd, updating snapshots when cwd changes.
3. Render concise context in the TUI sidebar while preserving the existing session status rows.
4. Add focused tests for git context discovery, snapshot propagation, and sidebar text.
5. Run formatting and targeted workspace validation before committing.
