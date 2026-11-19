# Managed worker groups

## Thinking

Basic MCP session control does not provide ownership, retry protection, or durable task results. A managed group needs a stable root session identity, topic, and workers with immediate parents. Nested helpers inherit the group. The daemon must serialize worker creation and cleanup, persist launch intentions before spawning, and recover ambiguous launches without duplicates. Runtime profiles supply literal command/arguments and a bootstrap prompt; model flags are configured rather than guessed. An agent chooses native helpers when its runtime can run the requested provider/model and otherwise uses managed sessions.

Cleanup terminates only sessions that match the recorded stable identity. It excludes the root, retains task results and working directories, and reports incomplete shutdowns for retry. Cold restart and handover must retain ownership. Status must distinguish launch, ready, running, completed, failed, and cancellation; a successful process launch is not proof the helper accepted a task.

## Plan

1. Add shared strict group/profile/task types and SessionApi methods, including Arc forwarding and local IPC.
2. Add stable session incarnation identities across persistence, restore, and handover.
3. Implement an atomic daemon registry for groups, idempotent worker launches, explicit worker updates/results, status/list, and group/subtree cleanup.
4. Expose strict MCP tools and reusable CLI profiles with literal argv bootstrap substitution. Update coordination guidance for native-first routing and managed fallback.
5. Validate real isolated worker launch, parent inheritance, results, retry, cleanup, restart, and malformed requests. Run CI gates and local max review/fix loop until clean.
6. Update the devlog, commit the logical unit, push once, and open a PR stacked on the current open parent branch.
