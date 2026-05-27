# triage-core

Shared session trait, types, and protocol engine for **Triage**, the attention-routing terminal supervisor.

This library is a core dependency of all other Triage components (`triaged` daemon, `triage` local client, `triage-mcp` server, and remote endpoints).

## Features

*   **Session Protocol**: Flatbuffers binary protocol definitions and parser logic.
*   **State Sharing**: Shared session state, layout management, and PTY manager traits.
*   **Instrumentation**: Consolidated workspace logging and tracing configuration.
