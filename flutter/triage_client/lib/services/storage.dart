import 'storage_stub.dart'
    if (dart.library.js_interop) 'storage_web.dart'
    as impl;

void persistToken(String token) => impl.persistToken(token);
String? retrieveToken() => impl.retrieveToken();
void clearToken() => impl.clearToken();

void persistClientId(String clientId) => impl.persistClientId(clientId);
String? retrieveClientId() => impl.retrieveClientId();
