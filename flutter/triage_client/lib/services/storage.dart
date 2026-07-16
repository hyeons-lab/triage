import 'package:flutter/foundation.dart' show visibleForTesting;

import 'storage_native.dart'
    if (dart.library.js_interop) 'storage_web.dart'
    as impl;

/// Hydrate any cached credentials from persistent storage. Must be awaited
/// before `runApp` so the synchronous accessors below return persisted values.
Future<void> loadCredentials() => impl.loadCredentials();

/// Drops any cached credentials so the next [loadCredentials] re-reads them.
/// Production loads once, before `runApp`; tests hydrate repeatedly from a
/// mocked store within a single isolate.
@visibleForTesting
void resetCredentialCacheForTesting() => impl.resetCredentialCacheForTesting();

// Tokens are issued per daemon (each one pairs this device separately), so they
// are keyed by server id. The client id identifies this *device* and is shared
// across every server.

void persistTokenFor(String serverId, String token) =>
    impl.persistTokenFor(serverId, token);
String? retrieveTokenFor(String serverId) => impl.retrieveTokenFor(serverId);
void clearTokenFor(String serverId) => impl.clearTokenFor(serverId);

/// The single unkeyed token written before multi-server support, read once so it
/// can be migrated onto the server created from the legacy daemon address.
String? retrieveLegacyToken() => impl.retrieveLegacyToken();
void clearLegacyToken() => impl.clearLegacyToken();

void persistClientId(String clientId) => impl.persistClientId(clientId);
String? retrieveClientId() => impl.retrieveClientId();
void clearClientId() => impl.clearClientId();
