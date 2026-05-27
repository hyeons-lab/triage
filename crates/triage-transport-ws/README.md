# triage-transport-ws

WebSocket transport adapter, server-side protocol implementation, and stress benchmarking suite for **Triage** remote clients.

This crate manages serializing and parsing Flatbuffers-over-WebSocket session API frames between the `triaged` daemon and remote web/mobile clients.

## Features

*   **WebSocket Engine**: High-performance asynchronous WebSocket protocol layer.
*   **Flatbuffers Framing**: High-efficiency framing of state snapshots and user input.
*   **Benchmarking Tools**: Integrated stress testing tools and performance benchmarks.
