# 000028-02-address-pr-comments

## Thinking
We need to address all PR #34 comments systematically:
1. Web client platform portability (avoid compiling errors on native platforms via conditional imports).
2. Cancel flow should disconnect WebSocket cleanly.
3. Align widget test FakeTriageWebSocketClient hello signature.
4. Hello handshake should return authenticated: false instead of a hard socket bail for invalid tokens.
5. Introduce a custom typed TransportError to avoid brittle string-matching of error codes.
6. Remove plaintext secrets from daemon trace logs.
7. Implement safe Mutex lock helpers to avoid daemon panics on poisoned locks.
8. Delete pairing_code.json immediately when pairing PIN is successfully consumed.
9. Cache require_pairing setting at daemon startup to avoid costly file I/O operations.
10. Align XDG_STATE_HOME directory resolution on the CLI side.
11. Clean up user-facing CLI error messages to reference config settings.

## Plan
1. Create storage.dart, storage_stub.dart, and storage_web.dart under flutter/triage_client/lib/services/ to implement compile-safe conditional token storage.
2. Update main.dart to use these token persistence functions and call _client.disconnect() on cancel.
3. Update widget_test.dart hello override to support new named parameters and return authenticated: true.
4. Define TransportError enum in triage-transport-ws and refactor handle_message to downcast to it.
5. Modify handle_request in triage-transport-ws to return ServerResult::Hello { authenticated: false } on invalid tokens and use TransportError::Unauthorized in default request gate.
6. Define safe lock helpers pairing_codes() and paired_devices() in SessionManager, refactoring all lock unwrap points.
7. Mask pairing PIN logs in SessionManager.
8. Add require_pairing caching to SessionManager.
9. Delete pairing_code.json on successful consumption in SessionManager::pair.
10. Update crates/triage/src/main.rs run_pairing_display to honor XDG_STATE_HOME and update config error help message.
11. Hardened Hello request unauthenticated state logic to explicitly reset authentication status if client parameters are missing.

