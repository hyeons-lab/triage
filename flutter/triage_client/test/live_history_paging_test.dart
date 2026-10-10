// Live-daemon paging checks for scrollback history windows.
//
// Exercises the REAL daemon round trip: FlatBuffers attach windows come
// back exact with older starts, and replaying a deeper window through a
// real SessionVm grows the terminal buffer. Skipped unless
// TRIAGE_LIVE_WS points at a daemon (e.g. ws://100.104.160.90:7777/ws),
// so CI stays hermetic.
//
// Run: `TRIAGE_LIVE_WS=ws://<host>:7777/ws flutter test
// test/live_history_paging_test.dart`
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/main.dart';
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:triage_client/terminal/terminal_intent.dart';

String? get _liveWs {
  const url = String.fromEnvironment('TRIAGE_LIVE_WS');
  if (url.isNotEmpty) return url;
  return Platform.environment['TRIAGE_LIVE_WS'];
}

String get _liveSessionId {
  const sid = String.fromEnvironment('TRIAGE_LIVE_SESSION');
  if (sid.isNotEmpty) return sid;
  return Platform.environment['TRIAGE_LIVE_SESSION'] ?? 'session-255';
}

Future<Map<String, dynamic>> _window(
  TriageWebSocketClient client,
  String clientId,
  int bytes, {
  String? sessionId,
}) async {
  final res = await client.attachSession(
    sessionId: sessionId ?? _liveSessionId,
    clientId: clientId,
    mode: 'Observer',
    historyBytes: bytes,
  );
  final response = res['response'] as Map<String, dynamic>?;
  return response?['snapshot'] as Map<String, dynamic>? ?? {};
}

void main() {
  test(
    'live FBS history windows widen with older starts',
    () async {
      final client = TriageWebSocketClient(Uri.parse(_liveWs!));
      try {
        await client.connect();
        expect(client.isFlatBuffersNegotiated, isTrue);
        final token = await client.pairViaTailscale(clientId: 'live-probe');
        await client.hello(clientId: 'live-probe', token: token);
        var olderStart = 1 << 62;
        for (final window in [65536, 131072, 262144]) {
          final snap = await _window(client, 'live-probe', window);
          final raw = snap['raw_output'];
          expect(raw, isA<Uint8List>());
          expect((raw as Uint8List).length, window);
          final start = snap['raw_output_start'] as int;
          expect(start, lessThan(olderStart));
          olderStart = start;
        }
      } finally {
        await client.disconnect();
      }
    },
    skip: _liveWs == null ? 'needs TRIAGE_LIVE_WS' : null,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'live deeper window replay grows the terminal buffer',
    () async {
      final client = TriageWebSocketClient(Uri.parse(_liveWs!));
      try {
        await client.connect();
        final token = await client.pairViaTailscale(clientId: 'live-probe2');
        await client.hello(clientId: 'live-probe2', token: token);
        final w64 = await _window(client, 'live-probe2', 65536);
        final w128 = await _window(client, 'live-probe2', 131072);

        final targetSessionId = _liveSessionId;
        final session = SessionVm(
          title: 'triage / $targetSessionId',
          sessionId: targetSessionId,
          status: 'attached',
          statusColor: const Color(0xff7fd1c7),
          icon: Icons.terminal,
          rows: const [],
          isRemote: true,
        );
        session.applyHistory(
          (w64['raw_output'] as Uint8List).toList(),
          throughOutputSeq: w64['output_seq'] as int?,
          rawOutputStart: w64['raw_output_start'] as int?,
          windowBytes: 65536,
        );
        session.noteViewFit(80, 24);
        final firstLines = session.terminal.buffer.lines.length;

        session.store.dispatch(const Attach());
        session.historyWindowBytes = 131072;
        session.applyHistory(
          (w128['raw_output'] as Uint8List).toList(),
          throughOutputSeq: w128['output_seq'] as int?,
          rawOutputStart: w128['raw_output_start'] as int?,
          windowBytes: 131072,
        );
        expect(
          session.terminal.buffer.lines.length,
          greaterThan(firstLines),
        );
      } finally {
        await client.disconnect();
      }
    },
    skip: _liveWs == null ? 'needs TRIAGE_LIVE_WS' : null,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
