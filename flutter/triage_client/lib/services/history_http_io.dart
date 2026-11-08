import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'history_http.dart';

final HttpClient _sharedHistoryHttpClient = HttpClient()
  ..autoUncompress = true
  ..connectionTimeout = const Duration(seconds: 10)
  ..idleTimeout = const Duration(seconds: 30);

Future<HistoryHttpResponse> performHistoryHttpGet(
  Uri uri, {
  required Map<String, String> headers,
}) async {
  final request = await _sharedHistoryHttpClient
      .getUrl(uri)
      .timeout(const Duration(seconds: 10));
  headers.forEach((key, value) {
    request.headers.set(key, value);
  });
  final response = await request.close().timeout(const Duration(seconds: 10));
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response.timeout(const Duration(seconds: 10))) {
    builder.add(chunk);
  }
  final contentType =
      response.headers.value(HttpHeaders.contentTypeHeader) ?? '';
  return (
    statusCode: response.statusCode,
    contentType: contentType,
    body: builder.takeBytes(),
  );
}
