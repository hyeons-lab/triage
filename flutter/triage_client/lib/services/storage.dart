import 'storage_stub.dart'
    if (dart.library.js_interop) 'storage_web.dart'
    as impl;

void persistToken(String token) => impl.persistToken(token);
String? retrieveToken() => impl.retrieveToken();
