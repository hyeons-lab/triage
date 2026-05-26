import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:triage_client/main.dart';
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:triage_client/widgets/terminal_pane.dart';

class FakeTriageWebSocketClient extends TriageWebSocketClient {
  FakeTriageWebSocketClient({
    this.shouldFailConnection = false,
    this.failConnectAttempts = 0,
    Set<String>? exitedSessionIds,
  }) : exitedSessionIds = {...?exitedSessionIds},
       super(Uri.parse('ws://localhost:8080/ws'));

  final bool shouldFailConnection;
  int failConnectAttempts;
  final Set<String> exitedSessionIds;

  final StreamController<Map<String, dynamic>> _testEventController =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  @override
  Stream<Map<String, dynamic>> get events => _testEventController.stream;

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  final List<String> startSessionCalls = [];
  final List<String> writeInputCalls = [];
  final List<String> attachSessionCalls = [];
  final List<String> restoreSessionCalls = [];
  final Map<String, String> restoreSessionSizes = {};
  final List<String> helloClientIds = [];
  final List<String> snapshotSessionCalls = [];
  final Map<String, List<String>> snapshotVisibleRows = {};
  final Map<String, Completer<Map<String, dynamic>>> snapshotCompleters = {};
  final Map<String, List<dynamic>> snapshotStyledRowsMap = {};

  @override
  Future<void> connect() async {
    if (shouldFailConnection || failConnectAttempts > 0) {
      if (failConnectAttempts > 0) {
        failConnectAttempts -= 1;
      }
      throw Exception('Connection failed');
    }
    _connected = true;
  }

  @override
  Future<Map<String, dynamic>> hello({String? clientId, String? token}) async {
    if (clientId != null) {
      helloClientIds.add(clientId);
    }
    return {'protocol_version': '2026-05-20', 'authenticated': true};
  }

  @override
  Future<List<String>> listSessions() async {
    return ['flutter-spike', 'websocket-session-api', 'main'];
  }

  @override
  Future<Map<String, dynamic>> attachSession({
    required String sessionId,
    required String clientId,
    String mode = 'InteractiveController',
  }) async {
    attachSessionCalls.add(sessionId);
    final completer = snapshotCompleters[sessionId];
    if (completer != null) {
      final snapRes = await completer.future;
      return {
        'response': {
          'snapshot': snapRes['snapshot'],
        },
      };
    }
    final visibleRows = snapshotVisibleRows[sessionId];
    if (visibleRows != null) {
      return {
        'response': {
          'snapshot': {
            'size': {'rows': 24, 'cols': 80},
            'exited': exitedSessionIds.contains(sessionId),
            'visible_rows': visibleRows,
            'styled_rows': visibleRows
                .map(
                  (row) => {
                    'spans': [
                      {
                        'text': row,
                        'style': {
                          'foreground': null,
                          'background': null,
                          'bold': false,
                          'dim': false,
                          'italic': false,
                          'underline': false,
                          'reverse': false,
                        },
                      },
                    ],
                  },
                )
                .toList(),
            'cursor': {'row': visibleRows.length - 1, 'col': 0},
          },
        },
      };
    }
    return {
      'response': {
        'snapshot': {
          'context': {
            'branch': sessionId == 'main' ? 'main' : 'experiment/flutter-spike',
          },
          'size': {'rows': 24, 'cols': 80},
          'exited': exitedSessionIds.contains(sessionId),
          'styled_rows': [
            {
              'spans': [
                {
                  'text': 'line 1 from $sessionId',
                  'style': {
                    'foreground': null,
                    'background': null,
                    'bold': false,
                    'dim': false,
                    'italic': false,
                    'underline': false,
                    'reverse': false,
                  },
                },
              ],
            },
            {
              'spans': [
                {
                  'text': 'line 2 from $sessionId',
                  'style': {
                    'foreground': null,
                    'background': null,
                    'bold': false,
                    'dim': false,
                    'italic': false,
                    'underline': false,
                    'reverse': false,
                  },
                },
              ],
            },
          ],
        },
      },
    };
  }

