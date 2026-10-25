import 'dart:async';
import 'dart:js_interop' as js;
import 'dart:js_interop_unsafe';

import 'history_http.dart';

Future<HistoryHttpResponse> performHistoryHttpGet(
  Uri uri, {
  required Map<String, String> headers,
}) async {
  final jsHeaders = js.JSObject();
  headers.forEach((key, value) {
    jsHeaders.setProperty(key.toJS, value.toJS);
  });
  final init = js.JSObject()
    ..setProperty('method'.toJS, 'GET'.toJS)
    ..setProperty('headers'.toJS, jsHeaders)
    ..setProperty('cache'.toJS, 'no-store'.toJS);

  final response = await js.globalContext
      .callMethod<js.JSPromise<js.JSObject>>(
        'fetch'.toJS,
        uri.toString().toJS,
        init,
      )
      .toDart
      .timeout(const Duration(seconds: 10));

  final statusCode = response.getProperty<js.JSNumber>('status'.toJS).toDartInt;
  final responseHeaders = response.getProperty<js.JSObject?>('headers'.toJS);
  final contentType =
      responseHeaders
          ?.callMethod<js.JSString?>('get'.toJS, 'content-type'.toJS)
          ?.toDart ??
      '';
  final arrayBuffer = await response
      .callMethod<js.JSPromise<js.JSArrayBuffer>>('arrayBuffer'.toJS)
      .toDart
      .timeout(const Duration(seconds: 10));
  final body = arrayBuffer.toDart.asUint8List();

  return (statusCode: statusCode, contentType: contentType, body: body);
}
