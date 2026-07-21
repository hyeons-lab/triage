import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart'
    show CheckedPopupMenuItem, Icons, MaterialApp, Scaffold, TextField;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:triage_client/main.dart';
import 'package:triage_client/models/daemon_server.dart';
import 'package:triage_client/services/server_store.dart';
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
    Set<String>? emptyIdStartSessionCommands,
  }) : exitedSessionIds = {...?exitedSessionIds},
       failedStartSessionCommands = {...?failedStartSessionCommands},
       emptyIdStartSessionCommands = {...?emptyIdStartSessionCommands},
       super(uri ?? Uri.parse('ws://localhost:8080/ws'));

  final bool shouldFailConnection;
  int failConnectAttempts;
  Completer<void>? hangConnect;
  bool listSessionsUnauthorized = false;
  bool authenticated;
  // When set, `hello` authenticates only these tokens — which is how a test
  // gives two daemons genuinely different credentials, rather than one global
  // yes/no.
  Set<String>? acceptTokens;
  final bool disconnectAfterHello;
  final Set<String> exitedSessionIds;
  final Set<String> failedStartSessionCommands;
  // Commands the daemon answers without a `session_id` — the response shape
  // `startSession` degrades to ''. Distinct from an outright throw.
  final Set<String> emptyIdStartSessionCommands;

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

  int connectCalls = 0;

  @override
  Future<void> connect() async {
    connectCalls += 1;
    final hang = hangConnect;
    if (hang != null && !hang.isCompleted) {
      // Simulates a half-open socket: the handshake sits pending until the
      // client's connect timeout fires (the test completes it with an error).
      await hang.future;
    }
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
    final accepted = acceptTokens;
    final isAuthenticated = accepted == null
        ? authenticated
        : token != null && accepted.contains(token);
    return {'protocol_version': '2026-05-20', 'authenticated': isAuthenticated};
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
    if (listSessionsUnauthorized) {
      throw TriageAuthException('unauthorized');
    }
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
    if (emptyIdStartSessionCommands.contains(command)) {
      return '';
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

  test('new-session fallback chain covers every shell, preferred first', () {
    // A client's platform says nothing about the daemon's, so each starting
    // point must still be able to reach the shells the other OS provides —
    // notably `defaultPosix` (an Android/Mac client) reaching `cmd`, which is
    // the only thing that spawns on a Windows daemon.
    for (final preferred in NewSessionShell.values) {
      final chain = newSessionShellFallbackChain(preferred);
      expect(chain.first, preferred);
      expect(chain.toSet(), NewSessionShell.values.toSet());
      expect(chain, hasLength(NewSessionShell.values.length));
    }
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

  test('uses same-origin websocket target behind a TLS reverse proxy', () {
    // A proxy terminating TLS on 443 is the only way to reach the daemon, so
    // the origin must win even though the port is not the daemon default.
    // Falling back to loopback here would both miss the daemon and be blocked
    // as mixed content from an https page.
    expect(
      defaultWebSocketUriForBase(Uri.parse('https://triage.example.test/')),
      Uri.parse('wss://triage.example.test:443/ws'),
    );
  });

  test('websocket target is rooted, so a subpath mount is not supported', () {
    // `/ws` is served at the origin root by the daemon, so the base path is
    // intentionally discarded. Asserted rather than left implicit: a proxy
    // mounting the client under a subpath would need `/app/ws`, and this is
    // the line that would have to change to support it.
    expect(
      defaultWebSocketUriForBase(Uri.parse('https://triage.example.test/app/')),
      Uri.parse('wss://triage.example.test:443/ws'),
    );
  });

  test('uses same-origin websocket target for a non-default daemon port', () {
    expect(
      defaultWebSocketUriForBase(Uri.parse('http://triage.example.test:9000/')),
      Uri.parse('ws://triage.example.test:9000/ws'),
    );
  });

  test('treats a loopback origin on a non-daemon port as the dev server', () {
    // Bracketed IPv6 is included because that is how the origin is *written*,
    // though `Uri.host` hands the predicate the unbracketed form. The rest are
    // spellings a browser or local tool can genuinely produce, including
    // 127.0.0.0/8 addresses other than 127.0.0.1.
    for (final host in [
      'localhost',
      '127.0.0.1',
      '127.0.0.2',
      '[::1]',
      '[0:0:0:0:0:0:0:1]',
    ]) {
      expect(
        defaultWebSocketUriForBase(Uri.parse('http://$host:8080/')),
        Uri.parse('ws://127.0.0.1:7777/ws'),
        reason: 'loopback host $host on 8080 should fall back to the daemon',
      );
    }

    // Bracketed in the URL, unbracketed once `Uri.host` has parsed it. Kept
    // separate from the loop because the two spellings differ.
    expect(
      defaultWebSocketUriForBase(Uri.parse('http://[::ffff:127.0.0.1]:8080/')),
      Uri.parse('ws://127.0.0.1:7777/ws'),
    );
  });

  test('a DNS name merely starting with "127." is not loopback', () {
    // `127.example.com` is a legal hostname — only the final label is barred
    // from being all-numeric. A prefix test would treat it as the dev server
    // and dial loopback, missing the daemon and tripping mixed-content
    // blocking from an https page.
    expect(
      defaultWebSocketUriForBase(Uri.parse('https://127.example.com/')),
      Uri.parse('wss://127.example.com:443/ws'),
    );
    expect(
      defaultWebSocketUriForBase(Uri.parse('https://127.0.0.1.evil.com/')),
      Uri.parse('wss://127.0.0.1.evil.com:443/ws'),
    );
  });

  test('octets must be plain decimal, not hex or signed', () {
    // `int.tryParse` accepts '0x7f', '+127' and surrounding whitespace with no
    // radix argument, so a digits-only match guards the octets. `0x1` is not
    // all-numeric, so `0x7f.0.0.0x1` is a legal DNS name a host could resolve.
    for (final host in ['0x7f.0.0.0x1', '0x7f.0.0.1']) {
      expect(
        defaultWebSocketUriForBase(Uri.parse('https://$host/')),
        Uri.parse('wss://$host:443/ws'),
        reason: '$host is a DNS name, not an IPv4 loopback literal',
      );
    }
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
    // The branch 'main' now renders both in the side-rail tile's git-context
    // row and in the workspace header, so expect at least one match.
    expect(find.text('main'), findsAtLeastNWidgets(1));

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

  testWidgets('opening a historical session fits it to the current viewport', (
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

    // Lazy-load: a non-selected exited session restores when opened, not on
    // connect. Opening it lays out its pane, which fits to the current
    // viewport (84x38 here) — so the session shows at the current device's
    // size, superseding the size it was persisted at. This is what we want
    // for the multi-device case (fit my screen, not the other device's).
    await tester.tap(find.text('triage / main').first);
    await tester.pumpAndSettle();

    expect(client.restoreSessionCalls, contains('main'));
    expect(client.restoreSessionSizes['main'], '84x38');
  });

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

      // Lazy-load: a non-selected exited session restores when opened, not on
      // connect (only the initially-selected session loads eagerly).
      await tester.tap(find.text('triage / main').first);
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

  testWidgets('redraws the active session when resuming after occlusion', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    int resizesFor(String sid) =>
        client.resizeSessionCalls.where((c) => c.startsWith('$sid:')).length;
    // 'flutter-spike' is the default-selected remote session.
    final baseline = resizesFor('flutter-spike');

    // Merely losing and regaining focus (inactive, no occlusion) must NOT
    // redraw — otherwise we'd jiggle the PTY on every desktop focus change.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(resizesFor('flutter-spike'), baseline);

    // Full occlusion (screen sleep / hidden) then resume jiggles the host PTY
    // size (rows-1, then back) so the program repaints over the live stream at
    // our width — the same heal a manual resize triggers, with no history replay.
    // Desktop walks through `inactive` on the way down and back up.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    // Two resizes: the jiggle down to rows-1 and back to the real size.
    expect(resizesFor('flutter-spike'), baseline + 2);
  });

  testWidgets('refocuses the active session when resuming after occlusion', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    // The terminal pane refocuses its view whenever `focusCursorRevision`
    // changes (see TerminalPane.didUpdateWidget); the real FocusNode lives on
    // the xterm view, which is stubbed out under FLUTTER_TEST, so we assert on
    // that revision — the contract the fix relies on — rather than raw focus.
    int revision() => tester
        .widget<TerminalPane>(find.byType(TerminalPane))
        .focusCursorRevision;
    final baseline = revision();

    // A bare inactive→resumed cycle (desktop focus change, no occlusion) must
    // NOT refocus — otherwise we'd steal focus on every app switch.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(revision(), baseline);

    // Full occlusion (hidden) then resume bumps the revision so the pane
    // re-requests focus and the session accepts input again without a manual
    // session switch. Desktop walks through `inactive` on the way down and up.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(revision(), greaterThan(baseline));
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
      // One attach on create. The host re-sync (a second attach) is now
      // deferred to the terminal view's first fit, which the headless test
      // fallback (a plain Container, not a TerminalView) never triggers; the
      // fit-driven re-sync is covered by the select-refresh test above.
      expect(
        client.attachSessionCalls.where((sid) => sid == 'scratch-1'),
        hasLength(1),
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

  testWidgets('a mobile client reaches a Windows daemon shell', (
    WidgetTester tester,
  ) async {
    // The regression this fixes: an Android client only ever offers
    // `defaultPosix`, and `/bin/sh` cannot spawn on a Windows daemon. With no
    // shell menu on mobile there is no way to pick another by hand, so the
    // chain has to reach `cmd.exe` on its own.
    await withPlatform(TargetPlatform.android, () async {
      final client = FakeTriageWebSocketClient(
        failedStartSessionCommands: {'/bin/sh'},
      );
      await tester.pumpWidget(TriageClientApp(client: client));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New session'));
      await tester.pumpAndSettle();

      expect(find.text('triage / scratch-1'), findsWidgets);
      expect(client.startSessionCommands, ['/bin/sh', 'cmd.exe']);
    });
  });

  testWidgets('a session id-less response falls through to the next shell', (
    WidgetTester tester,
  ) async {
    // A response carrying no `session_id` degrades to '' rather than throwing.
    // Breaking out of the chain on it would leave nothing to subscribe or
    // attach to and strand the rail on "Creating session...".
    await withPlatform(TargetPlatform.windows, () async {
      final client = FakeTriageWebSocketClient(
        emptyIdStartSessionCommands: {'cmd.exe'},
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

      expect(client.startSessionCommands, ['cmd.exe', 'bash']);
      expect(find.text('triage / scratch-1'), findsWidgets);
      expect(find.text('Creating session...'), findsNothing);
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

    // Tap the close button, then confirm in the dialog (closing a session
    // requires confirmation).
    await tester.tap(find.byTooltip('Close session'));
    await tester.pumpAndSettle();
    // The confirm dialog's button is the only 'Close session' Text (the icon
    // button uses a tooltip; the dialog title is 'Close session?').
    await tester.tap(find.text('Close session'));
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
    clearTokenFor(unconfiguredServerId);
    clearClientId();
    addTearDown(() {
      clearTokenFor(unconfiguredServerId);
      clearClientId();
    });

    persistClientId('triage-flutter-client-stored');
    persistTokenFor(unconfiguredServerId, 'stored-token');
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(client.helloClientIds.single, 'triage-flutter-client-stored');
    expect(client.helloTokens.single, 'stored-token');
    expect(find.text('Connected to Daemon'), findsOneWidget);

    clearTokenFor(unconfiguredServerId);
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

  testWidgets('a DNS name starting with "127." is not treated as local', (
    WidgetTester tester,
  ) async {
    // The pairing URL is only offered for a daemon on this machine, because a
    // remote user's browser cannot usefully open it. `127.0.0.1.evil.com` is a
    // legal, resolvable DNS name, and a `startsWith('127.')` host test would
    // present it as local — rendering an attacker-controlled URL as a trusted
    // "Verification URL" button carrying the device code.
    final client = FakeTriageWebSocketClient(
      uri: Uri.parse('ws://127.0.0.1.evil.com:7777/ws'),
      authenticated: false,
    );
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('Local approval required'), findsOneWidget);
    expect(
      find.textContaining('127.0.0.1.evil.com', findRichText: true),
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

  testWidgets('a token rejected while loading sessions routes to pairing', (
    WidgetTester tester,
  ) async {
    final client = FakeTriageWebSocketClient()..listSessionsUnauthorized = true;
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    // `hello` succeeded, so the app believed it was connected — then the daemon
    // refused `list_sessions` because the token is no longer valid for this
    // client id. Swallowing that (as the blanket `catch (_)` did) left the app
    // sitting on "Connected to Daemon" with no sessions and no way to re-pair.
    expect(find.text('Pair Remote Device'), findsOneWidget);
  });

  testWidgets('a connect requested during an in-flight connect is not dropped', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = FakeTriageWebSocketClient()..hangConnect = Completer<void>();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pump();
    expect(
      client.helloClientIds,
      isEmpty,
      reason: 'first connect is in flight',
    );

    // The user points the app at a different daemon while that connect is still
    // pending. The in-flight attempt is talking to the *old* address, so it
    // cannot satisfy this request.
    await tester.tap(find.byTooltip('Daemons'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'otherhost:7777');
    await tester.tap(find.text('Add'));
    await tester.pump();

    // The in-flight connect now succeeds — so no failure, and no backoff timer,
    // will come along to retry on the request's behalf. It has to be replayed
    // when the attempt settles, or the app silently stays on the old daemon.
    client.hangConnect!.complete();
    await tester.pump();
    await tester.pump();

    // Two connects: the one that was in flight, and the replay for the daemon
    // the user actually asked for. A dropped request would leave this at one.
    // (The first attempt is retired before its `hello` — it belongs to the
    // daemon we left — so the hello count is not what proves the replay ran.)
    expect(client.connectCalls, 2);
  });

  testWidgets('drag-reordering the rail persists a per-device session order', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = FakeTriageWebSocketClient();
    await tester.pumpWidget(TriageClientApp(client: client));
    await tester.pumpAndSettle();

    // Drag the last session ('triage / main') up to the top of the rail.
    final main = find.text('triage / main');
    expect(main, findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(main));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveBy(const Offset(0, -260));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    // The new order is persisted — under this server's key, since session ids
    // are daemon-local and one global list would let another daemon's order
    // overwrite this one's.
    final prefs = await SharedPreferences.getInstance();
    final order = prefs.getStringList(
      sessionOrderPrefKeyFor(unconfiguredServerId),
    );
    expect(order, isNotNull);
    expect(order, contains('main'));
    expect(order!.last, isNot('main'));
  });

  testWidgets(
    'session tile shows git context row and reveals detail popover on hover',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                child: SessionListTile(
                  title: 'triage / abc',
                  subtitle: 'attached',
                  statusColor: const Color(0xff7fd1c7),
                  icon: Icons.terminal,
                  repoName: 'triage',
                  branch: 'feat/side-rail-glance',
                  worktreeName: 'side-rail-glance',
                  snippet: 'running cargo test',
                  snippetDetail: 'Running the daemon test suite; all green.',
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Glance row combines repo, branch and worktree on one line.
      expect(
        find.text('triage  ·  feat/side-rail-glance  ·  side-rail-glance'),
        findsOneWidget,
      );
      // The detail summary is not shown until hover.
      expect(
        find.text('Running the daemon test suite; all green.'),
        findsNothing,
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(SessionListTile)));
      await tester.pumpAndSettle();

      expect(
        find.text('Running the daemon test suite; all green.'),
        findsOneWidget,
      );

      // Moving away dismisses the popover.
      await gesture.moveTo(const Offset(1000, 1000));
      await tester.pumpAndSettle();
      expect(
        find.text('Running the daemon test suite; all green.'),
        findsNothing,
      );
    },
  );

  group('parseDaemonAddress', () {
    test('bare host or IPv4 -> ws://host:7777/ws', () {
      expect(
        parseDaemonAddress('100.64.2.7').toString(),
        'ws://100.64.2.7:7777/ws',
      );
      expect(
        parseDaemonAddress('  my-mac.tailnet  ').toString(),
        'ws://my-mac.tailnet:7777/ws',
      );
    });

    test('host:port keeps the port', () {
      expect(
        parseDaemonAddress('192.168.1.5:7777').toString(),
        'ws://192.168.1.5:7777/ws',
      );
      expect(
        parseDaemonAddress('host.local:9000').toString(),
        'ws://host.local:9000/ws',
      );
    });

    test('full URLs normalize scheme/port/path', () {
      expect(parseDaemonAddress('ws://h:7777/ws').toString(), 'ws://h:7777/ws');
      expect(
        parseDaemonAddress('wss://my-mac.tailnet:7777').toString(),
        'wss://my-mac.tailnet:7777/ws',
      );
      expect(parseDaemonAddress('http://h').toString(), 'ws://h:7777/ws');
      expect(
        parseDaemonAddress('https://h:8443/ws').toString(),
        'wss://h:8443/ws',
      );
    });

    test('full URLs preserve query and fragment', () {
      expect(
        parseDaemonAddress('https://host/ws?token=abc123').toString(),
        'wss://host:7777/ws?token=abc123',
      );
      expect(
        parseDaemonAddress('wss://host:8443/path?a=1&b=2#frag').toString(),
        'wss://host:8443/path?a=1&b=2#frag',
      );
    });

    test('bracketed IPv6 literal', () {
      expect(parseDaemonAddress('[::1]:7777').toString(), 'ws://[::1]:7777/ws');
    });

    test('invalid input -> null', () {
      expect(parseDaemonAddress(''), isNull);
      expect(parseDaemonAddress('   '), isNull);
      expect(parseDaemonAddress('host:notaport'), isNull);
      expect(parseDaemonAddress('host:99999'), isNull);
      expect(parseDaemonAddress('ftp://host'), isNull);
    });
  });

  testWidgets('first run shows the connection screen when no address is set', (
    WidgetTester tester,
  ) async {
    // No injected client and no saved address → the app must prompt for a host
    // instead of auto-connecting.
    await tester.pumpWidget(const TriageClientApp());
    await tester.pumpAndSettle();

    expect(find.text('Connect to a Triage daemon'), findsOneWidget);
    expect(find.text('Daemon address'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('connection form validates input and submits the raw address', (
    WidgetTester tester,
  ) async {
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionSettingsForm(
            onSubmit: (raw, label) => submitted = raw,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final addressField = find.byType(TextField).first;
    await tester.enterText(addressField, 'myhost:abc');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Enter a valid host, host:port, or ws://, wss://, http://, or https:// URL.',
      ),
      findsOneWidget,
    );
    expect(submitted, isNull);

    await tester.enterText(addressField, '192.168.1.5:7777');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(submitted, '192.168.1.5:7777');
  });

  group('multi-daemon switcher', () {
    const workLaptop = DaemonServer(
      id: 'server-work',
      label: 'Work laptop',
      address: 'work.tailnet:7777',
    );
    const homeMac = DaemonServer(
      id: 'server-home',
      label: 'Home mac',
      address: 'home.tailnet:7777',
    );

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      clearTokenFor(workLaptop.id);
      clearTokenFor(homeMac.id);
      clearClientId();
    });

    tearDown(() {
      clearTokenFor(workLaptop.id);
      clearTokenFor(homeMac.id);
      clearClientId();
    });

    Future<FakeTriageWebSocketClient> pumpWithServers(
      WidgetTester tester, {
      required String selectedId,
    }) async {
      final client = FakeTriageWebSocketClient();
      await tester.pumpWidget(
        TriageClientApp(
          client: client,
          initialServers: ServerConfig(
            servers: const [workLaptop, homeMac],
            selectedId: selectedId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return client;
    }

    testWidgets('the rail names the daemon the sessions belong to', (
      WidgetTester tester,
    ) async {
      await pumpWithServers(tester, selectedId: workLaptop.id);

      // With more than one daemon configured, "Connected to Daemon" alone does
      // not say *which* machine these sessions are on.
      expect(find.text('Work laptop'), findsOneWidget);
      expect(find.text('Connected to Daemon'), findsOneWidget);
    });

    testWidgets('each daemon is paired with its own token', (
      WidgetTester tester,
    ) async {
      persistTokenFor(workLaptop.id, 'work-token');
      persistTokenFor(homeMac.id, 'home-token');

      final client = await pumpWithServers(tester, selectedId: workLaptop.id);
      expect(client.helloTokens.single, 'work-token');

      // Switch to the other daemon.
      await tester.tap(find.byTooltip('Daemons'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Home mac'));
      await tester.pumpAndSettle();

      // The whole point of keying tokens by server: the second daemon is
      // greeted with the token *it* issued, not the first one's, so switching
      // costs no re-pair in either direction.
      expect(client.helloTokens.last, 'home-token');
      expect(find.text('Home mac'), findsOneWidget);

      // And the daemon we left is still paired.
      expect(retrieveTokenFor(workLaptop.id), 'work-token');
    });

    testWidgets('pairing with a daemon does not overwrite the other token', (
      WidgetTester tester,
    ) async {
      persistTokenFor(workLaptop.id, 'work-token');
      // The home mac has never been paired with, so it challenges for a PIN.
      final client = FakeTriageWebSocketClient()..authenticated = false;
      await tester.pumpWidget(
        TriageClientApp(
          client: client,
          initialServers: const ServerConfig(
            servers: [workLaptop, homeMac],
            selectedId: 'server-home',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pair Remote Device'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'WXYZ9876');
      await tester.tap(find.text('Pair Device'));
      await tester.pumpAndSettle();

      expect(retrieveTokenFor(homeMac.id), 'paired-token');
      // Pairing a second daemon must not un-pair the first.
      expect(retrieveTokenFor(workLaptop.id), 'work-token');
    });

    testWidgets('switching mid-connect does not un-pair the incoming daemon', (
      WidgetTester tester,
    ) async {
      persistTokenFor(workLaptop.id, 'work-token');
      persistTokenFor(homeMac.id, 'home-token');

      // The work laptop has revoked our token; the home mac has not.
      final client = FakeTriageWebSocketClient()
        ..acceptTokens = {'home-token'}
        ..hangConnect = Completer<void>();
      await tester.pumpWidget(
        TriageClientApp(
          client: client,
          initialServers: const ServerConfig(
            servers: [workLaptop, homeMac],
            selectedId: 'server-work',
          ),
        ),
      );
      await tester.pump();

      // Switch to the home mac while the work laptop's connect is still pending.
      // Settle so the switch has fully landed (it persists the selection before
      // applying it) — otherwise the stale attempt resolves before the active
      // server has actually changed, and the race under test never happens.
      await tester.tap(find.byTooltip('Daemons'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Home mac'));
      await tester.pumpAndSettle();

      // The work laptop's attempt now lands, and its token is rejected. That
      // attempt belongs to the daemon we just left: if it clears "the active
      // server's" token rather than its own, it wipes the home mac's perfectly
      // good credential and drops us onto a PIN screen for a daemon that never
      // rejected anything.
      client.hangConnect!.complete();
      await tester.pumpAndSettle();

      expect(retrieveTokenFor(homeMac.id), 'home-token');
      expect(find.text('Connected to Daemon'), findsOneWidget);
      expect(find.text('Pair Remote Device'), findsNothing);
    });

    testWidgets('switching daemons does not carry session state across', (
      WidgetTester tester,
    ) async {
      persistTokenFor(workLaptop.id, 'work-token');
      persistTokenFor(homeMac.id, 'home-token');
      final client = await pumpWithServers(tester, selectedId: workLaptop.id);

      // The rail order recorded against the work laptop.
      await tester.drag(find.text('triage / main'), const Offset(0, -260));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      final workOrder = prefs.getStringList(
        sessionOrderPrefKeyFor(workLaptop.id),
      );
      expect(workOrder, isNotNull);

      // Switch to the home mac, holding its connect open so we can inspect the
      // window between daemons.
      client.hangConnect = Completer<void>();
      await tester.tap(find.byTooltip('Daemons'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Home mac'));
      await tester.pumpAndSettle();

      // The work laptop's tiles are gone. Leaving them on screen is what made
      // the whole class of cross-daemon bugs possible: they stay marked
      // `attached` and wired to the client, which now points at the home mac, so
      // a keystroke, a resize, or a drag would be delivered to the home mac
      // under a work-laptop session id — and the ids collide, since both
      // machines have a `main`.
      expect(find.text('triage / main'), findsNothing);

      // So nothing can have been filed under the home mac, and the work laptop's
      // own order is untouched.
      expect(prefs.getStringList(sessionOrderPrefKeyFor(homeMac.id)), isNull);
      expect(
        prefs.getStringList(sessionOrderPrefKeyFor(workLaptop.id)),
        workOrder,
      );

      client.hangConnect!.complete();
      await tester.pumpAndSettle();
      expect(client.helloTokens.last, 'home-token');
      expect(find.text('Connected to Daemon'), findsOneWidget);
    });

    testWidgets('forgetting the last daemon does not dial a phantom one', (
      WidgetTester tester,
    ) async {
      final client = FakeTriageWebSocketClient();
      await tester.pumpWidget(
        TriageClientApp(
          client: client,
          initialServers: const ServerConfig(
            servers: [workLaptop],
            selectedId: 'server-work',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final hellosWhileConnected = client.helloClientIds.length;

      await tester.tap(find.byTooltip('Daemons'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Forget'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();

      expect(find.text('Connect to a Triage daemon'), findsOneWidget);

      // With no daemon left, the resume/wake path must not reconnect. It used to
      // fire on `_clientInitialized` alone and fall back to the page-origin URI —
      // pairing against a localhost daemon the user never added, invisibly,
      // behind the connection screen.
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();

      expect(client.helloClientIds.length, hellosWhileConnected);
    });

    testWidgets('forgetting a daemon clears only its token', (
      WidgetTester tester,
    ) async {
      persistTokenFor(workLaptop.id, 'work-token');
      persistTokenFor(homeMac.id, 'home-token');
      await pumpWithServers(tester, selectedId: workLaptop.id);

      await tester.tap(find.byTooltip('Daemons'));
      await tester.pumpAndSettle();
      // Forget the daemon we are *not* on, so the rail stays put.
      await tester.tap(find.byTooltip('Forget').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();

      // A forgotten daemon's bearer token would otherwise sit in the keychain
      // under an id nothing can reach again.
      expect(retrieveTokenFor(homeMac.id), isNull);
      expect(retrieveTokenFor(workLaptop.id), 'work-token');

      final prefs = await SharedPreferences.getInstance();
      final saved = DaemonServer.decodeList(prefs.getString(serversPrefKey));
      expect(saved.map((s) => s.id), [workLaptop.id]);
    });
  });
}
