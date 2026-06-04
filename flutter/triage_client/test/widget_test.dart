import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart' show CheckedPopupMenuItem, TextField;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:triage_client/main.dart';
import 'package:triage_client/services/storage.dart';
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:triage_client/widgets/terminal_pane.dart';

class FakeTriageWebSocketClient extends TriageWebSocketClient {
  FakeTriageWebSocketClient({
    Uri? uri,
    this.shouldFailConnection = false,
    this.failConnectAttempts = 0,
    this.authenticated = true,
    this.disconnectAfterHello = false,
    Set<String>? exitedSessionIds,
    Set<String>? failedStartSessionCommands,
  }) : exitedSessionIds = {...?exitedSessionIds},
       failedStartSessionCommands = {...?failedStartSessionCommands},
       super(uri ?? Uri.parse('ws://localhost:8080/ws'));

  final bool shouldFailConnection;
  int failConnectAttempts;
  bool authenticated;
  final bool disconnectAfterHello;
  final Set<String> exitedSessionIds;
  final Set<String> failedStartSessionCommands;

  final StreamController<Map<String, dynamic>> _testEventController =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  @override
  Stream<Map<String, dynamic>> get events => _testEventController.stream;

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  final List<String> startSessionCalls = [];
  final List<String> startSessionCommands = [];
  final List<List<String>> startSessionArgs = [];
  final List<String> pairingChallengeClientIds = [];
  final List<String> pairCodes = [];
  final List<String> writeInputCalls = [];
  final List<String> attachSessionCalls = [];
  final List<String> restoreSessionCalls = [];
  final Map<String, String> restoreSessionSizes = {};
  final List<String> helloClientIds = [];
  final List<String?> helloTokens = [];
  final List<String> snapshotSessionCalls = [];
  final Map<String, List<String>> snapshotVisibleRows = {};
  final Map<String, List<String>> resizedVisibleRows = {};
  final Map<String, Completer<Map<String, dynamic>>> snapshotCompleters = {};
  final Map<String, Completer<Map<String, dynamic>>> attachCompleters = {};
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
    helloTokens.add(token);
    if (disconnectAfterHello) {
      _connected = false;
    }
    return {'protocol_version': '2026-05-20', 'authenticated': authenticated};
  }

  @override
  Future<Map<String, dynamic>> pairingChallenge({
    required String clientId,
  }) async {
    pairingChallengeClientIds.add(clientId);
    return {
      'device_code': 'ABCD1234',
      'expires_at':
          DateTime.now()
              .add(const Duration(minutes: 15))
              .toUtc()
              .millisecondsSinceEpoch ~/
          1000,
    };
  }

  @override
  Future<String> pair({required String code, required String clientId}) async {
    pairCodes.add(code);
    authenticated = true;
    return 'paired-token';
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
    final attachCompleter = attachCompleters[sessionId];
    if (attachCompleter != null) {
      return attachCompleter.future;
    }
    final completer = snapshotCompleters[sessionId];
    if (completer != null) {
      final snapRes = await completer.future;
      return {
        'response': {'snapshot': snapRes['snapshot']},
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
    startSessionCommands.add(command);
    startSessionArgs.add(args);
    if (failedStartSessionCommands.contains(command)) {
      throw Exception('start session failed for $command');
    }
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
    final visibleRows = resizedVisibleRows[sessionId];
    if (visibleRows == null) {
      return {};
    }
    snapshotVisibleRows[sessionId] = visibleRows;
    return {
      'snapshot': {
        'size': {'rows': rows, 'cols': cols},
        'exited': false,
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
    };
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

  void emitOutput(String sessionId, String text, {int outputSeq = 1}) {
    _testEventController.add({
      'type': 'event',
      'envelope': {
        'event': {
          'Output': {
            'session_id': sessionId,
            'output_seq': outputSeq,
            'bytes': utf8.encode(text),
          },
        },
      },
    });
  }

  Map<String, dynamic> attachSnapshotResponse(
    String sessionId,
    List<String> visibleRows,
  ) {
    return {
      'response': {
        'snapshot': {
          'context': {
            'branch': sessionId == 'main' ? 'main' : 'experiment/flutter-spike',
          },
          'size': {'rows': 24, 'cols': 80},
          'output_seq': 0,
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

Future<void> withPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  test('chooses new-session shell options by platform', () {
    expect(newSessionShellMenuOrderForPlatform(TargetPlatform.windows), [
      NewSessionShell.cmd,
      NewSessionShell.bash,
    ]);
    expect(newSessionShellMenuOrderForPlatform(TargetPlatform.macOS), [
      NewSessionShell.defaultPosix,
    ]);
    expect(newSessionShellMenuOrderForPlatform(TargetPlatform.linux), [
      NewSessionShell.defaultPosix,
    ]);
    expect(showNewSessionShellMenuForPlatform(TargetPlatform.windows), isTrue);
    expect(showNewSessionShellMenuForPlatform(TargetPlatform.macOS), isFalse);
    expect(showNewSessionShellMenuForPlatform(TargetPlatform.linux), isFalse);
  });

  test('uses daemon websocket target for Flutter dev server base URL', () {
    expect(
      defaultWebSocketUriForBase(Uri.parse('http://127.0.0.1:8080/')),
      Uri.parse('ws://127.0.0.1:7777/ws'),
    );
  });

  test(
    'uses same-origin websocket target when served by default daemon port',
    () {
      expect(
        defaultWebSocketUriForBase(
          Uri.parse('https://triage.example.test:7777/app/?mock=false#top'),
        ),
        Uri.parse('wss://triage.example.test:7777/ws'),
      );
    },
  );

  test('uses daemon websocket target for non-http base URLs', () {
    expect(
      defaultWebSocketUriForBase(Uri.parse('file:///tmp/triage/index.html')),
      Uri.parse('ws://127.0.0.1:7777/ws'),
    );
  });

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

  testWidgets('shows available sessions while one daemon session is loading', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    final delayedSnapshot = Completer<Map<String, dynamic>>();
    client.snapshotCompleters['flutter-spike'] = delayedSnapshot;

    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('triage / flutter-spike'), findsWidgets);
    expect(find.text('Loading session flutter-spike...'), findsOneWidget);
    expect(find.text('triage / main'), findsWidgets);
    expect(find.text('Loading 3 sessions...'), findsOneWidget);

    await tester.tap(find.text('triage / main').first);
    await tester.pumpAndSettle();
    expect(find.text('line 1 from main'), findsOneWidget);

    delayedSnapshot.complete({
      'snapshot': {
        'context': {'branch': 'experiment/flutter-spike'},
        'size': {'rows': 24, 'cols': 80},
        'exited': false,
        'visible_rows': ['flutter-spike ready'],
        'styled_rows': [
          {
            'spans': [
              {
                'text': 'flutter-spike ready',
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
        'cursor': {'row': 0, 'col': 0},
      },
    });
    await tester.pumpAndSettle();

    expect(find.text('Connected to Daemon'), findsOneWidget);

    await tester.tap(find.text('triage / flutter-spike').first);
    await tester.pumpAndSettle();
    expect(find.text('flutter-spike ready'), findsOneWidget);
  });

  testWidgets('buffers output while daemon session placeholder is loading', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    final delayedAttach = Completer<Map<String, dynamic>>();
    client.attachCompleters['flutter-spike'] = delayedAttach;

    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('Loading session flutter-spike...'), findsOneWidget);

    await tester.tap(find.text('triage / main').first);
    await tester.pumpAndSettle();
    expect(find.text('line 1 from main'), findsOneWidget);

    client.emitOutput(
      'flutter-spike',
      '\nlive output during attach',
      outputSeq: 7,
    );
    await tester.pump();

    delayedAttach.complete(
      client.attachSnapshotResponse('flutter-spike', [
        'flutter-spike attached',
      ]),
    );
    await tester.pumpAndSettle();

    final delayedRefresh = Completer<Map<String, dynamic>>();
    client.attachCompleters['flutter-spike'] = delayedRefresh;
    await tester.tap(find.text('triage / flutter-spike').first);
    await tester.pump();

    // Before the post-select refresh resolves, fallback rows only show the
    // attach snapshot. Live output is held in xterm (not rendered in this
    // FLUTTER_TEST fallback path) and lands in session.rows when the daemon
    // snapshot refresh below catches up.
    expect(find.text('flutter-spike attached'), findsOneWidget);
    expect(find.text('live output during attach'), findsNothing);

    delayedRefresh.complete(
      client.attachSnapshotResponse('flutter-spike', [
        'flutter-spike attached',
        'live output during attach',
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('live output during attach'), findsOneWidget);
  });

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

  testWidgets(
    'restores historical sessions using authentic saved size when available',
    (WidgetTester tester) async {
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
    },
  );

  testWidgets(
    'restores historical sessions using estimated viewport size when saved size is absent',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final client = FakeTriageWebSocketClient(exitedSessionIds: {'main'});
      client.snapshotCompleters['main'] = Completer<Map<String, dynamic>>()
        ..complete({
          'snapshot': {
            'context': {'branch': 'main'},
            'exited': true,
            'size': null,
          },
        });

      await tester.pumpWidget(TriageClientApp(client: client));
      await tester.pumpAndSettle();

      expect(client.restoreSessionCalls, contains('main'));
      expect(client.restoreSessionSizes['main'], '84x38');
    },
  );

  testWidgets('resizes selected live history before initial replay', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final client = FakeTriageWebSocketClient();
    client.snapshotVisibleRows['flutter-spike'] = [
      '                                        Welcome to Ubuntu 26.04 LTS (GNU/Linux 6.6.114.1-microso',
      'ft-standard-WSL2 x86_64)',
      '',
      r'dberrios@rogflowz13:/mnt/c/Users/iamst$',
    ];
    client.resizedVisibleRows['flutter-spike'] = [
      'Welcome to Ubuntu 26.04 LTS (GNU/Linux 6.6.114.1-microsoft-standard-WSL2 x86_64)',
      '',
      r'dberrios@rogflowz13:/mnt/c/Users/iamst$',
    ];

    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(
      client.resizeSessionCalls.where((call) => call == 'flutter-spike:84:38'),
      isNotEmpty,
    );
    expect(
      find.text(
        'Welcome to Ubuntu 26.04 LTS (GNU/Linux 6.6.114.1-microsoft-standard-WSL2 x86_64)',
      ),
      findsOneWidget,
    );
    expect(find.text('ft-standard-WSL2 x86_64)'), findsNothing);
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

      expect(find.text('main refreshed'), findsOneWidget);
    },
  );

  testWidgets('creates a scratch session over WebSocket', (
    WidgetTester tester,
  ) async {
    await withPlatform(TargetPlatform.windows, () async {
      final client = FakeTriageWebSocketClient();
      await tester.pumpWidget(TriageClientApp(client: client));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New session'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          CheckedPopupMenuItem<NewSessionShell>,
          'Cmd (cmd.exe)',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('triage / scratch-1'), findsWidgets);
      expect(find.text('line 1 from scratch-1'), findsOneWidget);
      expect(client.startSessionCommands, ['cmd.exe']);
      expect(
        client.attachSessionCalls.where((sid) => sid == 'scratch-1'),
        hasLength(2),
      );
    });
  });

  testWidgets('creates a default shell session directly on macOS', (
    WidgetTester tester,
  ) async {
    await withPlatform(TargetPlatform.macOS, () async {
      final client = FakeTriageWebSocketClient();
      await tester.pumpWidget(TriageClientApp(client: client));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New session'));
      await tester.pumpAndSettle();

      expect(find.byType(CheckedPopupMenuItem<NewSessionShell>), findsNothing);
      expect(find.text('triage / scratch-1'), findsWidgets);
      expect(client.startSessionCommands, ['/bin/sh']);
      expect(client.startSessionArgs, [
        ['-lc', 'exec "\${SHELL:-/bin/sh}"'],
      ]);
    });
  });

  testWidgets('creates a bash session from the plus menu', (
    WidgetTester tester,
  ) async {
    await withPlatform(TargetPlatform.windows, () async {
      final client = FakeTriageWebSocketClient();
      await tester.pumpWidget(TriageClientApp(client: client));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New session'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          CheckedPopupMenuItem<NewSessionShell>,
          'Bash (bash)',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('triage / scratch-1'), findsWidgets);
      expect(client.startSessionCommands, ['bash']);
    });
  });

  testWidgets('falls back to bash when cmd shell is unavailable', (
    WidgetTester tester,
  ) async {
    await withPlatform(TargetPlatform.windows, () async {
      final client = FakeTriageWebSocketClient(
        failedStartSessionCommands: {'cmd.exe'},
      );
      await tester.pumpWidget(TriageClientApp(client: client));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New session'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          CheckedPopupMenuItem<NewSessionShell>,
          'Cmd (cmd.exe)',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('triage / scratch-1'), findsWidgets);
      expect(find.text('line 1 from scratch-1'), findsOneWidget);
      expect(client.startSessionCommands, ['cmd.exe', 'bash']);
    });
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

  testWidgets('drops in-memory token when site data is cleared while running', (
    WidgetTester tester,
  ) async {
    clearToken();
    clearClientId();
    addTearDown(() {
      clearToken();
      clearClientId();
    });

    persistClientId('triage-flutter-client-stored');
    persistToken('stored-token');
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(client.helloClientIds.single, 'triage-flutter-client-stored');
    expect(client.helloTokens.single, 'stored-token');
    expect(find.text('Connected to Daemon'), findsOneWidget);

    clearToken();
    clearClientId();
    client.authenticated = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(client.helloTokens.last, isNull);
    expect(retrieveClientId(), 'triage-flutter-client-stored');
    expect(find.text('Pair Remote Device'), findsOneWidget);
    expect(
      client.pairingChallengeClientIds.last,
      'triage-flutter-client-stored',
    );
  });

  testWidgets('shows device-specific pairing challenge when unauthenticated', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient(authenticated: false);
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('Pair Remote Device'), findsOneWidget);
    expect(find.text('ABCD1234'), findsOneWidget);
    expect(
      find.textContaining('localhost:8080/pair', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('device_code=ABCD1234', findRichText: true),
      findsOneWidget,
    );
    expect(find.byTooltip('Open verification URL'), findsOneWidget);
    expect(find.byTooltip('Copy device code'), findsOneWidget);
    expect(client.pairingChallengeClientIds, client.helloClientIds);

    await tester.enterText(find.byType(TextField), 'WXYZ9876');
    await tester.tap(find.text('Pair Device'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(client.pairCodes, ['WXYZ9876']);
    expect(client.helloClientIds.length, 2);
    expect(find.text('Pair Remote Device'), findsNothing);
  });

  testWidgets('does not show non-local pairing URL when unauthenticated', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient(
      uri: Uri.parse('ws://192.168.1.10:7777/ws'),
      authenticated: false,
    );
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('Pair Remote Device'), findsOneWidget);
    expect(find.text('ABCD1234'), findsOneWidget);
    expect(find.text('Local approval required'), findsOneWidget);
    expect(find.textContaining('triage pair'), findsOneWidget);
    expect(
      find.textContaining('192.168.1.10:7777/pair', findRichText: true),
      findsNothing,
    );
  });

  testWidgets('clears pairing challenge loading when disconnected', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient(
      authenticated: false,
      disconnectAfterHello: true,
    );
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(find.text('Pair Remote Device'), findsOneWidget);
    expect(
      find.textContaining('Connection closed before the pairing challenge'),
      findsOneWidget,
    );
    expect(client.pairingChallengeClientIds, isEmpty);
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
