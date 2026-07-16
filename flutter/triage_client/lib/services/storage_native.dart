import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Native (macOS/iOS/desktop/Android) credential persistence.
//
// Tokens are bearer credentials, so they live in the platform Keychain /
// Keystore via flutter_secure_storage rather than a plaintext file. The shared
// storage API is synchronous (it is read from `initState` and from the periodic
// credential watcher, neither of which can await), while the Keychain API is
// async. We bridge that by hydrating an in-memory cache once at startup
// (`loadCredentials`) and serving reads from it; writes update the cache
// synchronously and write through to the Keychain in the background.
//
// A token is issued *per daemon* (each daemon pairs this device separately), so
// tokens are keyed by server id. The client id identifies this *device* and is
// shared across servers.

// Per-server token: `triage_bearer_token_<serverId>`.
const _tokenKeyPrefix = 'triage_bearer_token_';
// The single unkeyed token written before multi-server support. Read once so it
// can be migrated onto the server it belonged to, then deleted.
const _legacyTokenStorageKey = 'triage_bearer_token';
const _clientIdStorageKey = 'triage_client_id';

const _secureStorage = FlutterSecureStorage(
  // The app is sandboxed and ad-hoc signed (no development team), so it cannot
  // use the data-protection keychain (that needs a team-prefixed
  // keychain-access-group entitlement and would fail with errSecMissingEntitlement
  // / -34018). The legacy file-based keychain lets a sandboxed app read and write
  // its own items without that entitlement.
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);

String? _cachedClientId;
String? _cachedLegacyToken;
final Map<String, String> _cachedTokens = {};
bool _loaded = false;

/// Hydrate the in-memory cache from the Keychain. Call once before `runApp`.
/// Reads everything in one pass (`readAll`) so per-server tokens can be cached
/// without first knowing the server list. Safe when the platform Keychain is
/// unavailable (e.g. the unit-test VM has no plugin): it falls back to the
/// in-memory cache and never throws.
Future<void> loadCredentials() async {
  if (_loaded) return;
  try {
    final all = await _secureStorage.readAll();
    _cachedClientId = all[_clientIdStorageKey];
    _cachedLegacyToken = all[_legacyTokenStorageKey];
    _cachedTokens
      ..clear()
      ..addEntries(
        all.entries
            .where((e) => e.key.startsWith(_tokenKeyPrefix))
            .map(
              (e) => MapEntry(e.key.substring(_tokenKeyPrefix.length), e.value),
            ),
      );
  } catch (_) {
    // Keychain unavailable; keep whatever is already in the cache.
  }
  _loaded = true;
}

/// Drops the in-memory cache so the next [loadCredentials] re-reads the
/// Keychain. Exists for tests, which hydrate from a mocked Keychain repeatedly
/// within one isolate — production loads once, before `runApp`.
void resetCredentialCacheForTesting() {
  _cachedClientId = null;
  _cachedLegacyToken = null;
  _cachedTokens.clear();
  _loaded = false;
}

void persistTokenFor(String serverId, String token) {
  _cachedTokens[serverId] = token;
  _writeThrough('$_tokenKeyPrefix$serverId', token);
}

String? retrieveTokenFor(String serverId) => _cachedTokens[serverId];

void clearTokenFor(String serverId) {
  _cachedTokens.remove(serverId);
  _deleteThrough('$_tokenKeyPrefix$serverId');
}

/// The pre-multi-server token, if one was ever written. Used once at startup to
/// migrate it onto the server created from the legacy single daemon address.
String? retrieveLegacyToken() => _cachedLegacyToken;

void clearLegacyToken() {
  _cachedLegacyToken = null;
  _deleteThrough(_legacyTokenStorageKey);
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
