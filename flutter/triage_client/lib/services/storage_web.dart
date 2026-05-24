import 'dart:js_interop' as js;
import 'dart:js_interop_unsafe';

const _tokenStorageKey = 'triage_bearer_token';
const _clientIdStorageKey = 'triage_client_id';

void persistToken(String token) {
  try {
    final localStorage = js.globalContext.getProperty<js.JSObject>(
      'localStorage'.toJS,
    );
    localStorage.callMethod('setItem'.toJS, _tokenStorageKey.toJS, token.toJS);
  } catch (_) {}
}

String? retrieveToken() {
  try {
    final localStorage = js.globalContext.getProperty<js.JSObject>(
      'localStorage'.toJS,
    );
    final val = localStorage.callMethod<js.JSString?>(
      'getItem'.toJS,
      _tokenStorageKey.toJS,
    );
    return val?.toDart;
  } catch (_) {
    return null;
  }
}

void persistClientId(String clientId) {
  try {
    final localStorage = js.globalContext.getProperty<js.JSObject>(
      'localStorage'.toJS,
    );
    localStorage.callMethod(
      'setItem'.toJS,
      _clientIdStorageKey.toJS,
      clientId.toJS,
    );
  } catch (_) {}
}

String? retrieveClientId() {
  try {
    final localStorage = js.globalContext.getProperty<js.JSObject>(
      'localStorage'.toJS,
    );
    final val = localStorage.callMethod<js.JSString?>(
      'getItem'.toJS,
      _clientIdStorageKey.toJS,
    );
    return val?.toDart;
  } catch (_) {
    return null;
  }
}
