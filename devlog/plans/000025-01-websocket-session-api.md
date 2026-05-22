## Thinking

Phase 6 needs a remote-client transport before the Flutter web terminal spike can attach to daemon state. The current WebSocket crate is empty, while the existing core `SessionApi` and daemon Unix socket adapter already define the behavior to expose. The smallest useful slice is a JSON-over-WebSocket adapter that can be tested with an in-memory fake API and later hosted by the daemon.

Authentication, TLS, QR pairing, and the Flutter terminal pane should stay out of this branch. Those are important, but adding them now would blur whether the transport contract works.

The transport crate should not be named as a browser-only surface. Rename `argus-web` to `argus-transport-ws` before adding implementation so the same protocol can serve browser, mobile, and optional desktop clients.

## Plan

- Add `argus-transport-ws` dependencies for WebSocket protocol handling, JSON serialization, and error plumbing.
- Define versioned client request, server response, and server event envelopes.
- Implement a connection handler that accepts text JSON messages, calls a supplied `SessionApi`, and serializes success or error responses.
- Support session event streaming through explicit subscribe requests.
- Cover the protocol with focused tests using fake `SessionApi` implementations.
- Run formatting and targeted validation for the touched crate, then broader workspace checks if the crate-level tests pass.
