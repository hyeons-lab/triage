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
  }) : super(Uri.parse('ws://localhost:8080/ws'));

  final bool shouldFailConnection;
  int failConnectAttempts;

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
  final List<String> helloClientIds = [];

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
    return {
      'response': {
        'snapshot': {
          'context': {
            'branch': sessionId == 'main' ? 'main' : 'experiment/flutter-spike',
          },
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
