import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flat_buffers/flat_buffers.dart' as fb;
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/generated/triage_triage.generated_generated.dart'
    as fbs;
import 'package:triage_client/services/flatbuffers_js_compat.dart' as fbjs;
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeWebSocketChannel implements WebSocketChannel {
  FakeWebSocketChannel({required this.sink, this.protocol, Future<void>? ready})
    : _ready = ready ?? Future.value();

  /// Kill the underlying socket, as a real one does when it finally gives up:
  /// an optional error, then done.
  void die([Object? error]) {
    if (_streamController.isClosed) return;
    if (error != null) {
      _streamController.addError(error);
    }
    _streamController.close();
  }

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
  int closeCalls = 0;

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
  Future<void> close([int? closeCode, String? closeReason]) async {
    closeCalls += 1;
  }
}

class ThrowingWebSocketSink extends RecordingWebSocketSink {
  @override
  void add(Object? event) {
    throw StateError('sink closed');
  }
}

/// An agent attachment whose wire kind (99) no checked-in enum knows,
/// exercising the unknown-kind degrade path through a full decode. The
/// generated object builder cannot express an unknown enum, so this
/// mirrors its `finish` with the kind byte pinned past the table.
class _UnknownKindAgentBuilder extends fbs.AgentAttachmentObjectBuilder {
  _UnknownKindAgentBuilder({
    String? conversationId,
    String? transcriptPath,
    String? exePath,
    int? lastSeenMs,
  }) : _conversationId = conversationId,
       _transcriptPath = transcriptPath,
       _exePath = exePath,
       _lastSeenMs = lastSeenMs,
       super(kind: null);

  final String? _conversationId;
  final String? _transcriptPath;
  final String? _exePath;
  final int? _lastSeenMs;

