import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_client/main.dart';
import 'package:argus_client/services/argus_websocket_client.dart';
import 'package:argus_client/widgets/terminal_pane.dart';

class FakeArgusWebSocketClient extends ArgusWebSocketClient {
  FakeArgusWebSocketClient({this.shouldFailConnection = false})
    : super(Uri.parse('ws://localhost:8080/ws'));

  final bool shouldFailConnection;

  final StreamController<Map<String, dynamic>> _testEventController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _testEventController.stream;

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  final List<String> startSessionCalls = [];
  final List<String> writeInputCalls = [];
  final List<String> attachSessionCalls = [];

  @override
  Future<void> connect() async {
    if (shouldFailConnection) {
      throw Exception('Connection failed');
    }
    _connected = true;
  }

  @override
  Future<Map<String, dynamic>> hello() async {
    return {'protocol_version': '2026-05-20'};
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
}

void main() {
  testWidgets('shows Argus session shell with daemon sessions when connected', (
    WidgetTester tester,
  ) async {
    final client = FakeArgusWebSocketClient();
    await tester.pumpWidget(ArgusClientApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('Argus'), findsOneWidget);
    expect(find.text('argus / flutter-spike'), findsWidgets);
    expect(find.text('Connected to Daemon'), findsOneWidget);
  });

  testWidgets('selects sessions and sends input over WebSocket', (
    WidgetTester tester,
  ) async {
    final client = FakeArgusWebSocketClient();
    await tester.pumpWidget(ArgusClientApp(client: client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('argus / main'));
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
    final client = FakeArgusWebSocketClient();
    await tester.pumpWidget(ArgusClientApp(client: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('New session'));
    await tester.pumpAndSettle();

    expect(find.text('argus / scratch-1'), findsWidgets);
    expect(find.text('line 1 from scratch-1'), findsOneWidget);
  });

  testWidgets('falls back to local mock sessions when connection fails', (
    WidgetTester tester,
  ) async {
    final client = FakeArgusWebSocketClient(shouldFailConnection: true);
    await tester.pumpWidget(ArgusClientApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('Argus'), findsOneWidget);
    expect(find.text('argus / flutter-spike'), findsWidgets);
    expect(find.text('Offline (Local Mock)'), findsOneWidget);
  });

  testWidgets('closes a session over WebSocket and removes it from the list', (
    WidgetTester tester,
  ) async {
    final client = FakeArgusWebSocketClient();
    await tester.pumpWidget(ArgusClientApp(client: client));
    await tester.pumpAndSettle();

    // Verify initial active session is argus / flutter-spike
    expect(find.text('argus / flutter-spike'), findsWidgets);

    // Tap on close button
    await tester.tap(find.byTooltip('Close session'));
    await tester.pumpAndSettle();

    // Verify shutdown session was called with 'flutter-spike'
    expect(client.shutdownSessionCalls.contains('flutter-spike'), isTrue);

    // Verify session was removed and selected index was updated
    expect(find.text('argus / flutter-spike'), findsNothing);
  });
}
