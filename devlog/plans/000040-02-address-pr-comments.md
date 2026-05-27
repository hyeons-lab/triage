# Plan: Address PR Comments on Client FlatBuffers

This plan covers addressing the Copilot review comments regarding channel safety, allocation minimization, and adding FlatBuffers sending unit tests.

## Thinking

1.  **Safety check in `writeInput`**:
    *   Comment: `writeInput()` captures `final channel = _channel` for safety, but checks `isFlatBuffersNegotiated` which reads `_channel?.protocol`.
    *   Fix: Reference the captured `channel.protocol == 'triage-flatbuffers'` instead to prevent potential race conditions.
2.  **Minimizing allocations in `_send`**:
    *   Comment: The `payload` map is built unconditionally but only used in the JSON branch.
    *   Fix: Move map allocation inside the `else` JSON branch.
3.  **FlatBuffers Sending Unit Tests**:
    *   Comment: Lack of unit tests verifying the FlatBuffers serialization branch.
    *   Fix: Update `FakeWebSocketChannel` to support passing a custom `protocol` string and add test cases asserting client request message structures (ID, type, nested PTY resize structures) serialize correctly to FlatBuffers.

## Plan

1.  Modify `triage_websocket_client.dart` to implement safely captured channel protocol check and lazy payload map allocation.
2.  Add a test suite for FlatBuffers sending in `triage_websocket_client_test.dart`.
3.  Verify all tests pass (`flutter test`).

## Round 2 Thinking (PR Comments Round 4)

1.  **Nested request mapping extraction bugs**:
    *   Comment: FlatBuffers serialization for `styled_rows` was looking directly at the root of `extra` (e.g. `extra['session_id']`), but `styledRows()` nests parameters under a `request` map.
    *   Fix: Correctly extract fields (`session_id`, `start`, `end`) from the nested `request` map in `styled_rows`. Also audited other serialization cases and resolved identical nested extraction bugs in `attach_session` and `subscribe_session_events`.
2.  **Unawaited Futures / Timer Leaks in tests**:
    *   Comment: Outgoing requests return Futures that initiate a 10s timer. Leaving them unawaited and without a server reply can lead to flaky test runs via late async errors.
    *   Fix: Implement a `tearDown` block that calls `await client.disconnect()`, and safely catch errors on all pending request Futures inside test cases using `.catchError((_) => ...)`.
3.  **New Unit Test Coverage**:
    *   Add E2E FlatBuffers sending unit tests verifying the payload structures of `attachSession`, `subscribeSessionEvents`, and `styledRows`.

## Round 2 Plan

1.  Fix the FlatBuffers serialization mapping for `attach_session`, `subscribe_session_events`, and `styled_rows` inside `triage_websocket_client.dart`.
2.  Implement robust `tearDown` cleanup and error catching on outstanding Futures in `triage_websocket_client_test.dart`.
3.  Add dedicated unit tests for the three newly corrected request types.
4.  Verify all 46 client tests pass cleanly via `flutter test`.
