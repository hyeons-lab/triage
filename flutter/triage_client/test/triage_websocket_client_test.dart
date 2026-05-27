import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/generated/triage_triage.generated_generated.dart'
    as fbs;
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeWebSocketChannel implements WebSocketChannel {
  FakeWebSocketChannel({required this.sink, this.protocol});

  @override
  final WebSocketSink sink;

  final StreamController<dynamic> _streamController =
      StreamController<dynamic>();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  final String? protocol;

  @override
  Future<void> get ready => Future.value();

  @override
  Stream get stream => _streamController.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RecordingWebSocketSink implements WebSocketSink {
  final sent = <Object?>[];

  @override
  Future<void> get done => Future.value();

  @override
  void add(Object? event) {
    sent.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
}

class ThrowingWebSocketSink extends RecordingWebSocketSink {
  @override
  void add(Object? event) {
    throw StateError('sink closed');
  }
}

void main() {
  test('writeInput fails when the WebSocket is not connected', () async {
    final client = TriageWebSocketClient(Uri.parse('ws://localhost/ws'));

    await expectLater(
      client.writeInput(sessionId: 's1', clientId: 'c1', bytes: [65]),
      throwsStateError,
    );
  });

  test(
    'writeInput reports sink failures and closes the client state',
    () async {
      final sink = ThrowingWebSocketSink();
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) => FakeWebSocketChannel(sink: sink),
      );
      await client.connect();

      final eventFuture = client.events.first;

      await expectLater(
        client.writeInput(sessionId: 's1', clientId: 'c1', bytes: [65]),
        throwsStateError,
      );
      final event = await eventFuture;

      expect(client.isConnected, isFalse);
      expect(event['type'], equals('connection_closed'));
      expect(event['error'], contains('sink closed'));
    },
  );

  group('FlatBuffers Sending Path', () {
    late RecordingWebSocketSink sink;
    late TriageWebSocketClient client;

    setUp(() async {
      sink = RecordingWebSocketSink();
      client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) =>
            FakeWebSocketChannel(sink: sink, protocol: 'triage-flatbuffers'),
      );
      await client.connect();
    });

    test('hello request translates to binary FlatBuffers', () async {
      client.hello(clientId: 'client-123', token: 'token-abc');

      expect(sink.sent, hasLength(1));
      final bytes = sink.sent.first as List<int>;

      final msg = fbs.ClientMessage(bytes);
      expect(msg.id, equals('req-0'));
      expect(
        msg.payloadType,
        equals(fbs.ClientRequestPayloadTypeId.HelloRequest),
      );

      final helloReq = msg.payload as fbs.HelloRequest;
      expect(helloReq.clientId, equals('client-123'));
      expect(helloReq.token, equals('token-abc'));
    });

    test('writeInput request translates to binary FlatBuffers', () async {
      await client.writeInput(
        sessionId: 'session-456',
        clientId: 'client-123',
        bytes: [1, 2, 3],
      );

      expect(sink.sent, hasLength(1));
      final bytes = sink.sent.first as List<int>;

      final msg = fbs.ClientMessage(bytes);
      expect(msg.id, equals('req-0'));
      expect(
        msg.payloadType,
        equals(fbs.ClientRequestPayloadTypeId.WriteInputRequestTable),
      );

      final writeReq = msg.payload as fbs.WriteInputRequestTable;
      expect(writeReq.sessionId, equals('session-456'));
      expect(writeReq.clientId, equals('client-123'));
      expect(writeReq.bytes, equals([1, 2, 3]));
    });

    test('resizeSession request translates to binary FlatBuffers', () async {
      client.resizeSession(sessionId: 'session-456', cols: 120, rows: 40);

      expect(sink.sent, hasLength(1));
      final bytes = sink.sent.first as List<int>;

      final msg = fbs.ClientMessage(bytes);
      expect(msg.id, equals('req-0'));
      expect(
        msg.payloadType,
        equals(fbs.ClientRequestPayloadTypeId.ResizeSessionRequestTable),
      );

      final resizeReq = msg.payload as fbs.ResizeSessionRequestTable;
      expect(resizeReq.sessionId, equals('session-456'));
      expect(resizeReq.size!.cols, equals(120));
      expect(resizeReq.size!.rows, equals(40));
    });
  });
}
