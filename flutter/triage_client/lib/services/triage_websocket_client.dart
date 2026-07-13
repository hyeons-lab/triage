import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:triage_client/generated/triage_triage.generated_generated.dart'
    as fbs;

typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri);

/// Thrown when the daemon refuses a request because this client is not paired:
/// the bearer token was revoked or expired, or it belongs to a different client
/// id (a reinstall wipes the keystore-backed client id, so the stored token no
/// longer matches the id we send). Retrying is futile — the same token fails
/// identically forever — so callers must re-pair rather than reconnect.
///
/// A distinct type rather than a message substring, so that routing to the
/// pairing screen does not depend on how the daemon words the error.
class TriageAuthException implements Exception {
  TriageAuthException(this.message);

  final String message;

  // Callers display this straight to the user (stripping only an `Exception: `
  // prefix), so a `TriageAuthException: ` prefix here would leak into the UI.
  @override
  String toString() => message;
}

/// The daemon's error code for a request refused because the connection has not
/// paired (`TransportError::Unauthorized`, whose message is the same string).
const _unauthorizedCode = 'unauthorized';

bool _isUnauthorized(String value) =>
    value.trim().toLowerCase() == _unauthorizedCode;

class TriageWebSocketClient {
  TriageWebSocketClient(this.uri, {WebSocketChannelFactory? channelFactory})
    : _channelFactory =
          channelFactory ??
          ((uri) => WebSocketChannel.connect(uri, protocols: ['triage-json']));

  final Uri uri;
  final WebSocketChannelFactory _channelFactory;
  WebSocketChannel? _channel;
  // The current channel's listener, kept so it can be cancelled when the channel
  // is retired. A half-open socket never ends its own stream, so without this
  // the subscription — and the channel and socket it holds — would outlive every
  // reconnect.
  StreamSubscription<dynamic>? _subscription;

  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final Map<String, String> _pendingRequestTypes = {};
  final Map<String, Timer> _requestTimers = {};
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _eventController.stream;

  int _requestIdCounter = 0;

  bool get isConnected => _channel != null;

  bool get isFlatBuffersNegotiated =>
      _channel?.protocol == 'triage-flatbuffers';

  /// How long [connect] waits for the WebSocket handshake before failing.
  ///
  /// `WebSocketChannel.ready` has no deadline of its own, so a half-open socket
  /// — routine on a phone whose network changed while the app was backgrounded
  /// — leaves it pending for as long as the OS keeps retransmitting. Callers
  /// treat a connect that is still in flight as "one is already running, don't
  /// start another", so a `ready` that never settles wedges reconnection
  /// entirely. Bounding it guarantees every attempt terminates and can retry.
  static const Duration connectTimeout = Duration(seconds: 10);

  /// How long a request waits for its response before failing. Note this does
  /// not close the socket: a request can time out on a connection that stays
  /// open, so callers must not treat "still connected" as "still working".
  static const Duration requestTimeout = Duration(seconds: 10);

  /// How long [disconnect] waits for the close handshake before abandoning the
  /// socket.
  static const Duration closeTimeout = Duration(seconds: 2);

