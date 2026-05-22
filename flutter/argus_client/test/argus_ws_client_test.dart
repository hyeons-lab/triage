import 'dart:convert';

import 'package:argus_client/src/remote/argus_ws_client.dart';
import 'package:argus_client/src/remote/default_ws_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('helloMessage encodes the transport hello request', () {
    final Map<String, dynamic> message =
        jsonDecode(helloMessage()) as Map<String, dynamic>;

    expect(message['type'], 'hello');
    expect(message['id'], isA<String>());
  });

  test('defaultWebSocketUrl points at the daemon websocket port', () {
    expect(defaultWebSocketUrl(), startsWith('ws://'));
    expect(defaultWebSocketUrl(), endsWith(':8081'));
  });

  test('sessionSize encodes the default terminal dimensions', () {
    expect(
      sessionSize(),
      <String, Object?>{
        'rows': 24,
        'cols': 80,
        'pixel_width': 800,
        'pixel_height': 480,
        'dpi': 96,
      },
    );
  });
}