  @override
  Future<Map<String, dynamic>> snapshotSession({
    required String sessionId,
  }) async {
    snapshotSessionCalls.add(sessionId);
    final completer = snapshotCompleters[sessionId];
    if (completer != null) {
      return completer.future;
    }
    final visibleRows = snapshotVisibleRows[sessionId];
    return {
      'snapshot': {
        'size': {'rows': 24, 'cols': 80},
        'exited': exitedSessionIds.contains(sessionId),
        if (visibleRows != null) ...{
          'visible_rows': visibleRows,
          'styled_rows': visibleRows
              .map(
                (row) => {
                  'spans': [
                    {
                      'text': row,
                      'style': {
                        'foreground': null,
                        'background': null,
                        'bold': false,
                        'dim': false,
                        'italic': false,
                        'underline': false,
                        'reverse': false,
                      },
                    },
                  ],
                },
              )
              .toList(),
          'cursor': {'row': visibleRows.length - 1, 'col': 0},
        },
      },
    };
  }

  @override
  Future<Map<String, dynamic>> restoreSession({
    required String sessionId,
    required int cols,
    required int rows,
  }) async {
    restoreSessionCalls.add(sessionId);
    restoreSessionSizes[sessionId] = '${cols}x${rows}';
    exitedSessionIds.remove(sessionId);
    return {
      'snapshot': {
        'size': {'rows': rows, 'cols': cols},
        'exited': false,
      },
    };
  }

  @override
  Future<String> subscribeSessionEvents({
    required String sessionId,
    int? afterEventSeq,
  }) async {
    return 'sub-$sessionId';
  }

  @override
  Future<String> startSession({
    required String command,
    List<String> args = const [],
    String? cwd,
    int rows = 24,
    int cols = 80,
  }) async {
    final nextId = 'scratch-${startSessionCalls.length + 1}';
    startSessionCalls.add(nextId);
    return nextId;
  }

  @override
  Future<void> writeInput({
    required String sessionId,
    required String clientId,
    required List<int> bytes,
  }) async {
    writeInputCalls.add(sessionId);
  }

  final List<String> resizeSessionCalls = [];

  @override
  Future<Map<String, dynamic>> resizeSession({
    required String sessionId,
    required int cols,
    required int rows,
  }) async {
    resizeSessionCalls.add('$sessionId:$cols:$rows');
    return {};
  }

  @override
  Future<Map<String, dynamic>> styledRows({
    required String sessionId,
    required int start,
    required int end,
  }) async {
    final rows = snapshotStyledRowsMap[sessionId] ?? <dynamic>[];
    return {
      'response': {'rows': rows},
    };
  }

  final List<String> shutdownSessionCalls = [];

