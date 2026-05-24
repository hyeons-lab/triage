import 'dart:js_interop' as js;
import 'dart:js_interop_unsafe';

void persistToken(String token) {
  try {
    final localStorage = js.globalContext.getProperty<js.JSObject>('localStorage'.toJS);
    localStorage.callMethod('setItem'.toJS, 'triage_bearer_token'.toJS, token.toJS);
  } catch (_) {}
}

String? retrieveToken() {
  try {
    final localStorage = js.globalContext.getProperty<js.JSObject>('localStorage'.toJS);
    final val = localStorage.callMethod<js.JSString?>('getItem'.toJS, 'triage_bearer_token'.toJS);
    return val?.toDart;
  } catch (_) {
    return null;
  }
}
