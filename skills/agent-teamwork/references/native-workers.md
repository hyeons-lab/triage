# Native workers

Use only tools exposed in the current session and read their live descriptions.
Names below are discovery hints, not permission to invent unavailable calls.
All four coordinator runtimes can instead use the same Triage MCP workflow.

| Coordinator | Native discovery hints | Collection and ownership |
| --- | --- | --- |
| Muse | `subagent_spawn`, `subagent_wait` | Save returned child handles; collect every assigned result. |
| Claude Code | `Agent` or `Task`, according to available tools | Preserve returned task/session handles and supported model choices. |
| Codex | `spawn_agent`, messaging, agent status/wait tools | Check capacity and existing agents; address only children owned by this run. |
| AGY/Gemini | `swarm`, or `invoke_subagent` in versions exposing that interface | Follow the available teamwork skill/tool contract for board, waits, models and lifecycle. |

A different provider's model in a native catalog does not satisfy a request for
that provider's CLI environment. For example, an AGY-hosted coding model is not
Codex CLI. Use a Triage profile when the requested runtime or isolation is not
available natively. Keep the current coordinator unless the user requested a
handoff; another agent can be a planning worker without replacing the coordinator.

Do not copy tool signatures from another runtime. If the host caps concurrent
children, schedule waves or use authorized matching Triage profiles when their
capacity is independent. Do not use another runtime to evade a shared quota or
permission restriction. Record native and external handles separately.

## AGY teamwork and external workers

AGY's native teamwork/swarm board owns native conversations, messages and waits.
Triage owns external CLI sessions and durable group/task records. External
workers do not become swarm members and do not appear on its board automatically.

When using AGY's built-in teamwork workflow as the coordinator UI:

1. Follow its current rules for models, authors, workspaces, monitors and board
   messages. Read the actual native skill if available; do not assume a name or
   interface from another installation.
2. If that workflow requires all technical work/results on its board, give one
   native **relay worker** the external delegation assignment. The relay uses
   the Triage reference to launch the requested CLI workers, supervises them,
   and posts its own attributed status/result with group/task IDs and artifact
   links to the native board. Other native workers can refer to that post using
   the board's sequence IDs. The relay is orchestration, not a substitute for
   the requested external runtime.
3. Record that relay's native handle and the Triage group in the run record.
   Native helpers use the actual host `TRIAGE_SESSION_ID` or the explicitly
   supplied owned parent/group context;
   their native handles are not session IDs. Managed helpers must keep their
   existing group. Give the relay a bounded supervision assignment, explicit cleanup scope,
   and establish
   who owns the host inbox; leave unrelated mail unacknowledged.
4. Keep an owner actively observing pending external work. The relay must use
   bounded Triage waits/status reads and post meaningful changes to the board;
   it must not park on `swarm_wait` while only external work can progress. If
   no relay is available, the coordinator must check both backends using tools
   with bounded waits instead of sleeping indefinitely on the native board.
5. Native stop/kill does not clean up Triage sessions. Collect/integrate results,
   perform Triage cleanup at the assigned scope, then release native relays and
   workspaces under the host's rules. A partial relay or nested helper cleans
   only its owned child subtrees; whole-group cleanup requires explicit root-owner
   authority. After restart, recover the group and resume relay supervision
   rather than spawning duplicate external workers.

Other native hosts with their own channels can use the same relay pattern when
needed. A relay is optional when the coordinator can directly supervise both
backends. Never claim a shared inbox, board, workspace or cleanup API exists.
