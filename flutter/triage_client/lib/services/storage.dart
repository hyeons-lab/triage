import 'storage_native.dart'
    if (dart.library.js_interop) 'storage_web.dart'
    as impl;

/// Hydrate any cached credentials from persistent storage. Must be awaited
/// before `runApp` so the synchronous accessors below return persisted values.
Future<void> loadCredentials() => impl.loadCredentials();

void persistToken(String token) => impl.persistToken(token);
String? retrieveToken() => impl.retrieveToken();
void clearToken() => impl.clearToken();

void persistClientId(String clientId) => impl.persistClientId(clientId);
String? retrieveClientId() => impl.retrieveClientId();
void clearClientId() => impl.clearClientId();