  Future<void> connect() async {
    if (_channel != null) return;

    WebSocketChannel? channel;
    StreamSubscription<dynamic>? subscription;
    // Set when the channel dies before this call takes ownership of it — the
    // handlers below can't report that through `_channel`, because it isn't
    // ours yet.
    var diedBeforeOwned = false;
    try {
      final pending = _channelFactory(uri);
      channel = pending;
      subscription = pending.stream.listen(
        (message) {
          _handleIncomingMessage(message);
        },
        // Only the channel this client currently owns may tear it down. A
        // channel abandoned by a timed-out connect dies later, on its own
        // schedule — by then it may not be the current one, and disowning a
        // healthy successor here would drop a live connection. Same guard as
        // `writeInput`'s error path.
        onError: (error) {
          if (!identical(_channel, pending)) {
            diedBeforeOwned = true;
            return;
          }
          _cleanupPendingRequests();
          _channel = null;
          _subscription = null;
          _eventController.add({
            'type': 'connection_closed',
            'error': error.toString(),
          });
        },
        onDone: () {
          if (!identical(_channel, pending)) {
            diedBeforeOwned = true;
            return;
          }
          _cleanupPendingRequests();
          _channel = null;
          _subscription = null;
          _eventController.add({'type': 'connection_closed'});
        },
      );
      await pending.ready.timeout(connectTimeout);
      // A server that accepts the upgrade and closes immediately delivers
      // `onDone` in the gap between `ready` completing and the line below. Left
      // unchecked we would store a corpse and report it as connected — every
      // later write would vanish into it — so fail the connect instead.
      if (diedBeforeOwned) {
        throw StateError('WebSocket closed during the handshake');
      }
      _channel = pending;
      _subscription = subscription;
    } catch (error) {
      // This attempt never took ownership (`_channel` is assigned only on
      // success), so the same rule as the handlers above applies: if another
      // connect has since installed a live channel, leave it and its in-flight
      // requests alone. Only clean up when nothing has taken over.
      if (_channel == null) {
        _cleanupPendingRequests();
      }
      // A timeout does not cancel the handshake it gave up on, so retire this
      // channel for good: stop listening to it and close the socket. Left
      // subscribed, it would still be delivering frames — and running the
      // handlers above — long after this attempt was abandoned.
      unawaited(subscription?.cancel().catchError((_) {}));
      unawaited(channel?.sink.close().catchError((_) {}));
      rethrow;
    }
  }

  void _handleIncomingMessage(dynamic messageData) {
    try {
      final Map<String, dynamic> message;
      final binaryMessage = _asBinaryMessage(messageData);
      if (binaryMessage != null) {
        message = _parseFlatBuffers(binaryMessage);
      } else {
        message = jsonDecode(messageData.toString()) as Map<String, dynamic>;
      }
      final type = message['type'] as String?;

      if (type == 'response') {
        final id = message['id']?.toString();
        final result = message['result'] as Map<String, dynamic>?;
        if (id != null && _pendingRequests.containsKey(id)) {
          _requestTimers.remove(id)?.cancel();
          _pendingRequestTypes.remove(id);
          _pendingRequests.remove(id)!.complete(result ?? {});
        }
      } else if (type == 'error') {
        final id = message['id']?.toString();
        final error = message['error'] as Map<String, dynamic>?;
        if (id != null && _pendingRequests.containsKey(id)) {
          _requestTimers.remove(id)?.cancel();
          _pendingRequestTypes.remove(id);
          final code = error?['code']?.toString();
          final errorMessage =
              error?['message']?.toString() ?? code ?? 'Unknown error';
          // Classify pairing failures here, at the one place that sees the
          // daemon's error code, so callers route to pairing on a type rather
          // than sniffing message text. Fall back to the message only when
          // there is no code at all.
          final failure = _isUnauthorized(code ?? errorMessage)
              ? TriageAuthException(errorMessage)
              : Exception(errorMessage);
          _pendingRequests.remove(id)!.completeError(failure);
        }
      } else if (type == 'event') {
        _eventController.add(message);
      } else if (type == 'subscription_closed') {
        _eventController.add(message);
      } else if (type == 'session_snippet_updated') {
        // Connection-wide push (not tied to a request or subscription); forward
        // to the app so it can update the session's rail snippet live.
        _eventController.add(message);
      } else if (type == 'session_context_updated') {
        // Connection-wide push: a session's working directory / git context
        // changed. Forward so the rail's repo·branch·worktree (or cwd) line
        // stays fresh without re-attaching.
        _eventController.add(message);
      }
    } catch (error) {
      debugPrint(
        'Failed to parse WebSocket message '
        '(${messageData.runtimeType}): $error',
      );
      _eventController.add({
        'type': 'protocol_error',
        'error': error.toString(),
      });
    }
  }

