import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/generated/triage_triage.generated_generated.dart'
    as fbs;
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeWebSocketChannel implements WebSocketChannel {
  FakeWebSocketChannel({required this.sink, this.protocol, Future<void>? ready})
    : _ready = ready ?? Future.value();

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
  Future<void> get ready => _ready;

  final Future<void> _ready;

  @override
  Stream get stream => _streamController.stream;

  void addIncoming(Object? message) {
    _streamController.add(message);
  }

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
  test(
    'connect exposes the channel only after the handshake completes',
    () async {
      final sink = RecordingWebSocketSink();
      final ready = Completer<void>();
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) => FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-flatbuffers',
          ready: ready.future,
        ),
      );

      final connectFuture = client.connect();

      await Future<void>.delayed(Duration.zero);
      expect(client.isConnected, isFalse);
      expect(client.isFlatBuffersNegotiated, isFalse);

      ready.complete();
      await connectFuture;

      expect(client.isConnected, isTrue);
      expect(client.isFlatBuffersNegotiated, isTrue);
    },
  );

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

    tearDown(() async {
      await client.disconnect();
    });

    test('hello request translates to binary FlatBuffers', () async {
      final f = client.hello(clientId: 'client-123', token: 'token-abc');
      f.catchError((_) => <String, dynamic>{});

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

    test('pairingChallenge request translates to binary FlatBuffers', () async {
      final f = client.pairingChallenge(clientId: 'client-123');
      f.catchError((_) => <String, dynamic>{});

      expect(sink.sent, hasLength(1));
      final bytes = sink.sent.first as List<int>;

      final msg = fbs.ClientMessage(bytes);
      expect(msg.id, equals('req-0'));
      expect(
        msg.payloadType,
        equals(fbs.ClientRequestPayloadTypeId.PairingChallengeRequest),
      );

      final challengeReq = msg.payload as fbs.PairingChallengeRequest;
      expect(challengeReq.clientId, equals('client-123'));
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
      final f = client.resizeSession(
        sessionId: 'session-456',
        cols: 120,
        rows: 40,
      );
      f.catchError((_) => <String, dynamic>{});

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

    test('restoreSession request translates to binary FlatBuffers', () async {
      final f = client.restoreSession(
        sessionId: 'session-456',
        cols: 100,
        rows: 30,
      );
      f.catchError((_) => <String, dynamic>{});

      expect(sink.sent, hasLength(1));
      final bytes = sink.sent.first as List<int>;

      final msg = fbs.ClientMessage(bytes);
      expect(msg.id, equals('req-0'));
      expect(
        msg.payloadType,
        equals(fbs.ClientRequestPayloadTypeId.RestoreSessionRequestTable),
      );

      final restoreReq = msg.payload as fbs.RestoreSessionRequestTable;
      expect(restoreReq.sessionId, equals('session-456'));
      expect(restoreReq.size!.cols, equals(100));
      expect(restoreReq.size!.rows, equals(30));
    });

    test('attachSession request translates to binary FlatBuffers', () async {
      final f = client.attachSession(
        sessionId: 'session-789',
        clientId: 'client-abc',
        mode: 'Observer',
      );
      f.catchError((_) => <String, dynamic>{});

      expect(sink.sent, hasLength(1));
      final bytes = sink.sent.first as List<int>;

      final msg = fbs.ClientMessage(bytes);
      expect(msg.id, equals('req-0'));
      expect(
        msg.payloadType,
        equals(fbs.ClientRequestPayloadTypeId.AttachSessionRequestTable),
      );

      final attachReq = msg.payload as fbs.AttachSessionRequestTable;
      expect(attachReq.sessionId, equals('session-789'));
      expect(attachReq.clientId, equals('client-abc'));
      expect(attachReq.mode, equals(fbs.AttachMode.Observer));
    });

    test('attachSession rejects unknown attach modes', () async {
      await expectLater(
        client.attachSession(
          sessionId: 'session-789',
          clientId: 'client-abc',
          mode: 'observer',
        ),
        throwsArgumentError,
      );

      expect(sink.sent, isEmpty);
    });

    test(
      'subscribeSessionEvents request translates to binary FlatBuffers',
      () async {
        final f = client.subscribeSessionEvents(
          sessionId: 'session-789',
          afterEventSeq: 42,
        );
        f.catchError((_) => '');

        expect(sink.sent, hasLength(1));
        final bytes = sink.sent.first as List<int>;

        final msg = fbs.ClientMessage(bytes);
        expect(msg.id, equals('req-0'));
        expect(
          msg.payloadType,
          equals(
            fbs.ClientRequestPayloadTypeId.SubscribeSessionEventsRequestTable,
          ),
        );

        final subReq = msg.payload as fbs.SubscribeSessionEventsRequestTable;
        expect(subReq.sessionId, equals('session-789'));
        expect(subReq.afterEventSeq, equals(42));
      },
    );

    test('styledRows request translates to binary FlatBuffers', () async {
      final f = client.styledRows(sessionId: 'session-789', start: 10, end: 20);
      f.catchError((_) => <String, dynamic>{});

      expect(sink.sent, hasLength(1));
      final bytes = sink.sent.first as List<int>;

      final msg = fbs.ClientMessage(bytes);
      expect(msg.id, equals('req-0'));
      expect(
        msg.payloadType,
        equals(fbs.ClientRequestPayloadTypeId.StyledRowsRequestTable),
      );

      final styledReq = msg.payload as fbs.StyledRowsRequestTable;
      expect(styledReq.sessionId, equals('session-789'));
      expect(styledReq.start, equals(10));
      expect(styledReq.end, equals(20));
    });

    test('attachSession completes from binary FlatBuffers response', () async {
      final channel = FakeWebSocketChannel(
        sink: sink,
        protocol: 'triage-flatbuffers',
      );
      client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) => channel,
      );
      await client.connect();

      final future = client.attachSession(
        sessionId: 'session-789',
        clientId: 'client-abc',
      );

      final response = fbs.ServerMessageObjectBuilder(
        payloadType: fbs.ServerMessagePayloadTypeId.ResponsePayload,
        payload: fbs.ResponsePayloadObjectBuilder(
          id: 'req-0',
          resultType: fbs.ServerResultPayloadTypeId.AttachSessionResult,
          result: fbs.AttachSessionResultObjectBuilder(
            response: fbs.AttachSessionResponseObjectBuilder(
              snapshot: fbs.SessionSnapshotObjectBuilder(
                outputSeq: 1,
                bytesLogged: 2,
                size: fbs.SessionSizeObjectBuilder(
                  rows: 24,
                  cols: 80,
                  pixelWidth: 800,
                  pixelHeight: 480,
                  dpi: 96,
                ),
                visibleRows: ['ready'],
                styledRowsStart: 0,
                styledRows: [],
                bracketedPasteEnabled: false,
                exited: false,
              ),
              lease: fbs.InputLeaseStateObjectBuilder(generation: 1),
            ),
          ),
        ),
      ).toBytes();

      channel.addIncoming(response);

      final result = await future;
      expect(result['result'], equals('attach_session'));
      expect(result['response']['snapshot']['visible_rows'], equals(['ready']));
    });

    test(
      'pairingChallenge completes from binary FlatBuffers response',
      () async {
        final channel = FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-flatbuffers',
        );
        client = TriageWebSocketClient(
          Uri.parse('ws://localhost/ws'),
          channelFactory: (_) => channel,
        );
        await client.connect();

        final future = client.pairingChallenge(clientId: 'client-123');

        final response = fbs.ServerMessageObjectBuilder(
          payloadType: fbs.ServerMessagePayloadTypeId.ResponsePayload,
          payload: fbs.ResponsePayloadObjectBuilder(
            id: 'req-0',
            resultType: fbs.ServerResultPayloadTypeId.PairingChallengeResult,
            result: fbs.PairingChallengeResultObjectBuilder(
              deviceCode: 'DEVICE01',
              expiresAt: 123,
            ),
          ),
        ).toBytes();

        channel.addIncoming(response);

        final result = await future;
        expect(result['result'], equals('pairing_challenge'));
        expect(result['device_code'], equals('DEVICE01'));
        expect(result['expires_at'], equals(123));
      },
    );

    test(
      'attachSession completes from browser ByteBuffer FlatBuffers response',
      () async {
        final channel = FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-flatbuffers',
        );
        client = TriageWebSocketClient(
          Uri.parse('ws://localhost/ws'),
          channelFactory: (_) => channel,
        );
        await client.connect();

        final future = client.attachSession(
          sessionId: 'session-789',
          clientId: 'client-abc',
        );

        final response = fbs.ServerMessageObjectBuilder(
          payloadType: fbs.ServerMessagePayloadTypeId.ResponsePayload,
          payload: fbs.ResponsePayloadObjectBuilder(
            id: 'req-0',
            resultType: fbs.ServerResultPayloadTypeId.AttachSessionResult,
            result: fbs.AttachSessionResultObjectBuilder(
              response: fbs.AttachSessionResponseObjectBuilder(
                snapshot: fbs.SessionSnapshotObjectBuilder(
                  outputSeq: 1,
                  bytesLogged: 2,
                  size: fbs.SessionSizeObjectBuilder(
                    rows: 24,
                    cols: 80,
                    pixelWidth: 800,
                    pixelHeight: 480,
                    dpi: 96,
                  ),
                  visibleRows: ['from-byte-buffer'],
                  styledRowsStart: 0,
                  styledRows: [],
                  bracketedPasteEnabled: false,
                  exited: false,
                ),
                lease: fbs.InputLeaseStateObjectBuilder(generation: 1),
              ),
            ),
          ),
        ).toBytes();

        channel.addIncoming(Uint8List.fromList(response).buffer);

        final result = await future;
        expect(
          result['response']['snapshot']['visible_rows'],
          equals(['from-byte-buffer']),
        );
      },
    );

    test(
      'styledRows completes with error from binary FlatBuffers response',
      () async {
        final channel = FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-flatbuffers',
        );
        client = TriageWebSocketClient(
          Uri.parse('ws://localhost/ws'),
          channelFactory: (_) => channel,
        );
        await client.connect();

        final future = client.styledRows(
          sessionId: 'session-789',
          start: 0,
          end: 200,
        );

        final response = fbs.ServerMessageObjectBuilder(
          payloadType: fbs.ServerMessagePayloadTypeId.ErrorPayload,
          payload: fbs.ErrorPayloadObjectBuilder(
            id: 'req-0',
            code: 'request_failed',
            message: 'styled row range 0..200 exceeds retained row count 44',
          ),
        ).toBytes();

        channel.addIncoming(response);

        await expectLater(
          future,
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('styled row range'),
            ),
          ),
        );
      },
    );

    test(
      'binary FlatBuffers events use JSON-compatible envelope shape',
      () async {
        final channel = FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-flatbuffers',
        );
        client = TriageWebSocketClient(
          Uri.parse('ws://localhost/ws'),
          channelFactory: (_) => channel,
        );
        await client.connect();

        final eventFuture = client.events.first;
        final outputEvent = fbs.ServerMessageObjectBuilder(
          payloadType: fbs.ServerMessagePayloadTypeId.EventPayload,
          payload: fbs.EventPayloadObjectBuilder(
            subscriptionId: 'sub-1',
            eventSeq: 7,
            eventType: fbs.SessionEventPayloadTypeId.OutputEvent,
            event: fbs.OutputEventObjectBuilder(
              sessionId: 'session-789',
              outputSeq: 42,
              bytes: Uint8List.fromList([112, 119, 100]),
            ),
          ),
        ).toBytes();

        channel.addIncoming(ByteData.sublistView(outputEvent));

        final event = await eventFuture;
        expect(event['type'], equals('event'));
        expect(event['subscription_id'], equals('sub-1'));
        expect(event['envelope']['event_seq'], equals(7));
        expect(event['envelope']['event']['Output'], {
          'session_id': 'session-789',
          'output_seq': 42,
          'bytes': [112, 119, 100],
        });
      },
    );
  });
}
