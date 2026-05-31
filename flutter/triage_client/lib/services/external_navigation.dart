import 'external_navigation_stub.dart'
    if (dart.library.js_interop) 'external_navigation_web.dart'
    as impl;

bool openExternalUri(Uri uri) => impl.openExternalUri(uri);
