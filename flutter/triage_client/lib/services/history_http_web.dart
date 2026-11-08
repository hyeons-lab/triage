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
  final abortController = js.globalContext
      .getProperty<js.JSFunction?>('AbortController'.toJS)
      ?.callAsConstructor<js.JSObject>();
  final init = js.JSObject()
    ..setProperty('method'.toJS, 'GET'.toJS)
    ..setProperty('headers'.toJS, jsHeaders)
    ..setProperty('cache'.toJS, 'no-store'.toJS);
  final signal = abortController?.getProperty<js.JSObject?>('signal'.toJS);
  if (signal != null) {
    init.setProperty('signal'.toJS, signal);
  }

  void abortFetch() {
    abortController?.callMethod('abort'.toJS);
  }

  final js.JSObject response;
  try {
    response = await js.globalContext
        .callMethod<js.JSPromise<js.JSObject>>(
          'fetch'.toJS,
          uri.toString().toJS,
          init,
        )
        .toDart
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            abortFetch();
            throw TimeoutException('HTTP history fetch timed out');
          },
        );
  } catch (_) {
    abortFetch();
    rethrow;
  }

  final statusCode = response.getProperty<js.JSNumber>('status'.toJS).toDartInt;
  final responseHeaders = response.getProperty<js.JSObject?>('headers'.toJS);
  final contentType =
      responseHeaders
          ?.callMethod<js.JSString?>('get'.toJS, 'content-type'.toJS)
          ?.toDart ??
      '';
  final contentLengthRaw = responseHeaders
      ?.callMethod<js.JSString?>('get'.toJS, 'content-length'.toJS)
      ?.toDart;
  final declaredLength = contentLengthRaw != null
      ? int.tryParse(contentLengthRaw)
      : null;
  if (declaredLength != null && declaredLength > maxHistoryResponseBytes) {
    abortFetch();
    throw StateError(
      'HTTP history response too large ($declaredLength bytes > $maxHistoryResponseBytes)',
    );
  }

  final js.JSArrayBuffer arrayBuffer;
  try {
    arrayBuffer = await response
        .callMethod<js.JSPromise<js.JSArrayBuffer>>('arrayBuffer'.toJS)
        .toDart
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            abortFetch();
            throw TimeoutException('HTTP history body read timed out');
          },
        );
  } catch (_) {
    abortFetch();
    rethrow;
  }
  final body = arrayBuffer.toDart.asUint8List();
  if (body.length > maxHistoryResponseBytes) {
    throw StateError(
      'HTTP history response too large (${body.length} bytes > $maxHistoryResponseBytes)',
    );
  }

  return (statusCode: statusCode, contentType: contentType, body: body);
}