  @override
  int finish(fb.Builder fbBuilder) {
    final conversationId = _conversationId;
    final transcriptPath = _transcriptPath;
    final exePath = _exePath;
    final int? conversationIdOffset = conversationId == null
        ? null
        : fbBuilder.writeString(conversationId);
    final int? transcriptPathOffset = transcriptPath == null
        ? null
        : fbBuilder.writeString(transcriptPath);
    final int? exePathOffset = exePath == null
        ? null
        : fbBuilder.writeString(exePath);
    fbBuilder.startTable(5);
    fbBuilder.addInt8(0, 99);
    fbBuilder.addOffset(1, conversationIdOffset);
    fbBuilder.addOffset(2, transcriptPathOffset);
    fbBuilder.addOffset(3, exePathOffset);
    fbjs.addUint64(fbBuilder, 4, _lastSeenMs);
    return fbBuilder.endTable();
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

  test('connect gives up when the handshake never completes', () {
    fakeAsync((async) {
      final sink = RecordingWebSocketSink();
      // A `ready` that never settles — a half-open socket, which is what a
      // phone gets when its network changes while the app is backgrounded.
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) =>
            FakeWebSocketChannel(sink: sink, ready: Completer<void>().future),
      );

      Object? error;
      client.connect().catchError((Object e) {
        error = e;
      });
      async.elapse(
        TriageWebSocketClient.connectTimeout + const Duration(seconds: 1),
      );

      // The attempt must terminate: callers treat an in-flight connect as
      // "don't start another one", so a connect that hangs forever would wedge
      // reconnection permanently.
      expect(error, isA<TimeoutException>());
      expect(client.isConnected, isFalse);
    });
  });

  test('a timed-out connect retires the channel it abandoned', () {
    fakeAsync((async) {
      final sink = RecordingWebSocketSink();
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) =>
            FakeWebSocketChannel(sink: sink, ready: Completer<void>().future),
      );

      client.connect().catchError((Object _) {});
      async.elapse(
        TriageWebSocketClient.connectTimeout + const Duration(seconds: 1),
      );

      // The handshake it gave up on is still running, so the socket has to be
      // closed and unsubscribed — otherwise it keeps delivering into a client
      // that has moved on.
      expect(sink.closeCalls, 1);
    });
  });

  test('a superseded channel dying cannot disown the live one', () {
    fakeAsync((async) {
      final channels = <FakeWebSocketChannel>[];
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) {
          final channel = FakeWebSocketChannel(sink: RecordingWebSocketSink());
          channels.add(channel);
          return channel;
        },
      );

      // Connect, drop, reconnect — the ordinary reconnect cycle. `disconnect`
      // does not cancel the old channel's listener, so channel #1 is still wired
      // to the client when it finally dies.
      client.connect();
      async.flushMicrotasks();
      client.disconnect();
      async.elapse(TriageWebSocketClient.closeTimeout);
      client.connect();
      async.flushMicrotasks();
      expect(client.isConnected, isTrue);
      expect(channels.length, 2);

      final events = <Map<String, dynamic>>[];
      client.events.listen(events.add);

      // Channel #1's socket finally gives up, well after #2 took over. It must
      // not null out `_channel`, fail #2's in-flight requests, or report the
      // live connection closed.
      channels.first.die(StateError('socket reset'));
      async.flushMicrotasks();

      expect(client.isConnected, isTrue);
      expect(events, isEmpty);
    });
  });

  test('connect fails when the socket closes during the handshake', () {
    fakeAsync((async) {
      late FakeWebSocketChannel channel;
      final ready = Completer<void>();
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) {
          channel = FakeWebSocketChannel(
            sink: RecordingWebSocketSink(),
            ready: ready.future,
          );
          return channel;
        },
      );

      Object? error;
      client.connect().catchError((Object e) {
        error = e;
      });
      async.flushMicrotasks();

      // The server accepts the upgrade and closes immediately (a daemon shutting
      // down mid-handshake). `done` lands in the gap before we take ownership.
      channel.die();
      ready.complete();
      async.flushMicrotasks();

      // Storing that channel would leave us "connected" to a corpse: writes
      // vanish and no close is ever reported.
      expect(error, isNotNull);
      expect(client.isConnected, isFalse);
    });
  });

  test('an unauthorized error response surfaces as TriageAuthException', () {
    fakeAsync((async) {
      final sink = RecordingWebSocketSink();
      late FakeWebSocketChannel channel;
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) {
          channel = FakeWebSocketChannel(sink: sink, protocol: 'triage-json');
          return channel;
        },
      );

      client.connect();
      async.flushMicrotasks();

      Object? error;
      client.hello(clientId: 'c1', token: 'stale-token').catchError((Object e) {
        error = e;
        return <String, dynamic>{};
      });
      async.flushMicrotasks();

      final id =
          (jsonDecode(sink.sent.single as String)
              as Map<String, dynamic>)['id'];
      channel.addIncoming(
        jsonEncode({
          'type': 'error',
          'id': id,
          'error': {'code': 'unauthorized', 'message': 'unauthorized'},
        }),
      );
      async.flushMicrotasks();

      // Typed, not message-sniffed: a rejected token must route to pairing
      // rather than an endless reconnect backoff.
      expect(error, isA<TriageAuthException>());
    });
  });

  test('a non-auth error response stays a plain Exception', () {
    fakeAsync((async) {
      final sink = RecordingWebSocketSink();
      late FakeWebSocketChannel channel;
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) {
          channel = FakeWebSocketChannel(sink: sink, protocol: 'triage-json');
          return channel;
        },
      );

      client.connect();
      async.flushMicrotasks();

      Object? error;
      client.listSessions().catchError((Object e) {
        error = e;
        return <String>[];
      });
      async.flushMicrotasks();

      final id =
          (jsonDecode(sink.sent.single as String)
              as Map<String, dynamic>)['id'];
      channel.addIncoming(
        jsonEncode({
          'type': 'error',
          'id': id,
          'error': {'code': 'internal', 'message': 'boom'},
        }),
      );
      async.flushMicrotasks();

      expect(error, isA<Exception>());
      expect(error, isNot(isA<TriageAuthException>()));
    });
  });

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

    test('binary is offered ahead of JSON, with JSON retained', () {
      // The daemon takes the first token it recognizes from the client's list,
      // so this order *is* the default-format decision. JSON must stay present:
      // dropping it would leave a pre-binary daemon with nothing to negotiate.
      expect(
        websocketSubprotocols,
        equals(['triage-flatbuffers', 'triage-json']),
      );
    });

    test(
      'listSessionContexts request translates to binary FlatBuffers',
      () async {
        // Regression: this case was missing from the request switch, so the
        // request threw UnimplementedError on any flatbuffers-negotiated
        // connection. It stayed hidden because the client offered only
        // `triage-json`, so the binary path was never taken — and the caller
        // swallows the throw, so flipping the default would have degraded the
        // side rail silently rather than failing loudly.
        final f = client.listSessionContexts();
        f.catchError((_) => const <String, SessionContextRecord>{});

        expect(sink.sent, hasLength(1));
        final bytes = sink.sent.first as List<int>;

        final msg = fbs.ClientMessage(bytes);
        expect(msg.id, equals('req-0'));
        expect(
          msg.payloadType,
          equals(fbs.ClientRequestPayloadTypeId.ListSessionContextsRequest),
        );
      },
    );

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

    test('pairViaTailscale request translates to binary FlatBuffers', () async {
      final f = client.pairViaTailscale(clientId: 'client-123');
      f.catchError((_) => '');

      expect(sink.sent, hasLength(1));
      final bytes = sink.sent.first as List<int>;

      final msg = fbs.ClientMessage(bytes);
      expect(msg.id, equals('req-0'));
      expect(
        msg.payloadType,
        equals(fbs.ClientRequestPayloadTypeId.PairViaTailscaleRequest),
      );

      final pairReq = msg.payload as fbs.PairViaTailscaleRequest;
      expect(pairReq.clientId, equals('client-123'));
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
                agent: fbs.AgentAttachmentObjectBuilder(
                  kind: fbs.AgentKind.Muse,
                  conversationId: 'abc',
                  transcriptPath: '/tmp/t.jsonl',
                  exePath: '/bin/muse',
                  lastSeenMs: 42,
                ),
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
      // Parsed agent keys match the JSON transport's serde `snake_case`.
      expect(
        result['response']['snapshot']['agent'],
        equals({
          'kind': 'muse',
          'conversation_id': 'abc',
          'transcript_path': '/tmp/t.jsonl',
          'exe_path': '/bin/muse',
          'last_seen_ms': 42,
        }),
      );
    });

    test('attachSession decodes an absent agent as null', () async {
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
      expect(result['response']['snapshot']['agent'], isNull);
    });

    test('attachSession decodes every agent kind from binary', () async {
      const kinds = {
        fbs.AgentKind.Claude: 'claude',
        fbs.AgentKind.Codex: 'codex',
        fbs.AgentKind.Antigravity: 'antigravity',
        fbs.AgentKind.Muse: 'muse',
        fbs.AgentKind.Grok: 'grok',
      };
      for (final entry in kinds.entries) {
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
                  agent: fbs.AgentAttachmentObjectBuilder(kind: entry.key),
                ),
                lease: fbs.InputLeaseStateObjectBuilder(generation: 1),
              ),
            ),
          ),
        ).toBytes();

        channel.addIncoming(response);

        final result = await future;
        expect(
          result['response']['snapshot']['agent']['kind'],
          equals(entry.value),
          reason: 'kind ${entry.key} must decode to ${entry.value}',
        );
      }
    });

    test(
      'attachSession degrades an unknown agent kind, not the attachment',
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
                  visibleRows: ['ready'],
                  styledRowsStart: 0,
                  styledRows: [],
                  bracketedPasteEnabled: false,
                  exited: false,
                  agent: _UnknownKindAgentBuilder(
                    conversationId: 'abc',
                    transcriptPath: '/tmp/t.jsonl',
                    exePath: '/bin/future',
                    lastSeenMs: 42,
                  ),
                ),
                lease: fbs.InputLeaseStateObjectBuilder(generation: 1),
              ),
            ),
          ),
        ).toBytes();

        channel.addIncoming(response);

        final result = await future;
        // The kind degrades to null (the badge shows 'agent'); every other
        // field survives, so a future agent never renders as a plain shell.
        expect(
          result['response']['snapshot']['agent'],
          equals({
            'kind': null,
            'conversation_id': 'abc',
            'transcript_path': '/tmp/t.jsonl',
            'exe_path': '/bin/future',
            'last_seen_ms': 42,
          }),
        );
      },
    );

    test(
      'listSessionContexts completes from binary FlatBuffers response',
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

        final future = client.listSessionContexts();

        final response = fbs.ServerMessageObjectBuilder(
          payloadType: fbs.ServerMessagePayloadTypeId.ResponsePayload,
          payload: fbs.ResponsePayloadObjectBuilder(
            id: 'req-0',
            resultType: fbs.ServerResultPayloadTypeId.SessionContextsResult,
            result: fbs.SessionContextsResultObjectBuilder(
              entries: [
                fbs.SessionContextEntryObjectBuilder(
                  sessionId: 'session-1',
                  repositoryRoot: '/repo',
                  worktreeRoot: '/repo/worktrees/feat',
                  branch: 'feat/x',
                  lastActivityMs: 1782616328232,
                  lastInputMs: 1782616330000,
                ),
                // A session outside any repository, and one that has produced no
                // output: both must decode as absent/zero rather than throwing
                // or dropping the entry.
                fbs.SessionContextEntryObjectBuilder(sessionId: 'session-2'),
              ],
            ),
          ),
        ).toBytes();

        channel.addIncoming(response);

        final result = await future;
        expect(result.keys, containsAll(<String>['session-1', 'session-2']));
        expect(result['session-1']!.repositoryRoot, equals('/repo'));
        expect(
          result['session-1']!.worktreeRoot,
          equals('/repo/worktrees/feat'),
        );
        expect(result['session-1']!.branch, equals('feat/x'));
        expect(result['session-2']!.repositoryRoot, isNull);
        // Dropping this field decodes fine and orders the rail by id instead,
        // the failure this branch exists to prevent, and one nothing else
        // would report.
        expect(result['session-1']!.lastActivityMs, equals(1782616328232));
        expect(result['session-2']!.lastActivityMs, equals(0));
        expect(result['session-1']!.lastInputMs, equals(1782616330000));
        expect(result['session-2']!.lastInputMs, equals(0));
      },
    );

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

    // The self-update fields ride HelloResult, and `hello` hands its whole map
    // to callers — so a field the binary decoder forgets simply stops arriving
    // once FlatBuffers is the negotiated default, with nothing failing.
    test(
      'hello carries the self-update fields, not just the handshake',
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

        final future = client.hello(clientId: 'client-abc');
        channel.addIncoming(
          fbs.ServerMessageObjectBuilder(
            payloadType: fbs.ServerMessagePayloadTypeId.ResponsePayload,
            payload: fbs.ResponsePayloadObjectBuilder(
              id: 'req-0',
              resultType: fbs.ServerResultPayloadTypeId.HelloResult,
              result: fbs.HelloResultObjectBuilder(
                protocolVersion: '1',
                authenticated: true,
                serverVersion: '0.9.0',
                updateAvailable: true,
                latestVersion: '1.0.0',
                tailscalePairingAvailable: true,
                cpuPercent: 37,
                batteryPercent: 82,
                batteryState: fbs.BatteryState.Charging,
              ),
            ),
          ).toBytes(),
        );

        final result = await future;
        expect(result['protocol_version'], equals('1'));
        expect(result['authenticated'], isTrue);
        expect(result['server_version'], equals('0.9.0'));
        expect(result['update_available'], isTrue);
        expect(result['latest_version'], equals('1.0.0'));
        expect(result['tailscale_pairing_available'], isTrue);
        expect(result['cpu_percent'], equals(37));
        expect(result['battery_percent'], equals(82));
        expect(result['battery_state'], equals('charging'));
      },
    );

    test('getDaemonStats decodes FlatBuffers DaemonStatsResult', () async {
      final channel = FakeWebSocketChannel(
        sink: sink,
        protocol: 'triage-flatbuffers',
      );
      client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) => channel,
      );
      await client.connect();

      final future = client.getDaemonStats();
      channel.addIncoming(
        fbs.ServerMessageObjectBuilder(
          payloadType: fbs.ServerMessagePayloadTypeId.ResponsePayload,
          payload: fbs.ResponsePayloadObjectBuilder(
            id: 'req-0',
            resultType: fbs.ServerResultPayloadTypeId.DaemonStatsResult,
            result: fbs.DaemonStatsResultObjectBuilder(
              diskFreeBytes: 12345,
              diskTotalBytes: 67890,
              cpuPercent: 19,
              batteryPercent: 64,
              batteryState: fbs.BatteryState.Discharging,
            ),
          ),
        ).toBytes(),
      );

      final stats = await future;
      expect(stats, isNotNull);
      expect(stats!.diskFreeBytes, equals(12345));
      expect(stats.diskTotalBytes, equals(67890));
      expect(stats.cpuPercent, equals(19));
      expect(stats.batteryPercent, equals(64));
      expect(stats.batteryState, equals('discharging'));
    });

    test('hello omits latest_version until a release check has run', () async {
      final channel = FakeWebSocketChannel(
        sink: sink,
        protocol: 'triage-flatbuffers',
      );
      client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) => channel,
      );
      await client.connect();

      final future = client.hello(clientId: 'client-abc');
      channel.addIncoming(
        fbs.ServerMessageObjectBuilder(
          payloadType: fbs.ServerMessagePayloadTypeId.ResponsePayload,
          payload: fbs.ResponsePayloadObjectBuilder(
            id: 'req-0',
            resultType: fbs.ServerResultPayloadTypeId.HelloResult,
            result: fbs.HelloResultObjectBuilder(
              protocolVersion: '1',
              authenticated: true,
              serverVersion: '0.9.0',
              updateAvailable: false,
            ),
          ),
        ).toBytes(),
      );

      // Absent rather than null, matching the daemon's `skip_serializing_if`.
      expect(await future, isNot(contains('latest_version')));
    });

    test('decodes RailPinsUpdatedPayload push broadcast', () async {
      final channel = FakeWebSocketChannel(
        sink: sink,
        protocol: 'triage-flatbuffers',
      );
      client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) => channel,
      );
      await client.connect();

      final events = <Map<String, dynamic>>[];
      client.events.listen(events.add);

      channel.addIncoming(
        fbs.ServerMessageObjectBuilder(
          payloadType: fbs.ServerMessagePayloadTypeId.RailPinsUpdatedPayload,
          payload: fbs.RailPinsUpdatedPayloadObjectBuilder(
            groupKeys: ['/repo/a'],
            sessionIds: ['session-1', 'session-2'],
          ),
        ).toBytes(),
      );

      await pumpEventQueue();
      expect(events, hasLength(1));
      expect(events.first, {
        'type': 'rail_pins_updated',
        'group_keys': ['/repo/a'],
        'session_ids': ['session-1', 'session-2'],
      });
    });

    test(
      'decodes SessionCustomLabelUpdatedPayload with label and cleared label',
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

        final events = <Map<String, dynamic>>[];
        client.events.listen(events.add);

        channel.addIncoming(
          fbs.ServerMessageObjectBuilder(
            payloadType:
                fbs.ServerMessagePayloadTypeId.SessionCustomLabelUpdatedPayload,
            payload: fbs.SessionCustomLabelUpdatedPayloadObjectBuilder(
              sessionId: 's-42',
              label: 'Worker Node',
              hasLabel: true,
            ),
          ).toBytes(),
        );

        channel.addIncoming(
          fbs.ServerMessageObjectBuilder(
            payloadType:
                fbs.ServerMessagePayloadTypeId.SessionCustomLabelUpdatedPayload,
            payload: fbs.SessionCustomLabelUpdatedPayloadObjectBuilder(
              sessionId: 's-42',
              label: null,
              hasLabel: false,
            ),
          ).toBytes(),
        );

        await pumpEventQueue();
        expect(events, hasLength(2));
        expect(events[0], {
          'type': 'session_custom_label_updated',
          'session_id': 's-42',
          'custom_label': 'Worker Node',
        });
        expect(events[1], {
          'type': 'session_custom_label_updated',
          'session_id': 's-42',
          'custom_label': null,
        });
      },
    );

    test('getRailLayout decodes FlatBuffers RailLayoutResult', () async {
      final channel = FakeWebSocketChannel(
        sink: sink,
        protocol: 'triage-flatbuffers',
      );
      client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) => channel,
      );
      await client.connect();

      final future = client.getRailLayout();
      channel.addIncoming(
        fbs.ServerMessageObjectBuilder(
          payloadType: fbs.ServerMessagePayloadTypeId.ResponsePayload,
          payload: fbs.ResponsePayloadObjectBuilder(
            id: 'req-0',
            resultType: fbs.ServerResultPayloadTypeId.RailLayoutResult,
            result: fbs.RailLayoutResultObjectBuilder(
              groupKeys: ['/repo/main'],
              sessionIds: ['session-x'],
              customLabels: [
                fbs.CustomLabelEntryObjectBuilder(
                  sessionId: 'session-x',
                  label: 'Primary Task',
                ),
              ],
            ),
          ),
        ).toBytes(),
      );

      final layout = await future;
      expect(layout, isNotNull);
      expect(layout!.groupKeys, ['/repo/main']);
      expect(layout.sessionIds, ['session-x']);
      expect(layout.customLabels, {'session-x': 'Primary Task'});
    });

    test(
      'decodes SessionStartedPayload and SessionTerminatedPayload push broadcast',
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

        final events = <Map<String, dynamic>>[];
        client.events.listen(events.add);

        channel.addIncoming(
          fbs.ServerMessageObjectBuilder(
            payloadType: fbs.ServerMessagePayloadTypeId.SessionStartedPayload,
            payload: fbs.SessionStartedPayloadObjectBuilder(
              sessionId: 'session-remote-1',
              repositoryRoot: '/home/user/project',
              branch: 'main',
              lastActivityMs: 1720000000000,
              lastInputMs: 1720000000001,
            ),
          ).toBytes(),
        );

        channel.addIncoming(
          fbs.ServerMessageObjectBuilder(
            payloadType:
                fbs.ServerMessagePayloadTypeId.SessionTerminatedPayload,
            payload: fbs.SessionTerminatedPayloadObjectBuilder(
              sessionId: 'session-remote-1',
            ),
          ).toBytes(),
        );

        await pumpEventQueue();
        expect(events, hasLength(2));
        expect(events[0], {
          'type': 'session_started',
          'session_id': 'session-remote-1',
          'current_working_directory': null,
          'repository_root': '/home/user/project',
          'worktree_root': null,
          'branch': 'main',
          'last_activity_ms': 1720000000000,
          'last_input_ms': 1720000000001,
        });
        expect(events[1], {
          'type': 'session_terminated',
          'session_id': 'session-remote-1',
        });
      },
    );
  });

  test(
    'dispatches session_started and session_terminated text events',
    () async {
      final sink = RecordingWebSocketSink();
      final channel = FakeWebSocketChannel(sink: sink);
      final textClient = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) => channel,
      );
      await textClient.connect();

      final events = <Map<String, dynamic>>[];
      textClient.events.listen(events.add);

      channel.addIncoming(
        jsonEncode({
          'type': 'session_started',
          'session_id': 'session-text-1',
          'repository_root': '/home/user/repo',
          'branch': 'feature',
        }),
      );

      channel.addIncoming(
        jsonEncode({
          'type': 'session_terminated',
          'session_id': 'session-text-1',
        }),
      );

      await pumpEventQueue();
      expect(events, hasLength(2));
      expect(events[0], {
        'type': 'session_started',
        'session_id': 'session-text-1',
        'repository_root': '/home/user/repo',
        'branch': 'feature',
      });
      expect(events[1], {
        'type': 'session_terminated',
        'session_id': 'session-text-1',
      });
    },
  );

  group('Default FlatBuffers Negotiation', () {
    test('defaults to FlatBuffers when protocol is omitted or null', () async {
      final sink = RecordingWebSocketSink();
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) => FakeWebSocketChannel(sink: sink),
      );
      await client.connect();

      expect(client.isConnected, isTrue);
      expect(client.isFlatBuffersNegotiated, isTrue);
    });

    test('defaults to FlatBuffers when protocol is empty string', () async {
      final sink = RecordingWebSocketSink();
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) => FakeWebSocketChannel(sink: sink, protocol: ''),
      );
      await client.connect();

      expect(client.isConnected, isTrue);
      expect(client.isFlatBuffersNegotiated, isTrue);
    });

    test('uses FlatBuffers when triage-flatbuffers is selected', () async {
      final sink = RecordingWebSocketSink();
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) =>
            FakeWebSocketChannel(sink: sink, protocol: 'triage-flatbuffers'),
      );
      await client.connect();

      expect(client.isConnected, isTrue);
      expect(client.isFlatBuffersNegotiated, isTrue);
    });

    test('uses JSON only when triage-json is explicitly negotiated', () async {
      final sink = RecordingWebSocketSink();
      final client = TriageWebSocketClient(
        Uri.parse('ws://localhost/ws'),
        channelFactory: (_) =>
            FakeWebSocketChannel(sink: sink, protocol: 'triage-json'),
      );
      await client.connect();

      expect(client.isConnected, isTrue);
      expect(client.isFlatBuffersNegotiated, isFalse);
    });
  });

  group('rawOutputFromSnapshot decompression', () {
    test('decompresses gzip base64 encoded raw_output', () {
      final original = utf8.encode('Terminal history scrollback\nLine 2\n');
      final gzipped = GZipEncoder().encode(original);
      final encoded = base64Encode(gzipped);

      final snapshot = <String, dynamic>{'raw_output': encoded};
      final result = rawOutputFromSnapshot(snapshot);

      expect(result, equals(Uint8List.fromList(original)));
    });

    test('decodes uncompressed base64 raw_output fallback', () {
      final original = utf8.encode('Uncompressed text');
      final encoded = base64Encode(original);

      final snapshot = <String, dynamic>{'raw_output': encoded};
      final result = rawOutputFromSnapshot(snapshot);

      expect(result, equals(Uint8List.fromList(original)));
    });

    test('accepts legacy integer list raw_output', () {
      final original = [65, 66, 67, 68];
      final snapshot = <String, dynamic>{'raw_output': original};
      final result = rawOutputFromSnapshot(snapshot);

      expect(result, equals(Uint8List.fromList(original)));
    });

    test('passes through existing Uint8List directly', () {
      final original = Uint8List.fromList([1, 2, 3, 4]);
      final snapshot = <String, dynamic>{'raw_output': original};
      final result = rawOutputFromSnapshot(snapshot);

      expect(identical(result, original), isTrue);
    });

    test('returns empty Uint8List on empty string or missing field', () {
      expect(rawOutputFromSnapshot({'raw_output': ''}), isEmpty);
      expect(rawOutputFromSnapshot({}), isEmpty);
      expect(rawOutputFromSnapshot({'raw_output': null}), isEmpty);
    });

    test('history gate counts either the raw tail or the prefix', () {
      final raw = Uint8List.fromList([1, 2, 3]);
      final prefix = Uint8List.fromList([4, 5]);
      expect(
        snapshotCarriesHistory({
          'raw_output': raw,
          'raw_output_prefix': prefix,
        }),
        isTrue,
      );
      expect(snapshotCarriesHistory({'raw_output': raw}), isTrue);
      // A prefix-only restore snapshot still carries history: dropping
      // the prefix leg silently discards it as history-less.
      expect(snapshotCarriesHistory({'raw_output_prefix': prefix}), isTrue);
      expect(snapshotCarriesHistory({'raw_output': Uint8List(0)}), isFalse);
      expect(snapshotCarriesHistory({}), isFalse);
    });

    test(
      'prefix extractor reads raw_output_prefix with the same encodings',
      () {
        final original = utf8.encode('journaled old line\n');
        final encoded = base64Encode(GZipEncoder().encode(original));
        expect(
          rawOutputPrefixFromSnapshot({'raw_output_prefix': encoded}),
          equals(Uint8List.fromList(original)),
        );
        expect(rawOutputPrefixFromSnapshot({}), isEmpty);
        expect(
          rawOutputPrefixFromSnapshot({'raw_output_prefix': null}),
          isEmpty,
        );
        // The raw tail key must not leak into the prefix: a wrong key
        // string fails silent as an empty prefix at every attach site.
        expect(rawOutputPrefixFromSnapshot({'raw_output': encoded}), isEmpty);
      },
    );

    test(
      'rawOutputViewportFromSnapshot encodes styled_rows and cursor when split history is present',
      () {
        final raw = Uint8List.fromList(utf8.encode('raw-tail'));
        final prefix = Uint8List.fromList(utf8.encode('\x1b[0mprefix\r\n'));
        final snapshot = <String, dynamic>{
          'raw_output': raw,
          'raw_output_prefix': prefix,
          'styled_rows_start': 10,
          'styled_rows': [
            {
              'spans': [
                {
                  'text': 'Row 0   ',
                  'style': {'bold': true},
                },
              ],
            },
            {
              'spans': [
                {'text': 'Row 1', 'style': <String, dynamic>{}},
              ],
            },
          ],
          'cursor': {'row': 11, 'col': 5, 'visible': true},
        };
        final viewport = utf8.decode(rawOutputViewportFromSnapshot(snapshot));
        expect(viewport, contains('Row 0'));
        expect(viewport, isNot(contains('Row 0   ')));
        expect(viewport, contains('\r\n'));
        expect(viewport, contains('\r\x1b[5C\x1b[?25h'));
        expect(rawOutputViewportFromSnapshot({'raw_output': raw}), isEmpty);
      },
    );

    test('rejects corrupted gzip stream and returns empty Uint8List', () {
      final corrupt = [0x1f, 0x8b, 0x08, 0x00, 0xff, 0xff, 0xff];
      final encoded = base64Encode(corrupt);

      final snapshot = <String, dynamic>{'raw_output': encoded};
      final result = rawOutputFromSnapshot(snapshot);

      expect(result, isEmpty);
    });

    test('handles malformed list gracefully without throwing TypeError', () {
      final snapshot = <String, dynamic>{
        'raw_output': [65, null, 'invalid', 68],
      };
      final result = rawOutputFromSnapshot(snapshot);

      expect(result, isEmpty);
    });

    test(
      'rejects gzip payload whose footer ISIZE exceeds 16 MiB ceiling without decompressing',
      () {
        final original = utf8.encode('Small payload');
        final gzipped = List<int>.from(GZipEncoder().encode(original));
        expect(gzipped.length, greaterThanOrEqualTo(8));
        // Overwrite ISIZE with 32 MiB (0x02000000 in little-endian)
        final len = gzipped.length;
        gzipped[len - 4] = 0x00;
        gzipped[len - 3] = 0x00;
        gzipped[len - 2] = 0x00;
        gzipped[len - 1] = 0x02;

        final encoded = base64Encode(gzipped);
        final snapshot = <String, dynamic>{'raw_output': encoded};
        final result = rawOutputFromSnapshot(snapshot);

        expect(result, isEmpty);
      },
    );
  });

  group('isUsableDaemonStats', () {
    test('rejects null and zero-total probe failures', () {
      expect(isUsableDaemonStats(null), isFalse);
      expect(
        isUsableDaemonStats((
          diskFreeBytes: 0,
          diskTotalBytes: 0,
          cpuPercent: null,
          batteryPercent: null,
          batteryState: 'unknown',
        )),
        isFalse,
      );
    });

    test('accepts positive totals including a full disk', () {
      expect(
        isUsableDaemonStats((
          diskFreeBytes: 0,
          diskTotalBytes: 100,
          cpuPercent: null,
          batteryPercent: null,
          batteryState: 'unknown',
        )),
        isTrue,
      );
      expect(
        isUsableDaemonStats((
          diskFreeBytes: 50,
          diskTotalBytes: 100,
          cpuPercent: 12,
          batteryPercent: 87,
          batteryState: 'charging',
        )),
        isTrue,
      );
    });

    test('accepts host-only readings when disk is unknown', () {
      expect(
        isUsableDaemonStats((
          diskFreeBytes: 0,
          diskTotalBytes: 0,
          cpuPercent: 12,
          batteryPercent: null,
          batteryState: 'unknown',
        )),
        isTrue,
      );
      expect(
        isUsableDaemonStats((
          diskFreeBytes: 0,
          diskTotalBytes: 0,
          cpuPercent: null,
          batteryPercent: 87,
          batteryState: 'discharging',
        )),
        isTrue,
      );
    });
  });

  group('daemonStatsFromResponse', () {
    test('reads host legs alongside disk', () {
      final stats = daemonStatsFromResponse({
        'disk_free_bytes': 50,
        'disk_total_bytes': 100,
        'cpu_percent': 12,
        'battery_percent': 87,
        'battery_state': 'charging',
      });
      expect(stats.diskFreeBytes, 50);
      expect(stats.diskTotalBytes, 100);
      expect(stats.cpuPercent, 12);
      expect(stats.batteryPercent, 87);
      expect(stats.batteryState, 'charging');
    });

    test('missing keys degrade to hidden legs (old daemons)', () {
      final stats = daemonStatsFromResponse({
        'disk_free_bytes': 50,
        'disk_total_bytes': 100,
      });
      expect(stats.cpuPercent, isNull);
      expect(stats.batteryPercent, isNull);
      expect(stats.batteryState, 'unknown');
    });

    test('normalizes sentinel, clamp, non-finite numbers, and bad state', () {
      final stats = daemonStatsFromResponse({
        'disk_free_bytes': double.nan,
        'disk_total_bytes': double.infinity,
        'cpu_percent': -1,
        'battery_percent': 101,
        'battery_state': 'calibrating',
      });
      expect(stats.diskFreeBytes, 0);
      expect(stats.diskTotalBytes, 0);
      expect(stats.cpuPercent, isNull);
      expect(stats.batteryPercent, 100);
      expect(stats.batteryState, 'unknown');
    });

    test(
      'mergeDaemonStats retains previous legs when incoming legs are unknown',
      () {
        const previous = (
          diskFreeBytes: 40,
          diskTotalBytes: 100,
          cpuPercent: 18,
          batteryPercent: 75,
          batteryState: 'discharging',
        );
        final afterZeroDiskAndNullHost = mergeDaemonStats(previous, (
          diskFreeBytes: 0,
          diskTotalBytes: 0,
          cpuPercent: null,
          batteryPercent: null,
          batteryState: 'unknown',
        ));
        expect(afterZeroDiskAndNullHost, equals(previous));

        final afterPartialUpdate = mergeDaemonStats(previous, (
          diskFreeBytes: 35,
          diskTotalBytes: 100,
          cpuPercent: null,
          batteryPercent: 80,
          batteryState: 'charging',
        ));
        expect(afterPartialUpdate.diskFreeBytes, 35);
        expect(afterPartialUpdate.diskTotalBytes, 100);
        expect(afterPartialUpdate.cpuPercent, 18);
        expect(afterPartialUpdate.batteryPercent, 80);
        expect(afterPartialUpdate.batteryState, 'charging');
      },
    );
  });

  group('millisSinceLastInbound', () {
    test(
      'is zero before connect, grows with silence, resets on traffic',
      () async {
        final sink = RecordingWebSocketSink();
        final channel = FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-json',
        );
        final client = TriageWebSocketClient(
          Uri.parse('ws://localhost/ws'),
          channelFactory: (_) => channel,
        );
        expect(client.millisSinceLastInbound, 0);

        await client.connect();
        final fresh = client.millisSinceLastInbound;
        expect(fresh, lessThan(60000));

        await Future<void>.delayed(const Duration(milliseconds: 120));
        final silent = client.millisSinceLastInbound;
        expect(silent, greaterThan(fresh));

        channel.addIncoming(jsonEncode({'type': 'session_started'}));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(client.millisSinceLastInbound, lessThan(silent));

        await client.disconnect();
        expect(client.millisSinceLastInbound, 0);
      },
    );
  });

  group('HTTP session history', () {
    Uint8List buildThs1Frame({
      String sessionId = 's1',
      bool exited = false,
      bool bracketedPaste = false,
      bool rawOutputTruncated = false,
      int rows = 24,
      int cols = 80,
      int outputSeq = 42,
      int bytesLogged = 2000,
      int rawOutputStart = 1000,
      int rawOutputEnd = 2000,
      List<int> prefix = const <int>[],
      List<int> raw = const <int>[],
    }) {
      final metaBytes = utf8.encode(
        jsonEncode({
          'session_id': sessionId,
          'size': {'rows': rows, 'cols': cols},
          'exited': exited,
          'output_seq': outputSeq,
          'bracketed_paste_enabled': bracketedPaste,
          'bytes_logged': bytesLogged,
          'raw_output_start': rawOutputStart,
          'raw_output_end': rawOutputEnd,
          'raw_output_truncated': rawOutputTruncated,
        }),
      );
      final out = BytesBuilder(copy: false);
      out.add(const <int>[0x54, 0x48, 0x53, 0x31]); // THS1
      final header = ByteData(12);
      header.setUint32(0, metaBytes.length, Endian.little);
      header.setUint32(4, prefix.length, Endian.little);
      header.setUint32(8, raw.length, Endian.little);
      out.add(header.buffer.asUint8List());
      out.add(metaBytes);
      out.add(prefix);
      out.add(raw);
      return out.toBytes();
    }

    test(
      'buildHistoryUri maps ws:// to cleartext http:// and wss:// to https://',
      () {
        final cleartextClient = TriageWebSocketClient(
          Uri.parse('ws://100.64.0.1:7777/ws'),
        );
        final cleartextUri = cleartextClient.buildHistoryUri(
          'feat:my session',
          windowBytes: 65536,
          afterByte: 1024,
          afterSeq: 7,
          beforeByte: 4096,
        );
        expect(cleartextUri.scheme, 'http');
        expect(cleartextUri.host, '100.64.0.1');
        expect(cleartextUri.port, 7777);
        expect(cleartextUri.path, '/api/sessions/feat:my%20session/history');
        expect(cleartextUri.queryParameters, {
          'window_bytes': '65536',
          'after_byte': '1024',
          'after_seq': '7',
          'before_byte': '4096',
        });

        final tlsClient = TriageWebSocketClient(
          Uri.parse('wss://triage.example.com:8443/ws'),
        );
        final tlsUri = tlsClient.buildHistoryUri('main', windowBytes: 131072);
        expect(tlsUri.scheme, 'https');
        expect(tlsUri.host, 'triage.example.com');
        expect(tlsUri.port, 8443);
        expect(tlsUri.path, '/api/sessions/main/history');
        expect(tlsUri.queryParameters, {'window_bytes': '131072'});
      },
    );

    test('decodeHistoryFrame decodes THS1 metadata and binary slices', () {
      final rawBytes = utf8.encode('hello world\n');
      final prefixBytes = utf8.encode('older prefix\n');

      final frame = buildThs1Frame(
        sessionId: 's1',
        exited: true,
        bracketedPaste: true,
        rawOutputTruncated: true,
        rows: 40,
        cols: 120,
        outputSeq: 99,
        bytesLogged: 5000,
        rawOutputStart: 1200,
        rawOutputEnd: 2400,
        prefix: prefixBytes,
        raw: rawBytes,
      );
      final decoded = decodeHistoryFrame(frame);
      expect(decoded['session_id'], 's1');
      expect(decoded['exited'], isTrue);
      expect(decoded['bracketed_paste_enabled'], isTrue);
      expect(decoded['raw_output_truncated'], isTrue);
      expect(decoded['size'], {'rows': 40, 'cols': 120});
      expect(decoded['output_seq'], 99);
      expect(decoded['bytes_logged'], 5000);
      expect(decoded['raw_output_start'], 1200);
      expect(decoded['raw_output_end'], 2400);
      expect(utf8.decode(decoded['raw_output'] as Uint8List), 'hello world\n');
      expect(
        utf8.decode(decoded['raw_output_prefix'] as Uint8List),
        'older prefix\n',
      );

      final oversizedHeader = Uint8List(16);
      oversizedHeader.setRange(0, 4, [0x54, 0x48, 0x53, 0x31]);
      final bd = ByteData.sublistView(oversizedHeader);
      bd.setUint32(4, 32, Endian.little);
      bd.setUint32(8, 0, Endian.little);
      bd.setUint32(12, maxHistoryFramePayloadBytes + 1, Endian.little);
      expect(
        () => decodeHistoryFrame(oversizedHeader),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'fetchSessionHistory sends auth headers and maps 401 to TriageAuthException',
      () async {
        Uri? capturedUri;
        Map<String, String>? capturedHeaders;
        var statusToReturn = 200;

        final sink = RecordingWebSocketSink();
        final channel = FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-json',
        );
        final client = TriageWebSocketClient(
          Uri.parse('ws://127.0.0.1:7777/ws'),
          channelFactory: (_) => channel,
          httpFetcher: (uri, {required headers}) async {
            capturedUri = uri;
            capturedHeaders = headers;
            return (
              statusCode: statusToReturn,
              body: buildThs1Frame(
                outputSeq: 12,
                bytesLogged: 100,
                rawOutputStart: 0,
                rawOutputEnd: 100,
                raw: utf8.encode('ok\n'),
              ),
              contentType: 'application/octet-stream',
            );
          },
        );
        await client.connect();
        final helloFuture = client.hello(
          clientId: 'client-1',
          token: 'tok-secret',
        );
        await Future<void>.delayed(Duration.zero);
        final helloReq =
            jsonDecode(sink.sent.single as String) as Map<String, dynamic>;
        channel.addIncoming(
          jsonEncode({
            'type': 'response',
            'id': helloReq['id'],
            'response': {'type': 'hello', 'accepted': true},
          }),
        );
        await helloFuture;

        final res = await client.fetchSessionHistory(
          sessionId: 'main',
          clientId: 'client-1',
          windowBytes: 65536,
          afterByte: 50,
          afterSeq: 10,
        );
        expect(
          capturedUri.toString(),
          'http://127.0.0.1:7777/api/sessions/main/history?window_bytes=65536&after_byte=50&after_seq=10',
        );
        expect(capturedHeaders?['Authorization'], 'Bearer tok-secret');
        expect(capturedHeaders?['X-Triage-Client-Id'], 'client-1');
        expect(utf8.decode(res['raw_output'] as Uint8List), 'ok\n');

        statusToReturn = 401;
        await expectLater(
          client.fetchSessionHistory(
            sessionId: 'main',
            clientId: 'client-1',
            windowBytes: 65536,
          ),
          throwsA(isA<TriageAuthException>()),
        );
      },
    );

    test(
      'fetchSessionHistory falls back to WebSocket attachSession on HTTP 404 or SPA text/html response',
      () async {
        var returnSpaHtml = false;
        var throwTransportError = false;
        final sink = RecordingWebSocketSink();
        final channel = FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-json',
        );
        final client = TriageWebSocketClient(
          Uri.parse('ws://127.0.0.1:7777/ws'),
          channelFactory: (_) => channel,
          httpFetcher: (uri, {required headers}) async {
            if (throwTransportError) {
              throw Exception('HTTP connection reset');
            }
            if (returnSpaHtml) {
              return (
                statusCode: 200,
                body: Uint8List.fromList(utf8.encode('<!doctype html>')),
                contentType: 'text/html; charset=utf-8',
              );
            }
            return (
              statusCode: 404,
              body: Uint8List(0),
              contentType: 'text/plain',
            );
          },
        );
        await client.connect();

        // 1. HTTP 404 (legacy server without /api/sessions/:id/history) falls back to attachSession.
        final fallbackFuture1 = client.fetchSessionHistory(
          sessionId: 'main',
          clientId: 'client-1',
          windowBytes: 65536,
        );
        await Future<void>.delayed(Duration.zero);
        final attachReq1 =
            jsonDecode(sink.sent.last as String) as Map<String, dynamic>;
        expect(attachReq1['type'], 'attach_session');
        expect(attachReq1['request']['history_bytes'], 65536);
        channel.addIncoming(
          jsonEncode({
            'type': 'response',
            'id': attachReq1['id'],
            'result': {
              'type': 'attach_session',
              'response': {
                'snapshot': {
                  'output_seq': 7,
                  'bytes_logged': 12,
                  'raw_output': base64Encode(utf8.encode('ws-fallback\n')),
                  'raw_output_start': 0,
                  'exited': false,
                },
              },
            },
          }),
        );
        final snap1 = await fallbackFuture1;
        expect(snap1['output_seq'], 7);

        // 2. SPA text/html fallback response also falls back to attachSession.
        returnSpaHtml = true;
        final fallbackFuture2 = client.fetchSessionHistory(
          sessionId: 'main',
          clientId: 'client-1',
          windowBytes: 32768,
        );
        await Future<void>.delayed(Duration.zero);
        final attachReq2 =
            jsonDecode(sink.sent.last as String) as Map<String, dynamic>;
        expect(attachReq2['type'], 'attach_session');
        expect(attachReq2['request']['history_bytes'], 32768);
        channel.addIncoming(
          jsonEncode({
            'type': 'response',
            'id': attachReq2['id'],
            'result': {
              'type': 'attach_session',
              'response': {
                'snapshot': {
                  'output_seq': 8,
                  'bytes_logged': 15,
                  'raw_output': base64Encode(utf8.encode('ws-fallback-2\n')),
                  'raw_output_start': 0,
                  'exited': false,
                },
              },
            },
          }),
        );
        final snap2 = await fallbackFuture2;
        expect(snap2['output_seq'], 8);

        // 3. Transport exception on HTTP fetch also falls back to attachSession.
        throwTransportError = true;
        final fallbackFuture3 = client.fetchSessionHistory(
          sessionId: 'main',
          clientId: 'client-1',
          windowBytes: 16384,
        );
        await Future<void>.delayed(Duration.zero);
        final attachReq3 =
            jsonDecode(sink.sent.last as String) as Map<String, dynamic>;
        expect(attachReq3['type'], 'attach_session');
        expect(attachReq3['request']['history_bytes'], 16384);
        channel.addIncoming(
          jsonEncode({
            'type': 'response',
            'id': attachReq3['id'],
            'result': {
              'type': 'attach_session',
              'response': {
                'snapshot': {
                  'output_seq': 9,
                  'bytes_logged': 18,
                  'raw_output': base64Encode(utf8.encode('ws-fallback-3\n')),
                  'raw_output_start': 0,
                  'exited': false,
                },
              },
            },
          }),
        );
        final snap3 = await fallbackFuture3;
        expect(snap3['output_seq'], 9);
      },
    );
  });

  group('rawOutputViewportFromSnapshot mode-only prefix', () {
    test('homes cursor with ESC[H when prefix has no newlines', () {
      final modePrefix = utf8.encode(
        '\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h',
      );
      final snapshot = <String, dynamic>{
        'raw_output_prefix': modePrefix,
        'raw_output': utf8.encode('frame'),
        'styled_rows': [
          {
            'spans': [
              {
                'text': 'row0',
                'fg': {'type': 'default'},
                'bg': {'type': 'default'},
                'bold': false,
                'dim': false,
                'italic': false,
                'underline': false,
                'inverse': false,
              },
            ],
          },
          {
            'spans': [
              {
                'text': 'row1',
                'fg': {'type': 'default'},
                'bg': {'type': 'default'},
                'bold': false,
                'dim': false,
                'italic': false,
                'underline': false,
                'inverse': false,
              },
            ],
          },
        ],
        'cursor': {'row': 1, 'col': 4, 'visible': true},
      };
      final viewport = utf8.decode(rawOutputViewportFromSnapshot(snapshot));
      expect(
        viewport,
        startsWith(
          '\x1b[?7l\x1b[H\x1b[0m\x1b[0mrow0\x1b[0m\r\n\x1b[0m\x1b[0mrow1',
        ),
      );
    });
  });

  group('Terminal Cell Sync Protocol (FlatBuffers & JSON)', () {
    const trimmedOffsetCases = <int, int>{
      0x100000001: 0x100000001,
      0x3FFFFFFFFFFFF: 0x3FFFFFFFFFFFF,
      0x4000000000000: 0x4000000000000,
      0x4000000000001: 0x4000000000000,
      0x1FFFFFFFFFFFFF: 0x4000000000000,
    };

    test('frame parser preserves wide trimmed offsets and clamps at 2^50', () {
      for (final entry in trimmedOffsetCases.entries) {
        final frame = TerminalSyncFrameData.fromMap(<String, dynamic>{
          'trimmed_top_rows': entry.key,
        });
        expect(
          frame.trimmedTopRows,
          entry.value,
          reason: 'frame trimmed_top_rows=${entry.key}',
        );
      }
    });

    test('page parser preserves wide trimmed offsets and clamps at 2^50', () {
      for (final entry in trimmedOffsetCases.entries) {
        for (final wrapped in <bool>[false, true]) {
          final body = <String, dynamic>{'trimmed_top_rows': entry.key};
          final page = TerminalRowsPageData.fromMap(
            wrapped ? <String, dynamic>{'response': body} : body,
          );
          expect(
            page.trimmedTopRows,
            entry.value,
            reason: 'page trimmed_top_rows=${entry.key}, wrapped=$wrapped',
          );
        }
      }
    });

    test(
      'syncTerminalSession, fetchTerminalRows, ackTerminalSync, and TerminalSyncEvent round-trip over binary FlatBuffers',
      () async {
        final sink = RecordingWebSocketSink();
        final channel = FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-flatbuffers',
        );
        final client = TriageWebSocketClient(
          Uri.parse('ws://localhost/ws'),
          channelFactory: (_) => channel,
        );
        await client.connect();

        // 1. syncTerminalSession request + response
        final syncFuture = client.syncTerminalSession(
          sessionId: 'sess-1',
          clientId: 'client-1',
          mode: 'Observer',
          cols: 120,
          rows: 40,
          resizePty: true,
          restoreIfExited: true,
          subscribe: true,
          knownFrameSeq: 7,
        );

        expect(sink.sent, hasLength(1));
        final syncReqMsg = fbs.ClientMessage(sink.sent.last as List<int>);
        expect(syncReqMsg.id, equals('req-0'));
        expect(
          syncReqMsg.payloadType,
          equals(fbs.ClientRequestPayloadTypeId.SyncTerminalRequestTable),
        );
        final syncReq = syncReqMsg.payload as fbs.SyncTerminalRequestTable;
        expect(syncReq.sessionId, equals('sess-1'));
        expect(syncReq.clientId, equals('client-1'));
        expect(syncReq.mode, equals(fbs.AttachMode.Observer));
        expect(syncReq.size!.cols, equals(120));
        expect(syncReq.size!.rows, equals(40));
        expect(syncReq.resizePty, isTrue);
        expect(syncReq.restoreIfExited, isTrue);
        expect(syncReq.subscribe, isTrue);
        expect(syncReq.knownFrameSeq, equals(7));

        final viewportTcg1 = encodeTcg1PlainTextRows(const <String>[
          'prompt> hello',
          'second row',
        ], cols: 120);
        final pushedTcg1 = encodeTcg1PlainTextRows(const <String>[
          'scrolled line 0',
        ], cols: 120);
        final syncRespBytes = fbs.ServerMessageObjectBuilder(
          payloadType: fbs.ServerMessagePayloadTypeId.ResponsePayload,
          payload: fbs.ResponsePayloadObjectBuilder(
            id: 'req-0',
            resultType: fbs.ServerResultPayloadTypeId.SyncTerminalResult,
            result: fbs.SyncTerminalResultObjectBuilder(
              subscriptionId: 'sub-sess-1',
              snapshot: fbs.SessionSnapshotObjectBuilder(
                outputSeq: 12,
                bytesLogged: 512,
                size: fbs.SessionSizeObjectBuilder(
                  rows: 40,
                  cols: 120,
                  pixelWidth: 1200,
                  pixelHeight: 800,
                  dpi: 96,
                ),
                visibleRows: const <String>[],
                styledRowsStart: 0,
                styledRows: const <fbs.StyledRowObjectBuilder>[],
                bracketedPasteEnabled: true,
                exited: false,
              ),
              lease: fbs.InputLeaseStateObjectBuilder(generation: 3),
              frame: fbs.TerminalSyncFrameObjectBuilder(
                frameSeq: 8,
                rows: 40,
                cols: 120,
                totalScrollbackRows: 250,
                trimmedTopRows: 10,
                eraseScrollbackGen: 2,
                cursorX: 13,
                cursorY: 0,
                cursorStyle: 2,
                modeFlags:
                    kModeCursorVisible | kModeAutoWrap | kModeFullViewport,
                mouseMode: 2,
                mouseReportMode: 2,
                kittyKeyboardFlags: 1,
                title: 'zsh',
                viewportCompression: kCellCompressionNone,
                viewportPayload: viewportTcg1,
                pushedScrollbackStartRow: 249,
                pushedScrollbackRowCount: 1,
                pushedScrollbackCompression: kCellCompressionNone,
                pushedScrollbackPayload: pushedTcg1,
              ),
            ),
          ),
        ).toBytes();
        channel.addIncoming(syncRespBytes);

        final syncRes = await syncFuture;
        expect(syncRes['result'], equals('sync_terminal'));
        final syncInner = syncRes['response'] as Map<String, dynamic>;
        expect(syncInner['subscription_id'], equals('sub-sess-1'));
        final parsedFrame = TerminalSyncFrameData.fromMap(
          syncInner['frame'] as Map<String, dynamic>,
        );
        expect(parsedFrame.frameSeq, equals(8));
        expect(parsedFrame.cols, equals(120));
        expect(parsedFrame.rows, equals(40));
        expect(parsedFrame.totalScrollbackRows, equals(250));
        expect(parsedFrame.trimmedTopRows, equals(10));
        expect(parsedFrame.eraseScrollbackGen, equals(2));
        expect(parsedFrame.mouseMode, equals(2));
        expect(parsedFrame.mouseReportMode, equals(2));
        expect(parsedFrame.kittyKeyboardFlags, equals(1));
        expect(parsedFrame.title, equals('zsh'));
        expect(parsedFrame.fullViewport, isTrue);
        final decodedVp = decodeTcg1Batch(
          parsedFrame.viewportCompression,
          parsedFrame.viewportPayload,
        );
        expect(decodedVp, hasLength(2));

        // 2. fetchTerminalRows request + response
        final fetchFuture = client.fetchTerminalRows(
          sessionId: 'sess-1',
          startRow: 128,
          rowCount: 64,
        );
        expect(sink.sent, hasLength(2));
        final fetchReqMsg = fbs.ClientMessage(sink.sent.last as List<int>);
        expect(fetchReqMsg.id, equals('req-1'));
        expect(
          fetchReqMsg.payloadType,
          equals(fbs.ClientRequestPayloadTypeId.FetchTerminalRowsRequestTable),
        );
        final fetchReq =
            fetchReqMsg.payload as fbs.FetchTerminalRowsRequestTable;
        expect(fetchReq.sessionId, equals('sess-1'));
        expect(fetchReq.startRow, equals(128));
        expect(fetchReq.rowCount, equals(64));

        final pageTcg1 = encodeTcg1PlainTextRows(const <String>[
          'archived row 128',
          'archived row 129',
        ], cols: 120);
        channel.addIncoming(
          fbs.ServerMessageObjectBuilder(
            payloadType: fbs.ServerMessagePayloadTypeId.ResponsePayload,
            payload: fbs.ResponsePayloadObjectBuilder(
              id: 'req-1',
              resultType: fbs.ServerResultPayloadTypeId.FetchTerminalRowsResult,
              result: fbs.FetchTerminalRowsResultObjectBuilder(
                sessionId: 'sess-1',
                startRow: 128,
                rowCount: 2,
                totalScrollbackRows: 250,
                trimmedTopRows: 10,
                eraseScrollbackGen: 2,
                compression: kCellCompressionNone,
                payload: pageTcg1,
              ),
            ),
          ).toBytes(),
        );
        final fetchRes = await fetchFuture;
        final pageData = TerminalRowsPageData.fromMap(fetchRes);
        expect(pageData.sessionId, equals('sess-1'));
        expect(pageData.startRow, equals(128));
        expect(pageData.rowCount, equals(2));
        expect(
          decodeTcg1Batch(pageData.compression, pageData.payload),
          hasLength(2),
        );

        // 3. ackTerminalSync is fire-and-forget with null message id
        client.ackTerminalSync(subscriptionId: 'sub-sess-1', frameSeq: 8);
        expect(sink.sent, hasLength(3));
        final ackMsg = fbs.ClientMessage(sink.sent.last as List<int>);
        expect(ackMsg.id, isNull);
        expect(
          ackMsg.payloadType,
          equals(fbs.ClientRequestPayloadTypeId.AckTerminalSyncRequestTable),
        );
        final ackReq = ackMsg.payload as fbs.AckTerminalSyncRequestTable;
        expect(ackReq.subscriptionId, equals('sub-sess-1'));
        expect(ackReq.frameSeq, equals(8));

        // 4. TerminalSyncEvent server push
        final eventFuture = client.events.first;
        channel.addIncoming(
          fbs.ServerMessageObjectBuilder(
            payloadType: fbs.ServerMessagePayloadTypeId.EventPayload,
            payload: fbs.EventPayloadObjectBuilder(
              subscriptionId: 'sub-sess-1',
              eventSeq: 99,
              eventType: fbs.SessionEventPayloadTypeId.TerminalSyncEvent,
              event: fbs.TerminalSyncEventObjectBuilder(
                sessionId: 'sess-1',
                frame: fbs.TerminalSyncFrameObjectBuilder(
                  frameSeq: 9,
                  rows: 40,
                  cols: 120,
                  totalScrollbackRows: 250,
                  trimmedTopRows: 10,
                  eraseScrollbackGen: 2,
                  cursorX: 0,
                  cursorY: 1,
                  cursorStyle: 0,
                  modeFlags: kModeCursorVisible,
                  mouseMode: 0,
                  mouseReportMode: 0,
                  kittyKeyboardFlags: 0,
                  viewportCompression: kCellCompressionNone,
                  viewportPayload: encodeTcg1PlainTextRows(
                    const <String>['delta update'],
                    cols: 120,
                    startRowIndex: 1,
                  ),
                  pushedScrollbackStartRow: 0,
                  pushedScrollbackRowCount: 0,
                  pushedScrollbackCompression: kCellCompressionNone,
                  pushedScrollbackPayload: Uint8List(0),
                ),
              ),
            ),
          ).toBytes(),
        );
        final pushedEvt = await eventFuture;
        expect(pushedEvt['type'], equals('event'));
        expect(pushedEvt['subscription_id'], equals('sub-sess-1'));
        final syncEvt =
            ((pushedEvt['envelope'] as Map<String, dynamic>)['event']
                    as Map<String, dynamic>)['TerminalSync']
                as Map<String, dynamic>;
        expect(syncEvt['session_id'], equals('sess-1'));
        final deltaFrame = TerminalSyncFrameData.fromMap(
          syncEvt['frame'] as Map<String, dynamic>,
        );
        expect(deltaFrame.frameSeq, equals(9));
        expect(deltaFrame.fullViewport, isFalse);

        await client.disconnect();
      },
    );

    test(
      'syncTerminalSession, fetchTerminalRows, and ackTerminalSync round-trip over JSON with Base64 TCG1 payloads',
      () async {
        final sink = RecordingWebSocketSink();
        final channel = FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-json',
        );
        final client = TriageWebSocketClient(
          Uri.parse('ws://localhost/ws'),
          channelFactory: (_) => channel,
        );
        await client.connect();

        final syncFuture = client.syncTerminalSession(
          sessionId: 'sess-json',
          clientId: 'c-json',
          mode: 'InteractiveController',
          cols: 80,
          rows: 24,
        );
        final reqJson =
            jsonDecode(sink.sent.last as String) as Map<String, dynamic>;
        expect(reqJson['type'], equals('sync_terminal'));
        final tcg1 = encodeTcg1PlainTextRows(const <String>[
          'json row',
        ], cols: 80);
        channel.addIncoming(
          jsonEncode({
            'type': 'response',
            'id': reqJson['id'],
            'result': {
              'type': 'sync_terminal',
              'response': {
                'subscription_id': 'sub-json',
                'snapshot': {'exited': false},
                'lease': {'generation': 1},
                'frame': {
                  'frame_seq': 1,
                  'rows': 24,
                  'cols': 80,
                  'mode_flags': kModeFullViewport | kModeCursorVisible,
                  'viewport_compression': kCellCompressionNone,
                  'viewport_payload': base64Encode(tcg1),
                },
              },
            },
          }),
        );
        final syncRes = await syncFuture;
        final frame = TerminalSyncFrameData.fromMap(
          (syncRes['response'] as Map<String, dynamic>)['frame']
              as Map<String, dynamic>,
        );
        expect(
          decodeTcg1Batch(frame.viewportCompression, frame.viewportPayload),
          hasLength(1),
        );

        client.ackTerminalSync(subscriptionId: 'sub-json', frameSeq: 1);
        final ackJson =
            jsonDecode(sink.sent.last as String) as Map<String, dynamic>;
        expect(ackJson.containsKey('id'), isFalse);
        expect(ackJson['type'], equals('ack_terminal_sync'));
        expect(ackJson['subscription_id'], equals('sub-json'));
        expect(ackJson['frame_seq'], equals(1));

        await client.disconnect();
      },
    );

    test(
      'older daemon rejecting sync_terminal or fetch_terminal_rows surfaces TriageUnsupportedProtocolException',
      () async {
        final sink = RecordingWebSocketSink();
        final channel = FakeWebSocketChannel(
          sink: sink,
          protocol: 'triage-json',
        );
        final client = TriageWebSocketClient(
          Uri.parse('ws://localhost/ws'),
          channelFactory: (_) => channel,
        );
        await client.connect();

        final syncFuture = client.syncTerminalSession(
          sessionId: 'main',
          clientId: 'c1',
        );
        final req1 =
            jsonDecode(sink.sent.last as String) as Map<String, dynamic>;
        channel.addIncoming(
          jsonEncode({
            'type': 'error',
            'id': req1['id'],
            'error': {
              'code': 'invalid_request',
              'message':
                  'unknown variant `sync_terminal`, expected one of `hello`, `attach_session`',
            },
          }),
        );
        await expectLater(
          syncFuture,
          throwsA(isA<TriageUnsupportedProtocolException>()),
        );

        final fetchFuture = client.fetchTerminalRows(
          sessionId: 'main',
          startRow: 0,
          rowCount: 128,
        );
        final req2 =
            jsonDecode(sink.sent.last as String) as Map<String, dynamic>;
        channel.addIncoming(
          jsonEncode({
            'type': 'error',
            'id': req2['id'],
            'error': {
              'code': 'unsupported_payload',
              'message': 'request payload is not recognized or supported',
            },
          }),
        );
        await expectLater(
          fetchFuture,
          throwsA(isA<TriageUnsupportedProtocolException>()),
        );

        // Older daemon rejecting binary FlatBuffers frame with id == null
        // must immediately fail in-flight sync_terminal instead of hanging 30s.
        final binaryNullIdFuture = client.syncTerminalSession(
          sessionId: 'main',
          clientId: 'c1',
        );
        channel.addIncoming(
          jsonEncode({
            'type': 'error',
            'id': null,
            'error': {
              'code': 'invalid_flatbuffer',
              'message': 'unknown request payload union type',
            },
          }),
        );
        await expectLater(
          binaryNullIdFuture,
          throwsA(isA<TriageUnsupportedProtocolException>()),
        );

        await client.disconnect();
      },
    );
  });
}
