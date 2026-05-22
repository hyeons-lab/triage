import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

class ArgusWsClient {
  ArgusWsClient(this.uri);

  final Uri uri;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  Future<void> connect({
    required void Function(String message) onMessage,
    required void Function(Object error) onError,
    required void Function() onDone,
  }) async {
    final WebSocketChannel channel = WebSocketChannel.connect(uri);
    _channel = channel;
    _subscription = channel.stream.listen(
      (dynamic message) => onMessage(message.toString()),
      onError: onError,
      onDone: onDone,
    );
    channel.sink.add(helloMessage());
  }

  void startDemoSession() {
    _send(<String, Object?>{
      'id': nextRequestId('start'),
      'type': 'start_session',
      'request': <String, Object?>{
        'command': '/bin/sh',
        'args': <String>['-lc', 'cat'],
        'cwd': null,
        'size': sessionSize(),
      },
    });
  }

  void attachInteractive(String sessionId, String clientId) {
    _send(<String, Object?>{
      'id': nextRequestId('attach'),
      'type': 'attach_session',
      'request': <String, Object?>{
        'session_id': sessionId,
        'client_id': clientId,
        'mode': 'InteractiveController',
      },
    });
  }

  void subscribeSessionEvents(String sessionId) {
    _send(<String, Object?>{
      'id': nextRequestId('subscribe'),
      'type': 'subscribe_session_events',
      'request': <String, Object?>{
        'session_id': sessionId,
        'after_event_seq': null,
      },
    });
  }

  void writeInput(String sessionId, String clientId, String data) {
    _send(<String, Object?>{
      'id': nextRequestId('input'),
      'type': 'write_input',
      'request': <String, Object?>{
        'session_id': sessionId,
        'client_id': clientId,
        'bytes': data.codeUnits,
      },
    });
  }

  void _send(Map<String, Object?> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _channel?.sink.close();
    _subscription = null;
    _channel = null;
  }
}

String helloMessage() {
  return jsonEncode(<String, Object?>{
    'id': nextRequestId('hello'),
    'type': 'hello',
  });
}

Map<String, Object?> sessionSize() {
  return <String, Object?>{
    'rows': 24,
    'cols': 80,
    'pixel_width': 800,
    'pixel_height': 480,
    'dpi': 96,
  };
}

String nextRequestId([String prefix = 'request']) {
  return 'flutter-$prefix-${DateTime.now().microsecondsSinceEpoch}';
}
