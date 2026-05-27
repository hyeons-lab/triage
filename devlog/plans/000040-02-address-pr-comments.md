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