  Uint8List? _asBinaryMessage(dynamic messageData) {
    if (messageData is Uint8List) {
      return messageData;
    }
    if (messageData is ByteData) {
      return messageData.buffer.asUint8List(
        messageData.offsetInBytes,
        messageData.lengthInBytes,
      );
    }
    if (messageData is ByteBuffer) {
      return messageData.asUint8List();
    }
    if (messageData is List<int>) {
      return Uint8List.fromList(messageData);
    }
    return null;
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
    _pendingRequestTypes[id] = type;
    _requestTimers[id] = Timer(requestTimeout, () {
      if (_pendingRequests.remove(id) == completer && !completer.isCompleted) {
        final requestType = _pendingRequestTypes.remove(id) ?? type;
        completer.completeError(
          Exception('WebSocket request timed out: $requestType ($id)'),
        );
      }
      _requestTimers.remove(id);
    });

    try {
      if (isFlatBuffersNegotiated) {
        final List<int> bytes = _serializeFlatBuffersRequest(id, type, extra);
        _channel!.sink.add(bytes);
      } else {
        final payload = <String, dynamic>{'id': id, 'type': type};
        if (extra != null) {
          payload.addAll(extra);
        }
        _channel!.sink.add(jsonEncode(payload));
      }
    } catch (e) {
      _pendingRequests.remove(id);
      _pendingRequestTypes.remove(id);
      _requestTimers.remove(id)?.cancel();
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

  Future<Map<String, dynamic>> pairingChallenge({
    required String clientId,
  }) async {
    return _send('pairing_challenge', {'client_id': clientId});
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

  /// Returns the current snippet + detail summary for every session, keyed by
  /// session id. Sessions without a generated snippet carry `null` fields. Used
  /// to seed the side rail on connect; live updates arrive via
  /// `session_snippet_updated` events.
  Future<Map<String, ({String? snippet, String? detail})>>
  listSessionSnippets() async {
    final response = await _send('list_session_snippets');
    final entries = response['entries'] as List<dynamic>?;
    final result = <String, ({String? snippet, String? detail})>{};
    for (final entry in entries ?? const []) {
      final map = entry as Map<String, dynamic>;
      final sessionId = map['session_id'] as String?;
      if (sessionId != null) {
        result[sessionId] = (
          snippet: map['snippet'] as String?,
          detail: map['detail'] as String?,
        );
      }
    }
    return result;
  }

  /// Returns each session's git context (repository/worktree/branch), keyed by
  /// session id, so the side rail can show a meaningful title for every session
  /// on connect without subscribing to its event stream. The bulk response
  /// carries only the git fields (no live cwd — that arrives via
  /// `session_context_updated`). Best-effort: an older daemon that predates this
  /// request will error, which the caller swallows.
  Future<
    Map<
      String,
      ({String? repositoryRoot, String? worktreeRoot, String? branch})
    >
  >
  listSessionContexts() async {
    final response = await _send('list_session_contexts');
    final entries = response['entries'] as List<dynamic>?;
    final result =
        <
          String,
          ({String? repositoryRoot, String? worktreeRoot, String? branch})
        >{};
    for (final entry in entries ?? const []) {
      final map = entry as Map<String, dynamic>;
      final sessionId = map['session_id'] as String?;
      if (sessionId != null) {
        result[sessionId] = (
          repositoryRoot: map['repository_root'] as String?,
          worktreeRoot: map['worktree_root'] as String?,
          branch: map['branch'] as String?,
        );
      }
    }
    return result;
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
    final channel = _channel;
    if (channel == null) {
      throw StateError('WebSocket is not connected');
    }
    try {
      final isFb = channel.protocol == 'triage-flatbuffers';
      if (isFb) {
        final bytesPayload = fbs.WriteInputRequestTableObjectBuilder(
          sessionId: sessionId,
          clientId: clientId,
          bytes: bytes,
        );
        final msg = fbs.ClientMessageObjectBuilder(
          id: 'req-${_requestIdCounter++}',
          payloadType: fbs.ClientRequestPayloadTypeId.WriteInputRequestTable,
          payload: bytesPayload,
        );
        channel.sink.add(msg.toBytes());
      } else {
        final payload = <String, dynamic>{
          'type': 'write_input',
          'request': {
            'session_id': sessionId,
            'client_id': clientId,
            'bytes': bytes,
          },
        };
        channel.sink.add(jsonEncode(payload));
      }
    } catch (error, stackTrace) {
      _cleanupPendingRequests();
      if (identical(_channel, channel)) {
        _channel = null;
        unawaited(_subscription?.cancel().catchError((_) {}));
        _subscription = null;
      }
      _eventController.add({
        'type': 'connection_closed',
        'error': error.toString(),
      });
      Error.throwWithStackTrace(error, stackTrace);
    }
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

  Future<Map<String, dynamic>> restoreSession({
    required String sessionId,
    required int cols,
    required int rows,
  }) async {
    return _send('restore_session', {
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

  Future<Map<String, dynamic>> snapshotSession({
    required String sessionId,
  }) async {
    return _send('snapshot_session', {'session_id': sessionId});
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
    _pendingRequestTypes.clear();
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('WebSocket connection closed'));
      }
    }
    _pendingRequests.clear();
  }

  Future<void> disconnect() async {
    final channel = _channel;
    final subscription = _subscription;
    _channel = null;
    _subscription = null;
    // Stop listening first: on a half-open socket the close below never
    // completes, so the stream would never end on its own and the subscription
    // would keep this channel — and its socket — alive past every reconnect.
    unawaited(subscription?.cancel().catchError((_) {}));
    if (channel != null) {
      // Closing is a handshake, and a half-open socket never answers it. Bound
      // the wait: callers disconnect in order to reconnect, so a dead socket
      // must never be able to hold up the connection replacing it.
      try {
        await channel.sink.close().timeout(closeTimeout);
      } catch (_) {}
    }
    _cleanupPendingRequests();
  }

  Map<String, dynamic> _parseFlatBuffers(List<int> bytes) {
    final serverMsg = fbs.ServerMessage(bytes);
    final payloadType = serverMsg.payloadType;
    final payload = serverMsg.payload;

    if (payloadType == fbs.ServerMessagePayloadTypeId.ResponsePayload) {
      final resp = payload as fbs.ResponsePayload;
      return {
        'type': 'response',
        'id': resp.id,
        'result': _parseServerResult(resp.resultType, resp.result),
      };
    } else if (payloadType == fbs.ServerMessagePayloadTypeId.ErrorPayload) {
      final err = payload as fbs.ErrorPayload;
      return {
        'type': 'error',
        'id': err.id,
        'error': {'code': err.code, 'message': err.message},
      };
    } else if (payloadType == fbs.ServerMessagePayloadTypeId.EventPayload) {
      final evt = payload as fbs.EventPayload;
      return {
        'type': 'event',
        'subscription_id': evt.subscriptionId,
        'event_seq': evt.eventSeq,
        'envelope': {
          'event_seq': evt.eventSeq,
          'event': _parseSessionEvent(evt.eventType, evt.event),
        },
      };
    } else if (payloadType ==
        fbs.ServerMessagePayloadTypeId.SubscriptionClosedPayload) {
      final closed = payload as fbs.SubscriptionClosedPayload;
      return {
        'type': 'subscription_closed',
        'subscription_id': closed.subscriptionId,
      };
    } else if (payloadType ==
        fbs.ServerMessagePayloadTypeId.SessionSnippetUpdatedPayload) {
      final updated = payload as fbs.SessionSnippetUpdatedPayload;
      return {
        'type': 'session_snippet_updated',
        'session_id': updated.sessionId,
        'snippet': updated.snippet,
        'detail': updated.detail,
        'output_seq': updated.outputSeq,
      };
    } else if (payloadType ==
        fbs.ServerMessagePayloadTypeId.SessionContextUpdatedPayload) {
      final updated = payload as fbs.SessionContextUpdatedPayload;
      return {
        'type': 'session_context_updated',
        'session_id': updated.sessionId,
        'current_working_directory': updated.currentWorkingDirectory,
        'repository_root': updated.repositoryRoot,
        'worktree_root': updated.worktreeRoot,
        'branch': updated.branch,
      };
    }
    return {};
  }

  Map<String, dynamic> _parseServerResult(
    fbs.ServerResultPayloadTypeId? type,
    dynamic result,
  ) {
    if (result == null || type == null) return {};
    switch (type.value) {
      case 1: // UnitResult
        return {'result': 'unit'};
      case 2: // HelloResult
        final hello = result as fbs.HelloResult;
        return {
          'result': 'hello',
          'protocol_version': hello.protocolVersion,
          'authenticated': hello.authenticated,
        };
      case 3: // PairedResult
        final paired = result as fbs.PairedResult;
        return {'result': 'paired', 'token': paired.token};
      case 12: // PairingChallengeResult
        final challenge = result as fbs.PairingChallengeResult;
        return {
          'result': 'pairing_challenge',
          'device_code': challenge.deviceCode,
          'expires_at': challenge.expiresAt,
        };
      case 4: // SessionIdsResult
        final sids = result as fbs.SessionIdsResult;
        return {'result': 'session_ids', 'session_ids': sids.sessionIds ?? []};
      case 5: // SessionIdResult
        final sid = result as fbs.SessionIdResult;
        return {'result': 'session_id', 'session_id': sid.sessionId};
      case 6: // AttachSessionResult
        final attach = result as fbs.AttachSessionResult;
        return {
          'result': 'attach_session',
          'response': _parseAttachSessionResponse(attach.response),
        };
      case 7: // SubscribedResult
        final sub = result as fbs.SubscribedResult;
        return {'result': 'subscribed', 'subscription_id': sub.subscriptionId};
      case 8: // LeaseChangeResult
        final lease = result as fbs.LeaseChangeResult;
        return {
          'result': 'lease_change',
          'change': _parseLeaseChange(lease.change),
        };
      case 9: // SessionSnapshotResult
        final snap = result as fbs.SessionSnapshotResult;
        return {
          'result': 'session_snapshot',
          'snapshot': _parseSessionSnapshot(snap.snapshot),
        };
      case 10: // StyledRowsResult
        final styled = result as fbs.StyledRowsResult;
        return {
          'result': 'styled_rows',
          'response': _parseStyledRowsResponse(styled.response),
        };
      case 11: // CompletedSessionResult
        final completed = result as fbs.CompletedSessionResult;
        return {
          'result': 'completed_session',
          'completed': _parseCompletedSession(completed.completed),
        };
      case 13: // SessionSnippetsResult
        final snippets = result as fbs.SessionSnippetsResult;
        return {
          'result': 'session_snippets',
          'entries': (snippets.entries ?? [])
              .map(
                (entry) => {
                  'session_id': entry.sessionId,
                  'snippet': entry.snippet,
                  'detail': entry.detail,
                },
              )
              .toList(),
        };
      default:
        return {};
    }
  }

  Map<String, dynamic> _parseAttachSessionResponse(
    fbs.AttachSessionResponse? resp,
  ) {
    if (resp == null) return {};
    return {
      'snapshot': _parseSessionSnapshot(resp.snapshot),
      'lease': _parseLeaseState(resp.lease),
    };
  }

  Map<String, dynamic> _parseSessionSnapshot(fbs.SessionSnapshot? snap) {
    if (snap == null) return {};
    return {
      'output_seq': snap.outputSeq,
      'bytes_logged': snap.bytesLogged,
      'size': _parseSessionSize(snap.size),
      'visible_rows': snap.visibleRows ?? [],
      'styled_rows_start': snap.styledRowsStart,
      'styled_rows': (snap.styledRows ?? [])
          .map((row) => _parseStyledRow(row))
          .toList(),
      'cursor': _parseTerminalCursor(snap.cursor),
      'current_working_directory': snap.currentWorkingDirectory,
      'context': _parseSessionContext(snap.context),
      'bracketed_paste_enabled': snap.bracketedPasteEnabled,
      'exited': snap.exited,
      // Raw output-history tail for client-side re-emulation (empty from old
      // hosts). raw_output_start is its byte offset in the full output log.
      'raw_output': snap.rawOutput,
      'raw_output_start': snap.rawOutputStart,
      // Local-LLM one-line description of the session, if generated.
      'snippet': snap.snippet,
      // Local-LLM longer-form summary for the hover popover / search.
      'snippet_detail': snap.snippetDetail,
    };
  }

  Map<String, dynamic> _parseSessionSize(fbs.SessionSize? size) {
    if (size == null) return {};
    return {
      'rows': size.rows,
      'cols': size.cols,
      'pixel_width': size.pixelWidth,
      'pixel_height': size.pixelHeight,
      'dpi': size.dpi,
    };
  }

  Map<String, dynamic> _parseStyledRow(fbs.StyledRow? row) {
    if (row == null) return {};
    return {
      'spans': (row.spans ?? []).map((span) => _parseStyledSpan(span)).toList(),
    };
  }

  Map<String, dynamic> _parseStyledSpan(fbs.StyledSpan? span) {
    if (span == null) return {};
    return {'text': span.text, 'style': _parseTerminalStyle(span.style)};
  }

  Map<String, dynamic> _parseTerminalStyle(fbs.TerminalStyle? style) {
    if (style == null) return {};
    return {
      'foreground': style.hasForeground
          ? _parseTerminalColor(style.foreground)
          : null,
      'background': style.hasBackground
          ? _parseTerminalColor(style.background)
          : null,
      'bold': style.bold,
      'dim': style.dim,
      'italic': style.italic,
      'underline': style.underline,
      'reverse': style.reverse,
    };
  }

  Map<String, dynamic> _parseTerminalColor(fbs.TerminalColor? color) {
    if (color == null) return {};
    return {'red': color.red, 'green': color.green, 'blue': color.blue};
  }

  Map<String, dynamic> _parseTerminalCursor(fbs.TerminalCursor? cursor) {
    if (cursor == null) return {};
    return {'row': cursor.row, 'col': cursor.col, 'visible': cursor.visible};
  }

  Map<String, dynamic> _parseSessionContext(fbs.SessionContext? ctx) {
    if (ctx == null) return {};
    return {
      'repository_root': ctx.repositoryRoot,
      'worktree_root': ctx.worktreeRoot,
      'branch': ctx.branch,
    };
  }

  Map<String, dynamic> _parseLeaseState(fbs.InputLeaseState? state) {
    if (state == null) return {};
    return {
      'holder': _parseLeaseHolder(state.holder),
      'generation': state.generation,
    };
  }

  Map<String, dynamic>? _parseLeaseHolder(fbs.InputLeaseHolder? holder) {
    if (holder == null) return null;
    return {
      'client_id': holder.clientId,
      'kind': holder.kind?.name ?? 'Interactive',
    };
  }

  Map<String, dynamic> _parseLeaseChange(fbs.LeaseChange? change) {
    if (change == null) return {};
    return {
      'generation': change.generation,
      'previous': _parseLeaseHolder(change.previous),
      'current': _parseLeaseHolder(change.current),
      'action': change.action?.name ?? 'Acquired',
    };
  }

  Map<String, dynamic> _parseStyledRowsResponse(fbs.StyledRowsResponse? resp) {
    if (resp == null) return {};
    return {
      'output_seq': resp.outputSeq,
      'start': resp.start,
      'rows': (resp.rows ?? []).map((row) => _parseStyledRow(row)).toList(),
    };
  }

  Map<String, dynamic> _parseCompletedSession(fbs.CompletedSession? comp) {
    if (comp == null) return {};
    return {
      'output_seq': comp.outputSeq,
      'bytes_logged': comp.bytesLogged,
      'visible_rows': comp.visibleRows ?? [],
    };
  }

  Map<String, dynamic> _parseSessionEvent(
    fbs.SessionEventPayloadTypeId? type,
    dynamic event,
  ) {
    if (event == null || type == null) return {};
    switch (type.value) {
      case 1: // ResyncRequiredEvent
        final res = event as fbs.ResyncRequiredEvent;
        return {
          'ResyncRequired': {
            'session_id': res.sessionId,
            'latest_event_seq': res.latestEventSeq,
            'snapshot': _parseSessionSnapshot(res.snapshot),
          },
        };
      case 2: // OutputEvent
        final out = event as fbs.OutputEvent;
        return {
          'Output': {
            'session_id': out.sessionId,
            'output_seq': out.outputSeq,
            'bytes': out.bytes ?? [],
          },
        };
      case 3: // SnapshotEvent
        final snap = event as fbs.SnapshotEvent;
        return {
          'Snapshot': {
            'session_id': snap.sessionId,
            'snapshot': _parseSessionSnapshot(snap.snapshot),
          },
        };
      case 4: // LeaseChangedEvent
        final lease = event as fbs.LeaseChangedEvent;
        return {
          'LeaseChanged': {
            'session_id': lease.sessionId,
            'change': _parseLeaseChange(lease.change),
          },
        };
      case 5: // ExitedEvent
        final exited = event as fbs.ExitedEvent;
        return {
          'Exited': {
            'session_id': exited.sessionId,
            'completed': _parseCompletedSession(exited.completed),
          },
        };
      default:
        return {};
    }
  }

  List<int> _serializeFlatBuffersRequest(
    String id,
    String type,
    Map<String, dynamic>? extra,
  ) {
    final fbs.ClientRequestPayloadTypeId payloadType;
    final dynamic payload;

    switch (type) {
      case 'hello':
        payloadType = fbs.ClientRequestPayloadTypeId.HelloRequest;
        payload = fbs.HelloRequestObjectBuilder(
          clientId: extra?['client_id'] as String?,
          token: extra?['token'] as String?,
        );
        break;

      case 'pair':
        payloadType = fbs.ClientRequestPayloadTypeId.PairRequest;
        payload = fbs.PairRequestObjectBuilder(
          code: extra?['code'] as String?,
          clientId: extra?['client_id'] as String?,
        );
        break;

      case 'pairing_challenge':
        payloadType = fbs.ClientRequestPayloadTypeId.PairingChallengeRequest;
        payload = fbs.PairingChallengeRequestObjectBuilder(
          clientId: extra?['client_id'] as String?,
        );
        break;

      case 'list_sessions':
        payloadType = fbs.ClientRequestPayloadTypeId.ListSessionsRequest;
        payload = fbs.ListSessionsRequestObjectBuilder();
        break;

      case 'start_session':
        payloadType = fbs.ClientRequestPayloadTypeId.StartSessionRequestTable;
        final request = extra?['request'] as Map<String, dynamic>?;
        final sizeMap = request?['size'] as Map<String, dynamic>?;
        payload = fbs.StartSessionRequestTableObjectBuilder(
          command: request?['command'] as String?,
          args: (request?['args'] as List?)?.cast<String>(),
          cwd: request?['cwd'] as String?,
          size: sizeMap == null
              ? null
              : fbs.SessionSizeObjectBuilder(
                  rows: sizeMap['rows'] as int? ?? 24,
                  cols: sizeMap['cols'] as int? ?? 80,
                  pixelWidth: sizeMap['pixel_width'] as int? ?? 800,
                  pixelHeight: sizeMap['pixel_height'] as int? ?? 480,
                  dpi: sizeMap['dpi'] as int? ?? 96,
                ),
        );
        break;

      case 'attach_session':
        payloadType = fbs.ClientRequestPayloadTypeId.AttachSessionRequestTable;
        final request = extra?['request'] as Map<String, dynamic>?;
        final modeStr = request?['mode'] as String?;
        final fbs.AttachMode mode;
        mode = switch (modeStr) {
          'Observer' => fbs.AttachMode.Observer,
          'AgentController' => fbs.AttachMode.AgentController,
          'InteractiveController' => fbs.AttachMode.InteractiveController,
          _ => throw ArgumentError.value(
            modeStr,
            'mode',
            'Unknown attach mode',
          ),
        };
        payload = fbs.AttachSessionRequestTableObjectBuilder(
          sessionId: request?['session_id'] as String?,
          clientId: request?['client_id'] as String?,
          mode: mode,
        );
        break;

      case 'subscribe_session_events':
        payloadType =
            fbs.ClientRequestPayloadTypeId.SubscribeSessionEventsRequestTable;
        final request = extra?['request'] as Map<String, dynamic>?;
        payload = fbs.SubscribeSessionEventsRequestTableObjectBuilder(
          sessionId: request?['session_id'] as String?,
          afterEventSeq: request?['after_event_seq'] as int?,
        );
        break;

      case 'resize_session':
        payloadType = fbs.ClientRequestPayloadTypeId.ResizeSessionRequestTable;
        final request = extra?['request'] as Map<String, dynamic>?;
        final sizeMap = request?['size'] as Map<String, dynamic>?;
        payload = fbs.ResizeSessionRequestTableObjectBuilder(
          sessionId: request?['session_id'] as String?,
          size: sizeMap == null
              ? null
              : fbs.SessionSizeObjectBuilder(
                  rows: sizeMap['rows'] as int? ?? 24,
                  cols: sizeMap['cols'] as int? ?? 80,
                  pixelWidth: sizeMap['pixel_width'] as int? ?? 800,
                  pixelHeight: sizeMap['pixel_height'] as int? ?? 480,
                  dpi: sizeMap['dpi'] as int? ?? 96,
                ),
        );
        break;

      case 'restore_session':
        payloadType = fbs.ClientRequestPayloadTypeId.RestoreSessionRequestTable;
        final request = extra?['request'] as Map<String, dynamic>?;
        final sizeMap = request?['size'] as Map<String, dynamic>?;
        payload = fbs.RestoreSessionRequestTableObjectBuilder(
          sessionId: request?['session_id'] as String?,
          size: sizeMap == null
              ? null
              : fbs.SessionSizeObjectBuilder(
                  rows: sizeMap['rows'] as int? ?? 24,
                  cols: sizeMap['cols'] as int? ?? 80,
                  pixelWidth: sizeMap['pixel_width'] as int? ?? 800,
                  pixelHeight: sizeMap['pixel_height'] as int? ?? 480,
                  dpi: sizeMap['dpi'] as int? ?? 96,
                ),
        );
        break;

      case 'snapshot_session':
        payloadType = fbs.ClientRequestPayloadTypeId.SnapshotSessionRequest;
        payload = fbs.SnapshotSessionRequestObjectBuilder(
          sessionId: extra?['session_id'] as String?,
        );
        break;

      case 'shutdown_session':
        payloadType = fbs.ClientRequestPayloadTypeId.ShutdownSessionRequest;
        payload = fbs.ShutdownSessionRequestObjectBuilder(
          sessionId: extra?['session_id'] as String?,
        );
        break;

      case 'styled_rows':
        payloadType = fbs.ClientRequestPayloadTypeId.StyledRowsRequestTable;
        final request = extra?['request'] as Map<String, dynamic>?;
        payload = fbs.StyledRowsRequestTableObjectBuilder(
          sessionId: request?['session_id'] as String?,
          start: request?['start'] as int?,
          end: request?['end'] as int?,
        );
        break;

      case 'list_session_snippets':
        payloadType = fbs.ClientRequestPayloadTypeId.ListSessionSnippetsRequest;
        payload = fbs.ListSessionSnippetsRequestObjectBuilder();
        break;

      default:
        throw UnimplementedError(
          'FlatBuffers serialization not implemented for request type: $type',
        );
    }

    final msg = fbs.ClientMessageObjectBuilder(
      id: id,
      payloadType: payloadType,
      payload: payload,
    );
    return msg.toBytes();
  }
}
