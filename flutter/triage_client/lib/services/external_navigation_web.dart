import 'dart:js_interop' as js;
import 'dart:js_interop_unsafe';

bool openExternalUri(Uri uri) {
  try {
    final window = js.globalContext.getProperty<js.JSObject>('window'.toJS);
    window.callMethod(
      'open'.toJS,
      uri.toString().toJS,
      '_blank'.toJS,
      'noopener,noreferrer'.toJS,
    );
    return true;
  } catch (_) {
    return false;
  }
}
