import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri);

class TriageWebSocketClient {
  TriageWebSocketClient(this.uri, {WebSocketChannelFactory? channelFactory})
    : _channelFactory =
          channelFactory ?? ((uri) => WebSocketChannel.connect(uri));

  final Uri uri;
  final WebSocketChannelFactory _channelFactory;
  WebSocketChannel? _channel;

  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final Map<String, Timer> _requestTimers = {};
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _eventController.stream;

  int _requestIdCounter = 0;

  bool get isConnected => _channel != null;

  Future<void> connect() async {
    if (_channel != null) return;

    try {
      _channel = _channelFactory(uri);
      _channel!.stream.listen(
        (message) {
          _handleIncomingMessage(message.toString());
        },
        onError: (error) {
          _cleanupPendingRequests();
          _channel = null;
          _eventController.add({
            'type': 'connection_closed',
            'error': error.toString(),
          });
        },
        onDone: () {
          _cleanupPendingRequests();
          _channel = null;
          _eventController.add({'type': 'connection_closed'});
        },
      );
    } catch (error) {
      _cleanupPendingRequests();
      _channel = null;
      rethrow;
    }
  }

  void _handleIncomingMessage(String messageText) {
    try {
      final message = jsonDecode(messageText) as Map<String, dynamic>;
      final type = message['type'] as String?;

      if (type == 'response') {
        final id = message['id']?.toString();
        final result = message['result'] as Map<String, dynamic>?;
        if (id != null && _pendingRequests.containsKey(id)) {
          _requestTimers.remove(id)?.cancel();
          _pendingRequests.remove(id)!.complete(result ?? {});
        }
      } else if (type == 'error') {
        final id = message['id']?.toString();
        final error = message['error'] as Map<String, dynamic>?;
        if (id != null && _pendingRequests.containsKey(id)) {
          _requestTimers.remove(id)?.cancel();
          final errorMessage = error != null
              ? (error['message'] ?? error['code'] ?? 'Unknown error')
              : 'Unknown error';
          _pendingRequests.remove(id)!.completeError(Exception(errorMessage));
        }
      } else if (type == 'event') {
        _eventController.add(message);
      } else if (type == 'subscription_closed') {
        _eventController.add(message);
      }
    } catch (_) {
      // Ignore or log malformed JSON
    }
  }

  Future<Map<String, dynamic>> _send(
    String type, [
    Map<String, dynamic>? extra,
  ]) async {
    if (_channel == null) {
      throw Exception('WebSocket is not connected');
    }

    final id = 'req-${_requestIdCounter++}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;
    _requestTimers[id] = Timer(const Duration(seconds: 10), () {
      if (_pendingRequests.remove(id) == completer && !completer.isCompleted) {
        completer.completeError(Exception('WebSocket request timed out'));
      }
      _requestTimers.remove(id);
    });

    final payload = <String, dynamic>{'id': id, 'type': type};
    if (extra != null) {
      payload.addAll(extra);
    }

    try {
      _channel!.sink.add(jsonEncode(payload));
    } catch (e) {
      _pendingRequests.remove(id);
      _requestTimers.remove(id)?.cancel();
      completer.completeError(e);
      rethrow;
    }

    return completer.future;
  }

  Future<Map<String, dynamic>> hello({String? clientId, String? token}) async {
    return _send('hello', {
      if (clientId != null) 'client_id': clientId,
      if (token != null) 'token': token,
    });
  }

  Future<String> pair({required String code, required String clientId}) async {
    final response = await _send('pair', {'code': code, 'client_id': clientId});
    return response['token']?.toString() ?? '';
  }

  Future<String> startSession({
    required String command,
    List<String> args = const [],
    String? cwd,
    int rows = 24,
    int cols = 80,
  }) async {
    final response = await _send('start_session', {
      'request': {
        'command': command,
        'args': args,
        // ignore: use_null_aware_elements
        if (cwd != null) 'cwd': cwd,
        'size': {
          'rows': rows,
          'cols': cols,
          'pixel_width': cols * 10,
          'pixel_height': rows * 20,
          'dpi': 96,
        },
      },
    });
    return response['session_id']?.toString() ?? '';
  }

  Future<List<String>> listSessions() async {
    final response = await _send('list_sessions');
    final sessionIds = response['session_ids'] as List<dynamic>?;
    return sessionIds?.map((e) => e.toString()).toList() ?? [];
  }

  Future<Map<String, dynamic>> attachSession({
    required String sessionId,
    required String clientId,
    String mode = 'InteractiveController',
  }) async {
    return _send('attach_session', {
      'request': {'session_id': sessionId, 'client_id': clientId, 'mode': mode},
    });
  }

  Future<String> subscribeSessionEvents({
    required String sessionId,
    int? afterEventSeq,
  }) async {
    final response = await _send('subscribe_session_events', {
      'request': {
        'session_id': sessionId,
        // ignore: use_null_aware_elements
        if (afterEventSeq != null) 'after_event_seq': afterEventSeq,
      },
    });
    return response['subscription_id']?.toString() ?? '';
  }

  Future<void> writeInput({
    required String sessionId,
    required String clientId,
    required List<int> bytes,
  }) async {
    await _send('write_input', {
      'request': {
        'session_id': sessionId,
        'client_id': clientId,
        'bytes': bytes,
      },
    });
  }

  Future<Map<String, dynamic>> resizeSession({
    required String sessionId,
    required int cols,
    required int rows,
  }) async {
    return _send('resize_session', {
      'request': {
        'session_id': sessionId,
        'size': {
          'rows': rows,
          'cols': cols,
          'pixel_width': cols * 10,
          'pixel_height': rows * 20,
          'dpi': 96,
        },
      },
    });
  }

  Future<void> shutdownSession({required String sessionId}) async {
    await _send('shutdown_session', {'session_id': sessionId});
  }

  Future<Map<String, dynamic>> styledRows({
    required String sessionId,
    required int start,
    required int end,
  }) async {
    return _send('styled_rows', {
      'request': {'session_id': sessionId, 'start': start, 'end': end},
    });
  }

  void _cleanupPendingRequests() {
    for (final timer in _requestTimers.values) {
      timer.cancel();
    }
    _requestTimers.clear();
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('WebSocket connection closed'));
      }
    }
    _pendingRequests.clear();
  }

  Future<void> disconnect() async {
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      await channel.sink.close();
    }
    _cleanupPendingRequests();
  }
}
