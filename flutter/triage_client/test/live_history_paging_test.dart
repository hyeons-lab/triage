// Live-daemon paging checks for virtual scrollback cell pages.
//
// Exercises the real daemon round trip: FlatBuffers `SyncTerminal` frames and
// `FetchTerminalRows` pages decode into `SessionVm` / `TerminalCellBuffer`.
// Skipped unless `TRIAGE_LIVE_WS` points at a daemon (e.g. ws://<host>:7777/ws),
// so CI stays hermetic.
//
// Run: `TRIAGE_LIVE_WS=ws://<host>:7777/ws flutter test
// test/live_history_paging_test.dart`
import 'dart:io';
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/main.dart';
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';

String? get _liveWs {
  const url = String.fromEnvironment('TRIAGE_LIVE_WS');
  if (url.isNotEmpty) return url;
  return Platform.environment['TRIAGE_LIVE_WS'];
}

String get _liveSession {
  const session = String.fromEnvironment('TRIAGE_LIVE_SESSION');
  if (session.isNotEmpty) return session;
  return Platform.environment['TRIAGE_LIVE_SESSION'] ?? 'session-255';
}

void main() {
  test(
    'live FBS syncTerminalSession and fetchTerminalRows decode TCG1 cell batches',
    () async {
      final client = TriageWebSocketClient(Uri.parse(_liveWs!));
      try {
        await client.connect();
        expect(client.isFlatBuffersNegotiated, isTrue);
        final token = await client.pairViaTailscale(clientId: 'live-probe');
        await client.hello(clientId: 'live-probe', token: token);

        final syncRes = await client.syncTerminalSession(
          sessionId: _liveSession,
          clientId: 'live-probe',
          mode: 'Observer',
          subscribe: false,
          knownFrameSeq: 0,
        );
        final response =
            syncRes['response'] as Map<String, dynamic>? ?? syncRes;
        final frameMap = response['frame'] as Map<String, dynamic>?;
        expect(frameMap, isNotNull);

        final frame = TerminalSyncFrameData.fromMap(frameMap!);
        expect(frame.rows, greaterThan(0));
        expect(frame.cols, greaterThan(0));
        expect(frame.viewportPayload, isNotEmpty);

        final viewportRows = decodeTcg1Batch(
          frame.viewportCompression,
          frame.viewportPayload,
        );
        expect(viewportRows, isNotEmpty);

        if (frame.totalScrollbackRows > 0) {
          final count = min(kScrollbackPageSize, frame.totalScrollbackRows);
          final pageRes = await client.fetchTerminalRows(
            sessionId: _liveSession,
            startRow: 0,
            rowCount: count,
          );
          final page = TerminalRowsPageData.fromMap(pageRes);
          expect(page.rowCount, greaterThan(0));
          final decodedPage = decodeTcg1Batch(page.compression, page.payload);
          expect(decodedPage.length, page.rowCount);
        }
      } finally {
        await client.disconnect();
      }
    },
    skip: _liveWs == null ? 'needs TRIAGE_LIVE_WS' : null,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'live demand-paging populates SessionVm TerminalCellBuffer virtual scrollback',
    () async {
      final client = TriageWebSocketClient(Uri.parse(_liveWs!));
      try {
        await client.connect();
        final token = await client.pairViaTailscale(clientId: 'live-probe2');
        await client.hello(clientId: 'live-probe2', token: token);

        final syncRes = await client.syncTerminalSession(
          sessionId: _liveSession,
          clientId: 'live-probe2',
          mode: 'Observer',
          cols: 80,
          rows: 24,
          resizePty: false,
          subscribe: false,
          knownFrameSeq: 0,
        );
        final response =
            syncRes['response'] as Map<String, dynamic>? ?? syncRes;
        final frame = TerminalSyncFrameData.fromMap(
          response['frame'] as Map<String, dynamic>,
        );

        final session = SessionVm(
          title: 'triage / $_liveSession',
          sessionId: _liveSession,
          status: 'attached',
          statusColor: const Color(0xff7fd1c7),
          icon: Icons.terminal,
          rows: const [],
          isRemote: true,
        );
        addTearDown(session.dispose);

        session.applyTerminalSyncFrame(
          frame,
          notifyReplay: true,
          snapshot: response['snapshot'] as Map<String, dynamic>?,
        );
        expect(
          session.terminal.totalLines,
          frame.totalScrollbackRows + frame.rows,
        );

        if (frame.totalScrollbackRows > 0) {
          expect(session.terminal.lineAtVirtualRow(0), isNull);
          final count = min(kScrollbackPageSize, frame.totalScrollbackRows);
          final pageRes = await client.fetchTerminalRows(
            sessionId: _liveSession,
            startRow: 0,
            rowCount: count,
          );
          final page = TerminalRowsPageData.fromMap(pageRes);
          session.terminal.applyFetchedRows(page);
          expect(session.terminal.lineAtVirtualRow(0), isNotNull);
        }
      } finally {
        await client.disconnect();
      }
    },
    skip: _liveWs == null ? 'needs TRIAGE_LIVE_WS' : null,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
