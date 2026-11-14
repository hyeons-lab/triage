# Portable agent teamwork

## Thinking

The managed-worker APIs supply process/session ownership, task state, retries and cleanup. Agents also need a portable coordinator workflow that chooses an execution backend without treating an available model as the requested CLI runtime. AGY's native teamwork is one backend, with its own board and lifecycle; the shared skill must also work when Muse, Claude Code or Codex coordinates. A worker brief must be self-contained, scoped to its workspace and explicit about durable results. The current native review skills do not need modification for this feature.

## Plan

1. Add agent-teamwork with capability-based native/Triage routing, coordinator and worker roles, task dependencies, isolation, progress, verification, integration and cleanup.
2. Add focused native-backend and managed-worker references with concrete tool flow and recovery rules. Preserve nested group ownership, explicit runtime/model requests and native board boundaries.
3. Extend Triage's installer and fake-home verification for both skills and all runtime locations, including support references, linking, upgrades and missing capabilities.
4. Document invocation and prerequisites. Validate skill metadata and independently forward-test representative orchestrators and failures without touching live sessions or billing external models.
5. Run full applicable CI gates and the required local max review/fix loop. Update the devlog, commit once, push with an explicit feature refspec, and open a PR stacked on #217.
