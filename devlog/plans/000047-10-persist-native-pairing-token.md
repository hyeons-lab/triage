## Thinking

Reported symptom: the macOS client asks to pair again on every launch — the pairing
token (and client id) are not persisted across app restarts.

Root cause: native platforms use `lib/services/storage_stub.dart`, which is a pure
in-memory stub (`_stubToken` / `_stubClientId` static fields). Only the web build
(`storage_web.dart`) persists, via `window.localStorage`. So on macOS nothing is written
to disk and each launch starts unauthenticated.

Chosen backend (user decision): the macOS/iOS Keychain via `flutter_secure_storage`
(Keystore-backed `EncryptedSharedPreferences` on Android). The token is a bearer
credential, so encrypted-at-rest storage is preferable to a plaintext plist.

Design: `flutter_secure_storage`'s API is async, but the existing storage API
(`String? retrieveToken()`, etc.) is synchronous and is called from `initState`
(`_loadOrCreateClientId`) and from the 2s credential watcher, neither of which can await.
Rather than making the whole chain async (which ripples through `_loadOrCreateClientId`,
`_refreshBearerTokenFromStorage`, `_checkCredentialStorageStillMatches`, and the connect
path), hydrate an in-memory cache once at startup from the Keychain and keep reads
synchronous; writes/deletes update the cache synchronously and write through to the
Keychain asynchronously (fire-and-forget with error handling). Same Keychain security,
minimal call-site churn.

Test safety: widget tests pump `TriageClientApp` directly and never call `main()`, so
`loadCredentials()` is not invoked and the Keychain channel is never required. Write-through
calls are guarded, so in the test VM (no plugin) they fail silently and the cache behaves
exactly like the old in-memory stub — the existing persisted-client-id and
cleared-site-data tests keep passing.

macOS sandbox: Keychain access from a sandboxed app needs a keychain-access-groups
entitlement; add it to both `Release.entitlements` and `DebugProfile.entitlements`.

## Plan

1. Add `flutter_secure_storage` to `pubspec.yaml`.
2. Replace `storage_stub.dart` with `storage_native.dart`: Keychain-backed, sync cache,
   async `loadCredentials()` hydrator, guarded write-through persist/clear. Update the
   conditional import in `storage.dart` and export `loadCredentials()`.
3. Add a no-op `loadCredentials()` to `storage_web.dart` (localStorage is already sync).
4. Make `main()` async — `WidgetsFlutterBinding.ensureInitialized()`, `await loadCredentials()`,
   then `runApp`.
5. Add the `keychain-access-groups` entitlement to both macOS entitlement files.
6. Run `flutter test test/cursor_position_test.dart test/widget_test.dart` and the full suite.
7. Rebuild + reinstall `/Applications/Triage.app`; verify the token survives a restart.
8. Update the branch devlog.
