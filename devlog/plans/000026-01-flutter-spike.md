## Thinking

Argus already has the local daemon, TUI, MCP, and WebSocket transport foundations. The Flutter client spike should validate the client-side shape without expanding daemon semantics or committing to platform-specific polish too early.

The useful first slice is to inspect the existing Flutter scaffold, identify the transport contract it should consume, and build only enough UI or client plumbing to prove the remote-client path.

## Plan

- Inspect the existing Flutter client scaffold and current WebSocket transport API.
- Define the smallest spike objective that exercises the shared session API from Flutter.
- Implement only the client structure needed for that objective.
- Run focused Flutter and workspace validation appropriate to the files changed.
- Update the branch devlog with decisions, validation, and any follow-up work.
