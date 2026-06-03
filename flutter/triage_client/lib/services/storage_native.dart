import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Native (macOS/iOS/desktop/Android) credential persistence.
//
// The token is a bearer credential, so it is stored in the platform Keychain /
// Keystore via flutter_secure_storage rather than a plaintext file. The shared
// storage API is synchronous (it is read from `initState` and from the periodic
// credential watcher, neither of which can await), while the Keychain API is
// async. We bridge that by hydrating an in-memory cache once at startup
// (`loadCredentials`) and serving reads from it; writes update the cache
// synchronously and write through to the Keychain in the background.

const _tokenStorageKey = 'triage_bearer_token';
const _clientIdStorageKey = 'triage_client_id';

const _secureStorage = FlutterSecureStorage(
  // The app is sandboxed and ad-hoc signed (no development team), so it cannot
  // use the data-protection keychain (that needs a team-prefixed
  // keychain-access-group entitlement and would fail with errSecMissingEntitlement
  // / -34018). The legacy file-based keychain lets a sandboxed app read and write
  // its own items without that entitlement.
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);

String? _cachedToken;
String? _cachedClientId;
bool _loaded = false;

/// Hydrate the in-memory cache from the Keychain. Call once before `runApp`.
/// Safe to call when the platform Keychain is unavailable (e.g. the unit-test
/// VM has no plugin): it falls back to the in-memory cache and never throws.
Future<void> loadCredentials() async {
  if (_loaded) return;
  try {
    // Independent reads — run them concurrently so we don't serialize two
    // Keychain round trips ahead of the first frame.
    final values = await Future.wait([
      _secureStorage.read(key: _tokenStorageKey),
      _secureStorage.read(key: _clientIdStorageKey),
    ]);
    _cachedToken = values[0];
    _cachedClientId = values[1];
  } catch (_) {
    // Keychain unavailable; keep whatever is already in the cache.
  }
  _loaded = true;
}

void persistToken(String token) {
  _cachedToken = token;
  _writeThrough(_tokenStorageKey, token);
}

String? retrieveToken() => _cachedToken;

void clearToken() {
  _cachedToken = null;
  _deleteThrough(_tokenStorageKey);
}

void persistClientId(String clientId) {
  _cachedClientId = clientId;
  _writeThrough(_clientIdStorageKey, clientId);
}

String? retrieveClientId() => _cachedClientId;

void clearClientId() {
  _cachedClientId = null;
  _deleteThrough(_clientIdStorageKey);
}

void _writeThrough(String key, String value) {
  _secureStorage.write(key: key, value: value).catchError((_) {});
}

void _deleteThrough(String key) {
  _secureStorage.delete(key: key).catchError((_) {});
}
