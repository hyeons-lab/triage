import 'dart:typed_data';

import 'history_http_io.dart'
    if (dart.library.js_interop) 'history_http_web.dart';

const int maxHistoryResponseBytes = 16 * 1024 * 1024;

typedef HistoryHttpResponse = ({
  int statusCode,
  String contentType,
  Uint8List body,
});

typedef HistoryHttpFetcher =
    Future<HistoryHttpResponse> Function(
      Uri uri, {
      required Map<String, String> headers,
    });

Future<HistoryHttpResponse> getHistoryHttp(
  Uri uri, {
  required Map<String, String> headers,
}) => performHistoryHttpGet(uri, headers: headers);
