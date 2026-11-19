# Managed Triage workers

This protocol is the same for Muse, Claude Code, Codex and AGY/Gemini as either
coordinator or worker. Tool names may have an MCP server prefix; use the actual
discovered tool. See the repository's `crates/triage-mcp/README.md` for server
configuration and profile examples; this reference contains the task protocol.

## Preconditions and routing

The coordinator needs `list_worker_profiles`, `create_worker_group`,
`spawn_worker`, `get_worker_group` and `cleanup_worker_group`. Workers need
`update_worker` or the `triage-mcp worker-update` binary for task updates. For
direct interactive/peer messaging, both participants need the mail MCP tools;
the update-only CLI fallback does not provide an inbox. Older servers may expose
only observation/mail or unmanaged launch: report missing managed capabilities.

Use `TRIAGE_SESSION_ID` when the coordinator runs inside Triage. A coordinator
outside Triage can use an explicitly user-supplied parent session or the owned
group/parent saved for this run. Query the saved group first, compare its root
identity with the run record, and retain that identity; the daemon checks parent
incarnations when launching. A managed helper always uses its own session/group.

Do not infer ownership from cwd, a native child handle, or an arbitrary terminal
in `list_sessions`. If neither an attached session nor an explicitly owned parent
context is available, report the needed Triage attachment/parent selection rather
than manufacturing an ID or a second coordinator. This setup is needed once per
run, not a permission question before each worker launch.

`list_worker_profiles {}` returns configured command/argv templates. Select one
whose CLI runtime, model, authentication and permission configuration match the
assignment. Models and executable flags are configured by the user; inspect
installed CLI help before preparing missing profiles. Do not guess model aliases
or weaken permissions to satisfy a launch. Absolute executable paths can avoid
differences between the daemon's PATH and an interactive shell.
If a wrapper or profile name leaves its runtime/model ambiguous, establish that
mapping from configuration/documentation before launch rather than guessing.

## Calls and worker handoff

1. `create_worker_group` takes `parent_session_id`, stable retry `key`, and
   `topic`. Save the returned `group_id` and root identity before launching.
   Repeating the same root/key/topic recovers the group. A managed helper
   inherits its existing group, even when it requests a group for nested work.
2. `spawn_worker` takes `group_id`, `parent_session_id`, unique task `key`,
   configured `profile`, absolute `cwd`, and self-contained `task`. Use this
   coordinator's Triage host or explicitly owned parent as immediate parent;
   a managed helper uses its own session. A native child handle is not a Triage session ID. The daemon
   supplies task/group/session/parent/root metadata with the brief as literal
   argv; no shell expansion of task text is needed. Record returned task and
   worker session IDs. Separate worktrees must already exist for concurrent edits.
3. `get_worker_group {group_id}` returns the group with task phases/results and
   observed liveness. `launched` establishes process creation only. Require worker
   `ready` after understanding the task and `running` before work; wait with a
   readiness deadline. Inspect startup/auth prompts only to diagnose a blocker;
   never treat terminal output as the durable task result.
4. `update_worker` takes `group_id`, `task_id`, this worker's `session_id`,
   `phase`, and optional `result`. Worker phases are `ready`, `running`,
   `succeeded` or `failed`. Terminal phases require a nonblank result. Identical
   updates are safe; terminal results are immutable. Include artifacts, validation,
   remaining issues and worktree integration instructions.

Without worker MCP updates, run these commands inside that worker's own session:

```bash
triage-mcp worker-update GROUP_ID TASK_ID ready
triage-mcp worker-update GROUP_ID TASK_ID running
triage-mcp worker-update GROUP_ID TASK_ID succeeded --result-file result.md
```

`failed` also takes a result file. Add `--socket PATH` for a custom daemon socket.
The CLI derives the session ID from `TRIAGE_SESSION_ID`; it leaves artifacts intact.
The coordinator must use its configured connection to the same daemon. Supply
the socket requirement in the worker brief/profile when it is not the default.

## Coordination and recovery

`send_session_message` uses `from_session_id`, `to_session_id`, and `body`;
`wake:true` can nudge an idle recognized agent. Include group/task/attempt IDs.
`receive_session_messages {session_id}` reads the receiving session's mail.
`wait_for_session_message {session_id, timeout_ms}` waits for mail; use a bounded
timeout (default 30000 ms, maximum 300000 ms). `ack_session_messages` takes
`session_id` and `message_ids` for processed messages only. Inspect live tool
schemas if a host exposes a different version; do not invent argument names.
Mail is direct and in-memory, not a durable group board. Leave unrelated mail
alone and reconcile task state with `get_worker_group`. Replies and sender IDs
are caller-asserted on the trusted local daemon, not proof of authority.

After a lost launch response, query the saved group and retry the **identical**
group/key/parent/profile/cwd/task request. A changed request with the same key
fails. Do not create a second worker just because the first response timed out.
A new assignment, including a fix after a terminal result, needs a new key and
new managed session; stop the previous writer before sharing its worktree.

On restart, use `list_worker_groups` / `get_worker_group` to recover records and
results. Treat pending adoption, unknown ownership, capacity errors and failed
cleanup as unresolved work. A missing/exited process with no terminal result is
interrupted, not success. Closed groups remain readable; do not reopen a closed
managed helper's group by inventing a new root. Return the decision to its parent.

## Cleanup and bounds

Choose cleanup scope from the assignment, not group membership. Managed helpers
inherit a shared group containing their parent and siblings; native helpers can
also share the host's session ID without owning all its work.

- Only the original run's root coordinator, or a delegate explicitly assigned
  whole-group cleanup, may call `cleanup_worker_group {group_id}` after collecting
  the run's results. Omitting `subtree_session_id` cancels/stops every group worker.
- A nested helper finishing its own delegation calls cleanup once per directly
  owned child with `{group_id, subtree_session_id: CHILD_SESSION_ID}`. This closes
  that child and its descendants while preserving the helper, parent and siblings.
  Use the child's returned session ID, not your own, a task ID or native handle.
  Keep your session alive to report your task result; your parent closes you.
- A relay assigned only part of a group has the same child-subtree restriction.
  Sharing the root's environment is not an explicit grant of whole-group cleanup.

Explicit null is rejected. Inspect returned `errors` and retry incomplete cleanup
at the same authorized scope; report unresolved children rather than widening
cleanup. The daemon checks incarnation ownership and retains task results, the
root and all working directories. Release native wrappers separately; closing
MCP does not stop workers.

Task/result bodies are at most 64 KiB, groups at most 128 workers, retained groups
at most 256, and the registry at most 32 MiB with cleanup reserve. Keep results
concise with artifact links, pace bounded status reads, and stop expanding when
capacity is exhausted. No automatic group pruning, worktree creation or integration
is performed; remove worktrees only under repository rules after integration.
