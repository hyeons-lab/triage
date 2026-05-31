# Device-Specific Pairing Pins

## Thinking

The current issue is behavioral rather than only storage-related: a pin can be stored and reused after expiry, and the pairing model should distinguish browser-local identity from TUI-local identity. The implementation should preserve existing transport contracts where possible, but the client/device identity needs to be stable per device and the daemon must be able to reject or replace expired credentials predictably.

For web, browser-local storage is the right boundary: every tab in the same browser profile can reuse the same local device identity and pin, while another browser profile has to pair separately. The TUI should use its own local client/device identity and credential store rather than sharing browser state.

## Plan

1. Trace the current pairing request, pin issuance, pin storage, and auth validation paths across `triaged`, `triage`, and the Flutter client.
2. Identify the protocol changes needed to model device identity and expired-pin refresh without adding unrelated authentication features.
3. Implement daemon-side device-specific pairing state and expiry handling.
4. Implement web local-storage persistence for browser device identity and pin, and ensure TUI persistence remains device-specific.
5. Add focused tests for expired stored pins, per-device pins, and client storage behavior where the repo already has test seams.
6. Run targeted validation, update this devlog, and summarize remaining risks.

