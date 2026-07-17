import 'dart:js_interop' as js;
import 'dart:js_interop_unsafe';

// Web credential persistence. localStorage is already synchronous and
// persistent, so unlike the native implementation there is nothing to pre-load.
//
// A token is issued *per daemon* (each daemon pairs this device separately), so
// tokens are keyed by server id. The client id identifies this *device* and is
// shared across servers.

// Per-server token: `triage_bearer_token_<serverId>`.
const _tokenKeyPrefix = 'triage_bearer_token_';
// The single unkeyed token written before multi-server support, kept readable so
// it can be migrated onto the server it belonged to, then deleted.
const _legacyTokenStorageKey = 'triage_bearer_token';
const _clientIdStorageKey = 'triage_client_id';

/// Present for parity with the native implementation; localStorage needs no
/// hydration.
Future<void> loadCredentials() async {}

/// Present for parity with the native implementation, which caches in memory.
/// localStorage is read through on every access, so there is nothing to drop.
void resetCredentialCacheForTesting() {}

void persistTokenFor(String serverId, String token) =>
    _setItem('$_tokenKeyPrefix$serverId', token);

String? retrieveTokenFor(String serverId) =>
    _getItem('$_tokenKeyPrefix$serverId');

void clearTokenFor(String serverId) => _removeItem('$_tokenKeyPrefix$serverId');

/// The pre-multi-server token, if one was ever written. Used once at startup to
/// migrate it onto the server created from the legacy single daemon address.
String? retrieveLegacyToken() => _getItem(_legacyTokenStorageKey);

void clearLegacyToken() => _removeItem(_legacyTokenStorageKey);

void persistClientId(String clientId) =>
    _setItem(_clientIdStorageKey, clientId);

String? retrieveClientId() => _getItem(_clientIdStorageKey);

void clearClientId() => _removeItem(_clientIdStorageKey);

js.JSObject? _localStorage() {
  try {
    return js.globalContext.getProperty<js.JSObject>('localStorage'.toJS);
  } catch (_) {
    return null;
  }
}

void _setItem(String key, String value) {
  try {
    _localStorage()?.callMethod('setItem'.toJS, key.toJS, value.toJS);
  } catch (_) {}
}

String? _getItem(String key) {
  try {
    return _localStorage()
        ?.callMethod<js.JSString?>('getItem'.toJS, key.toJS)
        ?.toDart;
  } catch (_) {
    return null;
  }
}

void _removeItem(String key) {
  try {
    _localStorage()?.callMethod('removeItem'.toJS, key.toJS);
  } catch (_) {}
}