  @override
  Future<void> shutdownSession({required String sessionId}) async {
    shutdownSessionCalls.add(sessionId);
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  Future<void> emitSocketClosed() async {
    _connected = false;
    _testEventController.add({'type': 'connection_closed'});
  }

  void emitExited(String sessionId) {
    _testEventController.add({
      'type': 'event',
      'envelope': {
        'event': {
          'Exited': {'session_id': sessionId},
        },
      },
    });
  }

  void emitSnapshot(
    String sessionId,
    List<String> visibleRows, {
    List<String>? styledRows,
  }) {
    final snapshotStyledRows = styledRows ?? visibleRows;
    final mappedRows = snapshotStyledRows
        .map(
          (row) => {
            'spans': [
              {
                'text': row,
                'style': {
                  'foreground': null,
                  'background': null,
                  'bold': false,
                  'dim': false,
                  'italic': false,
                  'underline': false,
                  'reverse': false,
                },
              },
            ],
          },
        )
        .toList();
    snapshotStyledRowsMap[sessionId] = mappedRows;

    _testEventController.add({
      'type': 'event',
      'envelope': {
        'event': {
          'Snapshot': {
            'session_id': sessionId,
            'snapshot': {
              'output_seq': 42,
              'exited': false,
              'visible_rows': visibleRows,
              'styled_rows': mappedRows,
              'cursor': {'row': visibleRows.length - 1, 'col': 0},
            },
          },
        },
      },
    });
  }
}

void main() {
  testWidgets(
    'shows Triage session shell with daemon sessions when connected',
    (WidgetTester tester) async {
      final client = FakeTriageWebSocketClient();
      await tester.pumpWidget(TriageClientApp(client: client));
      await tester.pumpAndSettle();

      expect(find.text('Triage'), findsOneWidget);
      expect(find.text('triage / flutter-spike'), findsWidgets);
      expect(find.text('Connected to Daemon'), findsOneWidget);
    },
  );

  testWidgets('selects sessions and sends input over WebSocket', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('triage / main'));
    await tester.pumpAndSettle();
    expect(find.text('main'), findsOneWidget);

    final terminalPane = tester.widget<TerminalPane>(find.byType(TerminalPane));
    terminalPane.controller.sendInput('pwd');
    await tester.pumpAndSettle();

    expect(client.writeInputCalls.contains('main'), isTrue);
  });

  testWidgets('restores historical daemon sessions before attaching input', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient(
      exitedSessionIds: {'flutter-spike'},
    );
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(client.restoreSessionCalls, contains('flutter-spike'));
    expect(find.text('attached'), findsWidgets);

    final terminalPane = tester.widget<TerminalPane>(find.byType(TerminalPane));
    terminalPane.controller.sendInput('pwd');
    await tester.pumpAndSettle();

    expect(client.writeInputCalls.contains('flutter-spike'), isTrue);
  });

  testWidgets('restores historical sessions using authentic saved size when available', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final client = FakeTriageWebSocketClient(exitedSessionIds: {'main'});
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(client.restoreSessionCalls, contains('main'));
    expect(client.restoreSessionSizes['main'], '80x24');
  });

  testWidgets('restores historical sessions using estimated viewport size when saved size is absent', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final client = FakeTriageWebSocketClient(exitedSessionIds: {'main'});
    client.snapshotCompleters['main'] = Completer<Map<String, dynamic>>()..complete({
      'snapshot': {
        'context': {'branch': 'main'},
        'exited': true,
        'size': null,
      }
    });

    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(client.restoreSessionCalls, contains('main'));
    expect(client.restoreSessionSizes['main'], '94x40');
  });

  testWidgets('applies daemon snapshot events to replace restored rows', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('line 1 from flutter-spike'), findsOneWidget);

    client.emitSnapshot(
      'flutter-spike',
      ['stale full-screen row', 'wide restored row'],
      styledRows: ['wide restored row'],
    );
    await tester.pumpAndSettle();

    expect(find.text('wide restored row'), findsOneWidget);
    expect(find.text('stale full-screen row'), findsNothing);
    expect(find.text('line 1 from flutter-spike'), findsOneWidget);
  });

  testWidgets('refreshes selected remote session from daemon snapshot', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    client.snapshotVisibleRows['flutter-spike'] = ['refreshed flutter-spike'];
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('triage / main'));
    await tester.pumpAndSettle();
    client.snapshotVisibleRows['flutter-spike'] = ['fresh after switch back'];

    await tester.tap(find.text('triage / flutter-spike').first);
    await tester.pumpAndSettle();

    expect(client.snapshotSessionCalls, contains('flutter-spike'));
    expect(find.text('fresh after switch back'), findsOneWidget);
    expect(find.text('line 1 from flutter-spike'), findsNothing);
  });

  testWidgets(
    'marks replay pending while selected session snapshot refreshes',
    (WidgetTester tester) async {
      final client = FakeTriageWebSocketClient();
      await tester.pumpWidget(TriageClientApp(client: client));
      await tester.pumpAndSettle();

      final completer = Completer<Map<String, dynamic>>();
      client.snapshotCompleters['main'] = completer;
      await tester.tap(find.text('triage / main'));
      await tester.pump();

      var terminalPane = tester.widget<TerminalPane>(find.byType(TerminalPane));
      expect(terminalPane.replayPending, isTrue);

      completer.complete({
        'snapshot': {
          'size': {'rows': 24, 'cols': 80},
          'exited': false,
          'visible_rows': ['main refreshed'],
          'styled_rows': [
            {
              'spans': [
                {
                  'text': 'main refreshed',
                  'style': {
                    'foreground': null,
                    'background': null,
                    'bold': false,
                    'dim': false,
                    'italic': false,
                    'underline': false,
                    'reverse': false,
                  },
                },
              ],
            },
          ],
        },
      });
      await tester.pumpAndSettle();

      terminalPane = tester.widget<TerminalPane>(find.byType(TerminalPane));
      expect(terminalPane.replayPending, isFalse);
      expect(find.text('main refreshed'), findsOneWidget);
    },
  );

  testWidgets('creates a scratch session over WebSocket', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('New session'));
    await tester.pumpAndSettle();

    expect(find.text('triage / scratch-1'), findsWidgets);
    expect(find.text('line 1 from scratch-1'), findsOneWidget);
  });

  testWidgets('keeps retrying when connection fails', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient(shouldFailConnection: true);
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pump();

    expect(find.text('Triage'), findsOneWidget);
    expect(find.text('triage / flutter-spike'), findsWidgets);
    expect(find.text('Reconnecting...'), findsOneWidget);
  });

  testWidgets('closes a session over WebSocket and removes it from the list', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    // Verify initial active session is triage / flutter-spike
    expect(find.text('triage / flutter-spike'), findsWidgets);

    // Tap on close button
    await tester.tap(find.byTooltip('Close session'));
    await tester.pumpAndSettle();

    // Verify shutdown session was called with 'flutter-spike'
    expect(client.shutdownSessionCalls.contains('flutter-spike'), isTrue);

    // Verify session was removed and selected index was updated
    expect(find.text('triage / flutter-spike'), findsNothing);
  });

  testWidgets('uses a persisted per-install client id for authentication', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(client.helloClientIds, isNotEmpty);
    expect(client.helloClientIds.single, isNot('triage-flutter-client'));
    expect(client.helloClientIds.single, startsWith('triage-flutter-client-'));

    final secondClient = FakeTriageWebSocketClient();
    await tester.pumpWidget(
      TriageClientApp(key: UniqueKey(), client: secondClient),
    );
    await tester.pumpAndSettle();

    expect(secondClient.helloClientIds.single, client.helloClientIds.single);
  });

  testWidgets('does not locally edit daemon terminal after disconnect', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    final terminalPane = tester.widget<TerminalPane>(find.byType(TerminalPane));
    await client.disconnect();

    terminalPane.controller.sendInput('typed while disconnected');
    terminalPane.controller.sendInput('\x7f');
    await tester.pumpAndSettle();

    expect(client.writeInputCalls, isEmpty);
    expect(find.textContaining('typed while disconnected'), findsNothing);
    expect(find.text('disconnected'), findsWidgets);
  });

  testWidgets('does not locally edit daemon terminal after exit', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    client.emitExited('flutter-spike');
    await tester.pumpAndSettle();

    final terminalPane = tester.widget<TerminalPane>(find.byType(TerminalPane));
    terminalPane.controller.sendInput('typed after exit');
    terminalPane.controller.sendInput('\x7f');
    await tester.pumpAndSettle();

    expect(client.writeInputCalls, isEmpty);
    expect(find.textContaining('typed after exit'), findsNothing);
    expect(find.text('exited'), findsWidgets);
  });

  testWidgets('reconnects while app is running after connection failure', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient(failConnectAttempts: 1);
    await tester.pumpWidget(TriageClientApp(client: client));

    await tester.pump();
    expect(client.helloClientIds, isEmpty);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(client.helloClientIds.length, 1);
    expect(find.text('Connected to Daemon'), findsOneWidget);
  });
}
