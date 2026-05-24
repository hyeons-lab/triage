## Thinking
- 2026-05-24T08:33-0700 Review found that all Flutter installs used the shared `triage-flutter-client` id, while daemon token storage is keyed by `ClientId`; pairing a second device therefore replaces the first device's token hash.
- 2026-05-24T08:33-0700 The least invasive fix is to keep the daemon's one-token-per-client-id model and make the Flutter client generate and persist a unique id per browser/app install alongside the bearer token.

## Plan
- 2026-05-24T08:33-0700 Add client-id persistence to the existing Flutter storage facade and web/stub implementations.
- 2026-05-24T08:33-0700 Generate a stable `triage-flutter-client-*` id on first launch and use it for hello, pair, attach, and input calls.
- 2026-05-24T08:33-0700 Add widget coverage proving the shared fixed id is no longer used.
