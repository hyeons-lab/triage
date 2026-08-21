# triage-core

Shared session traits, protocol definitions, configuration parser, and rule evaluation engine for **Triage**, the attention-routing terminal supervisor.

This library is a core dependency of all other Triage components (`triaged` daemon, `triage` local client, `triage-hook` agent shim, `triage-mcp` server, and remote endpoints).

## Features

*   **Session Protocol**: FlatBuffers binary protocol schema and serialization definitions for session snapshots, input streaming, and lifecycle events.
*   **Approval Judge Rules**: Deterministic security rule evaluation tables (`judge_rules.rs`) for tool-call judging (Layer 1 deny rules and Layer 2 allow rules).
*   **Typed Configuration**: TOML configuration parsing and strict validation (`config.rs`).
*   **State Sharing**: Shared session state, layout management, and PTY manager abstractions.
*   **IPC Definitions**: Shared wire structures for local domain socket and named pipe communication.
