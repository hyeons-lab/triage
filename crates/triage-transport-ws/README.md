# triage-transport-ws

WebSocket transport adapter, server-side protocol implementation, and benchmarking suite for **Triage** remote clients.

This crate manages serializing and parsing FlatBuffers-over-WebSocket session API frames between the `triaged` daemon and remote web, desktop, and mobile clients.

## Features

*   **WebSocket Engine**: High-performance asynchronous WebSocket protocol layer.
*   **FlatBuffers Framing**: Zero-copy framing of terminal state snapshots, delta streams, and user input.
*   **Approval Judge Push Events**: Real-time broadcast of tool-call verdicts, audit streams, and policy changes to connected remote clients.
*   **Benchmarking Tools**: Integrated stress testing tools and throughput benchmarks.
