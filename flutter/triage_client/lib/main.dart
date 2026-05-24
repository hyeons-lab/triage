import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/widgets/terminal_pane.dart';
import 'package:triage_client/services/storage.dart';

void main() {
  runApp(const TriageClientApp());
}

class TriageClientApp extends StatelessWidget {
  const TriageClientApp({super.key, this.client});

  final TriageWebSocketClient? client;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Triage',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2b6f6f),
          brightness: Brightness.dark,
        ),
        fontFamily: 'Segoe UI',
        scaffoldBackgroundColor: const Color(0xff101416),
      ),
      home: TriageHome(client: client),
    );
  }
}

class SessionVm {
  SessionVm({
    required this.title,
    required this.branch,
    required this.status,
    required this.statusColor,
    required this.icon,
    required this.rows,
    required this.outputSeq,
    this.isRemote = false,
  }) : terminalController = TerminalController();

  final String title;
  final String branch;
  String status;
  Color statusColor;
  final IconData icon;
  final List<StyledRow> rows;
  final TerminalController terminalController;
  int outputSeq;
  final bool isRemote;
}

class TriageHome extends StatefulWidget {
  const TriageHome({super.key, this.client});

  final TriageWebSocketClient? client;

  @override
  State<TriageHome> createState() => _TriageHomeState();
}

class _TriageHomeState extends State<TriageHome> {
  late TriageWebSocketClient _client;
  bool _clientInitialized = false;
  bool _isConnecting = false;
  bool _disposed = false;
  int _connectGeneration = 0;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  StreamSubscription<Map<String, dynamic>>? _websocketSubscription;
  String? _bearerToken;
  bool _needsPairing = false;
  bool _sidebarCollapsed = false;
  String _connectionStatus = 'Offline (Local Mock)';
  Color _connectionStatusColor = const Color(0xff7f8b8d);
  late final String _clientId;
  final Map<String, String> _subscriptionIds = {};
  final Map<String, List<Map<String, dynamic>>> _pendingEvents = {};

  late final List<SessionVm> _sessions;
  int _selectedIndex = 0;
  int _createdSessionCount = 0;

  SessionVm get _selectedSession => _sessions[_selectedIndex];

  StyledRow _plainRow(String text) {
    return StyledRow(
      spans: [StyledSpan(text: text, style: const TerminalStyle())],
    );
  }

  StyledRow _promptRow(String command) {
    return StyledRow(
      spans: [
        const StyledSpan(
          text: r'$ ',
          style: TerminalStyle(
            foreground: TerminalColor(red: 127, green: 209, blue: 199),
            bold: true,
          ),
        ),
        StyledSpan(text: command, style: const TerminalStyle(bold: true)),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _clientId = _loadOrCreateClientId();
    _sessions = [
      SessionVm(
        title: 'triage / flutter-spike',
        branch: 'experiment/flutter-spike',
        status: 'awaiting input',
        statusColor: const Color(0xffffc857),
        icon: Icons.terminal,
        rows: [
          _promptRow('cargo run -p triaged'),
          _plainRow('daemon listening on local session transport'),
          _plainRow(''),
          _promptRow('flutter run -d web-server --no-web-resources-cdn'),
          _plainRow('lib/main.dart is being served at http://127.0.0.1:8080'),
          _plainRow(''),
          _plainRow('awaiting input: define TerminalPane bridge boundary'),
        ],
        outputSeq: 0,
      ),
      SessionVm(
        title: 'triage / websocket-session-api',
        branch: 'feat/websocket-session-api',
        status: 'running cargo test',
        statusColor: const Color(0xff7fd1c7),
        icon: Icons.sync,
        rows: [
          _promptRow('cargo test -p triage-transport-ws'),
          _plainRow('test protocol::tests::subscribe_streams_events ... ok'),
          _plainRow('test protocol::tests::invalid_json_returns_error ... ok'),
          _plainRow(''),
          _plainRow('running: websocket integration notes'),
        ],
        outputSeq: 0,
      ),
      SessionVm(
        title: 'triage / main',
        branch: 'main',
        status: 'idle',
        statusColor: const Color(0xff7f8b8d),
        icon: Icons.pause_circle_outline,
        rows: [
          _promptRow('git status --short --branch'),
          _plainRow('## main...origin/main'),
          _plainRow(''),
          _plainRow('idle'),
        ],
        outputSeq: 0,
      ),
    ];
    for (final s in _sessions) {
      _setupSessionInputListener(s);
    }
    _connectWebSocket();
  }

  String _loadOrCreateClientId() {
    final storedClientId = retrieveClientId();
    if (storedClientId != null && storedClientId.trim().isNotEmpty) {
      return storedClientId;
    }

    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final clientId = 'triage-flutter-client-$suffix';
    persistClientId(clientId);
    return clientId;
  }

  bool _isRemoteSession(SessionVm session) {
    return session.isRemote;
  }

  void _markRemoteSessionDisconnected(SessionVm session) {
    if (session.status == 'disconnected') return;
    setState(() {
      session.status = 'disconnected';
      session.statusColor = const Color(0xffff6b6b);
      _connectionStatus = 'Connection Closed';
      _connectionStatusColor = const Color(0xff7f8b8d);
    });
  }

  void _markAttachedSessionsDisconnected() {
    for (final session in _sessions) {
      if (session.status == 'attached') {
        session.status = 'disconnected';
        session.statusColor = const Color(0xffff6b6b);
      }
    }
  }

  void _setupSessionInputListener(SessionVm session) {
    session.terminalController.addInputListener((keys) {
      if (_isRemoteSession(session)) {
        if (session.status != 'attached') {
          return;
        }

        if (!_client.isConnected) {
          _markRemoteSessionDisconnected(session);
          return;
        }

        final parts = session.title.split(' / ');
        final sessionId = parts.length > 1 ? parts[1] : null;
        if (sessionId != null) {
          _client
              .writeInput(
                sessionId: sessionId,
                clientId: _clientId,
                bytes: utf8.encode(keys),
              )
              .catchError((_) {
                _markRemoteSessionDisconnected(session);
              });
        }
      } else {
        setState(() {
          if (keys == '\r') {
            session.rows.add(_plainRow(''));
            session.terminalController.write('\r\n');
          } else if (keys == '\x7f' || keys == '\x08') {
            if (session.rows.isNotEmpty && session.rows.last.spans.isNotEmpty) {
              final text = session.rows.last.spans.last.text;
              if (text.isNotEmpty) {
                final newText = text.substring(0, text.length - 1);
                final lastIndex = session.rows.last.spans.length - 1;
                session.rows.last.spans[lastIndex] = StyledSpan(
                  text: newText,
                  style: session.rows.last.spans.last.style,
                );
                session.terminalController.write('\x08 \x08');
              }
            }
          } else {
            if (session.rows.isEmpty) {
              session.rows.add(_plainRow(''));
            }
            session.rows.last.spans.add(
              StyledSpan(text: keys, style: const TerminalStyle()),
            );
            session.terminalController.write(keys);
          }
        });
      }
    });

    session.terminalController.addResizeOutListener((cols, rows) {
      if (_client.isConnected && session.status == 'attached') {
        final parts = session.title.split(' / ');
        final sessionId = parts.length > 1 ? parts[1] : null;
        if (sessionId != null) {
          _client
              .resizeSession(sessionId: sessionId, cols: cols, rows: rows)
              .catchError((_) => <String, dynamic>{});
        }
      }
    });
  }

  Duration _nextReconnectDelay() {
    final seconds = 1 << _reconnectAttempt.clamp(0, 4);
    _reconnectAttempt += 1;
    return Duration(seconds: seconds);
  }

  void _scheduleReconnect() {
    if (_disposed || _needsPairing || _reconnectTimer?.isActive == true) {
      return;
    }

    final delay = _nextReconnectDelay();
    setState(() {
      _connectionStatus = 'Reconnecting...';
      _connectionStatusColor = const Color(0xffffc857);
      _markAttachedSessionsDisconnected();
    });
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _connectWebSocket(isReconnect: true);
    });
  }

  void _connectWebSocket({bool isReconnect = false}) async {
    if (_disposed || _isConnecting) return;
    _isConnecting = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final generation = ++_connectGeneration;
    _bearerToken ??= retrieveToken();
    if (_clientInitialized) {
      try {
        await _client.disconnect();
      } catch (_) {}
      try {
        await _websocketSubscription?.cancel();
      } catch (_) {}
    }

    if (_disposed || generation != _connectGeneration) {
      _isConnecting = false;
      return;
    }

    final client =
        widget.client ??
        TriageWebSocketClient(Uri.parse('ws://127.0.0.1:7777/ws'));
    _client = client;
    _clientInitialized = true;

    setState(() {
      _connectionStatus = 'Connecting...';
      _connectionStatusColor = const Color(0xffffc857);
    });

    try {
      await _client.connect();

      if (_disposed || generation != _connectGeneration) {
        await _client.disconnect();
        _isConnecting = false;
        return;
      }

      _websocketSubscription = _client.events.listen(
        _onWebSocketEvent,
        onError: (error) => _onWebSocketError(error, generation),
        onDone: () => _onWebSocketClosed(generation),
      );

      final helloRes = await _client.hello(
        clientId: _clientId,
        token: _bearerToken,
      );
      final authenticated = helloRes['authenticated'] as bool? ?? false;

      if (_disposed || generation != _connectGeneration) {
        _isConnecting = false;
        return;
      }

      if (!authenticated) {
        setState(() {
          _needsPairing = true;
          _connectionStatus = 'Awaiting Pairing';
          _connectionStatusColor = const Color(0xffffc857);
        });
        _isConnecting = false;
        return;
      }

      setState(() {
        _needsPairing = false;
        _connectionStatus = 'Connected to Daemon';
        _connectionStatusColor = const Color(0xff7fd1c7);
      });

      await _loadDaemonSessions();
      _reconnectAttempt = 0;
    } catch (e) {
      if (_disposed || generation != _connectGeneration) {
        _isConnecting = false;
        return;
      }
      final errStr = e.toString();
      if (errStr.contains('unauthorized') ||
          errStr.contains('unauthenticated')) {
        setState(() {
          _needsPairing = true;
          _connectionStatus = 'Awaiting Pairing';
          _connectionStatusColor = const Color(0xffffc857);
        });
      } else {
        setState(() {
          _connectionStatus = isReconnect
              ? 'Reconnect Failed'
              : 'Offline (Local Mock)';
          _connectionStatusColor = const Color(0xff7f8b8d);
          _markAttachedSessionsDisconnected();
        });
        _scheduleReconnect();
      }
    } finally {
      if (generation == _connectGeneration) {
        _isConnecting = false;
      }
    }
  }

  Future<void> _onPairRequested(String pin) async {
    final token = await _client.pair(code: pin, clientId: _clientId);
    if (token.isNotEmpty) {
      setState(() {
        _bearerToken = token;
        persistToken(token);
      });
      _reconnectAttempt = 0;
      _connectWebSocket();
    } else {
      throw Exception('Server returned empty pairing token');
    }
  }

  Future<void> _loadDaemonSessions() async {
    if (!_client.isConnected) return;

    try {
      final sessionIds = await _client.listSessions();
      final List<SessionVm> daemonSessions = [];

      for (final sid in sessionIds) {
        String? subId;
        try {
          // Subscribe to events first so we don't miss anything printed during attach
          subId = await _client.subscribeSessionEvents(sessionId: sid);
          if (subId.isNotEmpty) {
            _subscriptionIds[subId] = sid;
          }

          final attachRes = await _client.attachSession(
            sessionId: sid,
            clientId: _clientId,
            mode: 'InteractiveController',
          );
          final responseObj = attachRes['response'] as Map<String, dynamic>?;
          final snapshot = responseObj?['snapshot'] as Map<String, dynamic>?;

          final contextObj = snapshot?['context'] as Map<String, dynamic>?;
          final branch = contextObj?['branch']?.toString() ?? 'main';

          final visibleRowsJson = snapshot?['visible_rows'] as List<dynamic>?;
          final styledRowsJson = snapshot?['styled_rows'] as List<dynamic>?;
          final styledRows =
              styledRowsJson
                  ?.map((e) => StyledRow.fromJson(e as Map<String, dynamic>))
                  .toList() ??
              [];

          final List<StyledRow> rows = [];
          if (visibleRowsJson != null) {
            final visibleRows = visibleRowsJson.cast<String>();
            final styledRowsStart = visibleRows.length - styledRows.length;
            if (styledRowsStart > 0) {
              try {
                final historyRes = await _client.styledRows(
                  sessionId: sid,
                  start: 0,
                  end: visibleRows.length,
                );
                final responseObj =
                    historyRes['response'] as Map<String, dynamic>?;
                final rowsList = responseObj?['rows'] as List<dynamic>?;
                if (rowsList != null) {
                  rows.addAll(
                    rowsList.map(
                      (e) => StyledRow.fromJson(e as Map<String, dynamic>),
                    ),
                  );
                } else {
                  for (var i = 0; i < visibleRows.length; i++) {
                    if (i < styledRowsStart) {
                      rows.add(_plainRow(visibleRows[i]));
                    } else {
                      rows.add(styledRows[i - styledRowsStart]);
                    }
                  }
                }
              } catch (_) {
                for (var i = 0; i < visibleRows.length; i++) {
                  if (i < styledRowsStart) {
                    rows.add(_plainRow(visibleRows[i]));
                  } else {
                    rows.add(styledRows[i - styledRowsStart]);
                  }
                }
              }
            } else {
              rows.addAll(styledRows);
            }
          } else {
            rows.addAll(styledRows);
          }

          final session = SessionVm(
            title: 'triage / $sid',
            branch: branch,
            status: 'attached',
            statusColor: const Color(0xff7fd1c7),
            icon: Icons.terminal,
            rows: rows.isEmpty ? [_plainRow('Attached to session $sid')] : rows,
            outputSeq: snapshot?['output_seq'] as int? ?? 0,
            isRemote: true,
          );
          _setupSessionInputListener(session);
          daemonSessions.add(session);
        } catch (e) {
          // Roll back the subscription bookkeeping and drop any events buffered
          // for a session we will never expose, so they don't accumulate forever.
          if (subId != null && subId.isNotEmpty) {
            _subscriptionIds.remove(subId);
          }
          _pendingEvents.remove(sid);
          debugPrint('Failed to load session $sid: ${e.toString()}');
        }
      }

      setState(() {
        for (final s in _sessions) {
          s.terminalController.dispose();
          TerminalPane.destroySession(s.title);
        }
        _sessions.clear();
        _sessions.addAll(daemonSessions);
        if (_selectedIndex >= _sessions.length) {
          _selectedIndex = _sessions.isEmpty ? 0 : _sessions.length - 1;
        }
      });

      // Drain and replay any pending events that arrived while loading
      for (final session in daemonSessions) {
        final parts = session.title.split(' / ');
        final sid = parts.length > 1 ? parts[1] : null;
        if (sid != null) {
          final pending = _pendingEvents.remove(sid);
          if (pending != null) {
            for (final msg in pending) {
              _onWebSocketEvent(msg);
            }
          }
        }
      }
    } catch (_) {
      // Fallback
    }
  }

  void _onWebSocketEvent(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type == 'connection_closed') {
      _onWebSocketClosed(_connectGeneration);
      return;
    }

    if (type == 'event') {
      final envelope = message['envelope'] as Map<String, dynamic>?;
      final event = envelope?['event'] as Map<String, dynamic>?;
      if (event == null) return;

      String? sessionId;
      if (event.containsKey('Output')) {
        sessionId = event['Output']['session_id'] as String?;
      } else if (event.containsKey('Exited')) {
        sessionId = event['Exited']['session_id'] as String?;
      }

      if (sessionId == null) return;

      final sessionIndex = _sessions.indexWhere(
        (s) => s.title == 'triage / $sessionId',
      );

      if (sessionIndex == -1) {
        // Buffer the event for when the session is fully attached/loaded
        _pendingEvents.putIfAbsent(sessionId, () => []).add(message);
        return;
      }

      final session = _sessions[sessionIndex];

      if (event.containsKey('Output')) {
        final output = event['Output'] as Map<String, dynamic>;
        final outputSeq = output['output_seq'] as int? ?? 0;
        final bytes = (output['bytes'] as List<dynamic>).cast<int>();
        final text = utf8.decode(bytes, allowMalformed: true);

        // Filter out any duplicate welcome messages or output
        // already incorporated in the attached session snapshot.
        if (outputSeq <= session.outputSeq) {
          return;
        }

        // Write directly to xterm.js via the controller.
        // This bypasses calling setState() on every small output chunk,
        // avoiding Flutter widget tree rebuilds during active WebSocket sessions.
        session.terminalController.write(text);

        // Update backup logs silently (without calling setState).
        final rows = session.rows;
        final newLines = text.split('\n');
        if (rows.isNotEmpty &&
            rows.last.spans.length == 1 &&
            rows.last.spans.first.text.isEmpty) {
          rows.removeLast();
        }
        for (final line in newLines) {
          rows.add(_plainRow(line));
        }
        session.outputSeq = outputSeq;
      } else if (event.containsKey('Exited')) {
        setState(() {
          session.status = 'exited';
          session.statusColor = const Color(0xff7f8b8d);
        });
      }
    }
  }

  void _onWebSocketError(dynamic error, int generation) {
    if (_disposed || generation != _connectGeneration) return;
    setState(() {
      _connectionStatus = 'Error';
      _connectionStatusColor = const Color(0xffff6b6b);
      _markAttachedSessionsDisconnected();
    });
    _scheduleReconnect();
  }

  void _onWebSocketClosed(int generation) {
    if (_disposed || generation != _connectGeneration) return;
    setState(() {
      _connectionStatus = 'Connection Closed';
      _connectionStatusColor = const Color(0xff7f8b8d);
      _markAttachedSessionsDisconnected();
    });
    _scheduleReconnect();
  }

  @override
  void dispose() {
    _disposed = true;
    _connectGeneration++;
    _reconnectTimer?.cancel();
    if (_clientInitialized) {
      _client.disconnect();
      _websocketSubscription?.cancel();
    }
    for (final s in _sessions) {
      s.terminalController.dispose();
      TerminalPane.destroySession(s.title);
    }
    super.dispose();
  }

  void _selectSession(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  void _createSession() async {
    if (_client.isConnected) {
      setState(() {
        _connectionStatus = 'Creating session...';
        _connectionStatusColor = const Color(0xffffc857);
      });
      String sessionId = '';
      String? subId;
      try {
        try {
          sessionId = await _client.startSession(command: 'bash');
        } catch (_) {
          sessionId = await _client.startSession(command: 'cmd.exe');
        }
        if (sessionId.isNotEmpty) {
          // Subscribe to events first so we don't miss welcome messages
          subId = await _client.subscribeSessionEvents(sessionId: sessionId);
          if (subId.isNotEmpty) {
            _subscriptionIds[subId] = sessionId;
          }

          final attachRes = await _client.attachSession(
            sessionId: sessionId,
            clientId: _clientId,
            mode: 'InteractiveController',
          );
          final responseObj = attachRes['response'] as Map<String, dynamic>?;
          final snapshot = responseObj?['snapshot'] as Map<String, dynamic>?;
          final contextObj = snapshot?['context'] as Map<String, dynamic>?;
          final branch = contextObj?['branch']?.toString() ?? 'main';

          final visibleRowsJson = snapshot?['visible_rows'] as List<dynamic>?;
          final styledRowsJson = snapshot?['styled_rows'] as List<dynamic>?;
          final styledRows =
              styledRowsJson
                  ?.map((e) => StyledRow.fromJson(e as Map<String, dynamic>))
                  .toList() ??
              [];

          final List<StyledRow> rows = [];
          if (visibleRowsJson != null) {
            final visibleRows = visibleRowsJson.cast<String>();
            final styledRowsStart = visibleRows.length - styledRows.length;
            if (styledRowsStart > 0) {
              try {
                final historyRes = await _client.styledRows(
                  sessionId: sessionId,
                  start: 0,
                  end: visibleRows.length,
                );
                final responseObj =
                    historyRes['response'] as Map<String, dynamic>?;
                final rowsList = responseObj?['rows'] as List<dynamic>?;
                if (rowsList != null) {
                  rows.addAll(
                    rowsList.map(
                      (e) => StyledRow.fromJson(e as Map<String, dynamic>),
                    ),
                  );
                } else {
                  for (var i = 0; i < visibleRows.length; i++) {
                    if (i < styledRowsStart) {
                      rows.add(_plainRow(visibleRows[i]));
                    } else {
                      rows.add(styledRows[i - styledRowsStart]);
                    }
                  }
                }
              } catch (_) {
                for (var i = 0; i < visibleRows.length; i++) {
                  if (i < styledRowsStart) {
                    rows.add(_plainRow(visibleRows[i]));
                  } else {
                    rows.add(styledRows[i - styledRowsStart]);
                  }
                }
              }
            } else {
              rows.addAll(styledRows);
            }
          } else {
            rows.addAll(styledRows);
          }

          final session = SessionVm(
            title: 'triage / $sessionId',
            branch: branch,
            status: 'attached',
            statusColor: const Color(0xff7fd1c7),
            icon: Icons.terminal,
            rows: rows.isEmpty
                ? [_plainRow('Attached to session $sessionId')]
                : rows,
            outputSeq: snapshot?['output_seq'] as int? ?? 0,
            isRemote: true,
          );
          _setupSessionInputListener(session);

          setState(() {
            _sessions.insert(0, session);
            _selectedIndex = 0;
            _connectionStatus = 'Connected to Daemon';
            _connectionStatusColor = const Color(0xff7fd1c7);
          });

          // Drain and replay any pending events that arrived during attach
          final pending = _pendingEvents.remove(sessionId);
          if (pending != null) {
            for (final msg in pending) {
              _onWebSocketEvent(msg);
            }
          }
        }
      } catch (e) {
        // Roll back partial state so a failed create doesn't strand a subscription
        // id or accumulate buffered events for a session that will never appear.
        if (subId != null && subId.isNotEmpty) {
          _subscriptionIds.remove(subId);
        }
        if (sessionId.isNotEmpty) {
          _pendingEvents.remove(sessionId);
        }
        setState(() {
          _connectionStatus = 'Error creating session';
          _connectionStatusColor = const Color(0xffff6b6b);
        });
      }
      return;
    }

    final scratchId = _createdSessionCount + 1;
    final session = SessionVm(
      title: 'triage / scratch-$scratchId',
      branch: 'experiment/flutter-spike',
      status: 'idle',
      statusColor: const Color(0xff7f8b8d),
      icon: Icons.add_circle_outline,
      rows: [
        _promptRow('triage session new'),
        _plainRow('created scratch session $scratchId'),
        _plainRow(''),
        _plainRow('ready'),
      ],
      outputSeq: 0,
    );
    _setupSessionInputListener(session);

    setState(() {
      _createdSessionCount = scratchId;
      _sessions.insert(0, session);
      _selectedIndex = 0;
    });
  }

  Future<void> _closeSession(SessionVm session) async {
    final parts = session.title.split(' / ');
    final sessionId = parts.length > 1 ? parts[1] : null;

    if (_client.isConnected && sessionId != null) {
      try {
        await _client.shutdownSession(sessionId: sessionId);
      } catch (e) {
        debugPrint('Failed to shutdown session: ${e.toString()}');
      }
    }

    setState(() {
      final index = _sessions.indexOf(session);
      if (index != -1) {
        _sessions.removeAt(index);
        session.terminalController.dispose();
        TerminalPane.destroySession(session.title);
        if (_selectedIndex >= _sessions.length) {
          _selectedIndex = _sessions.isEmpty ? 0 : _sessions.length - 1;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_needsPairing) {
      return Scaffold(
        body: Center(
          child: SingleChildScrollView(
            child: Container(
              width: 420,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: const Color(0xff161b1d),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xff2a3437)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: _PairingView(
                onPair: _onPairRequested,
                onCancel: () async {
                  try {
                    await _client.disconnect().catchError((_) {});
                    await _websocketSubscription?.cancel().catchError((_) {});
                    _reconnectTimer?.cancel();
                  } catch (_) {}
                  if (!mounted) return;
                  setState(() {
                    _needsPairing = false;
                    _connectionStatus = 'Offline (Local Mock)';
                    _connectionStatusColor = const Color(0xff7f8b8d);
                  });
                },
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            SessionRail(
              sessions: _sessions,
              selectedIndex: _selectedIndex,
              onSelectSession: _selectSession,
              onCreateSession: _createSession,
              connectionStatus: _connectionStatus,
              connectionStatusColor: _connectionStatusColor,
              isCollapsed: _sidebarCollapsed,
              onToggleCollapse: () {
                setState(() {
                  _sidebarCollapsed = !_sidebarCollapsed;
                });
              },
            ),
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: Color(0xff263033),
            ),
            Expanded(
              child: _sessions.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.terminal,
                            size: 64,
                            color: Color(0xff263033),
                          ),
                          SizedBox(height: 16),
                          Text(
                            'No active sessions',
                            style: TextStyle(
                              fontSize: 18,
                              color: Color(0xff7f8b8d),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Create a new session by clicking the "+" button on the sidebar.',
                            style: TextStyle(
                              fontSize: 14,
                              color: Color(0xff7f8b8d),
                            ),
                          ),
                        ],
                      ),
                    )
                  : SessionWorkspace(
                      session: _selectedSession,
                      onCloseSession: () => _closeSession(_selectedSession),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SessionRail extends StatelessWidget {
  const SessionRail({
    super.key,
    required this.sessions,
    required this.selectedIndex,
    required this.onSelectSession,
    required this.onCreateSession,
    required this.connectionStatus,
    required this.connectionStatusColor,
    required this.isCollapsed,
    required this.onToggleCollapse,
  });

  final List<SessionVm> sessions;
  final int selectedIndex;
  final ValueChanged<int> onSelectSession;
  final VoidCallback onCreateSession;
  final String connectionStatus;
  final Color connectionStatusColor;
  final bool isCollapsed;
  final VoidCallback onToggleCollapse;

  @override
  Widget build(BuildContext context) {
    if (isCollapsed) {
      return Container(
        width: 72,
        color: const Color(0xff151a1d),
        child: Column(
          children: [
            const SizedBox(height: 20),
            IconButton(
              onPressed: onToggleCollapse,
              tooltip: 'Expand sidebar',
              icon: const Icon(
                Icons.chevron_right,
                color: Color(0xff7fd1c7),
                size: 26,
              ),
            ),
            const SizedBox(height: 16),
            IconButton(
              onPressed: onCreateSession,
              tooltip: 'New session',
              icon: const Icon(Icons.add, color: Color(0xffcdd7d6)),
            ),
            const SizedBox(height: 16),
            Tooltip(
              message: connectionStatus,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: connectionStatusColor,
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Divider(height: 1, color: Color(0xff263033)),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  children: [
                    for (final indexed in sessions.indexed)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Tooltip(
                          message: indexed.$2.title,
                          child: InkWell(
                            onTap: () => onSelectSession(indexed.$1),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: indexed.$1 == selectedIndex
                                    ? const Color(0xff233033)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: indexed.$1 == selectedIndex
                                      ? const Color(0xff3b5356)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Icon(
                                indexed.$2.icon,
                                color: indexed.$1 == selectedIndex
                                    ? const Color(0xff7fd1c7)
                                    : const Color(0xffcdd7d6),
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: 320,
      color: const Color(0xff151a1d),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 10, 16),
            child: Row(
              children: [
                const Icon(Icons.route, size: 24, color: Color(0xff7fd1c7)),
                const SizedBox(width: 10),
                const Text(
                  'Triage',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: onToggleCollapse,
                  tooltip: 'Minimize sidebar',
                  icon: const Icon(
                    Icons.chevron_left,
                    color: Color(0xff7f8b8d),
                    size: 22,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const Spacer(),
                IconButton(
                  onPressed: onCreateSession,
                  tooltip: 'New session',
                  icon: const Icon(Icons.add, color: Color(0xffcdd7d6)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _ConnectionStatus(
              status: connectionStatus,
              color: connectionStatusColor,
            ),
          ),
          const SizedBox(height: 18),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'SESSIONS',
              style: TextStyle(
                color: Color(0xff7f8b8d),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              child: Column(
                children: [
                  for (final indexed in sessions.indexed)
                    SessionListTile(
                      selected: indexed.$1 == selectedIndex,
                      title: indexed.$2.title,
                      subtitle: indexed.$2.status,
                      statusColor: indexed.$2.statusColor,
                      icon: indexed.$2.icon,
                      onTap: () => onSelectSession(indexed.$1),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.status, required this.color});

  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xff1d2528),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xff2f3b3f)),
      ),
      child: Row(
        children: [
          Icon(Icons.radio_button_checked, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class SessionListTile extends StatelessWidget {
  const SessionListTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.statusColor,
    required this.icon,
    required this.onTap,
    this.selected = false,
  });

  final String title;
  final String subtitle;
  final Color statusColor;
  final IconData icon;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: title,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? const Color(0xff233033) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? const Color(0xff3b5356) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: const Color(0xffcdd7d6)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xff9aa6a8)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SessionWorkspace extends StatelessWidget {
  const SessionWorkspace({
    super.key,
    required this.session,
    this.onCloseSession,
  });

  final SessionVm session;
  final VoidCallback? onCloseSession;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        WorkspaceHeader(session: session, onClose: onCloseSession),
        Expanded(
          child: TerminalPane(
            key: ValueKey(session.title),
            terminalId: session.title,
            controller: session.terminalController,
            fallbackRows: session.rows,
          ),
        ),
      ],
    );
  }
}

class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({super.key, required this.session, this.onClose});

  final SessionVm session;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: const BoxDecoration(
        color: Color(0xff151a1d),
        border: Border(bottom: BorderSide(color: Color(0xff263033))),
      ),
      child: Row(
        children: [
          Icon(session.icon, color: const Color(0xff7fd1c7)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  session.branch,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xff9aa6a8)),
                ),
              ],
            ),
          ),
          Icon(Icons.circle, size: 12, color: session.statusColor),
          const SizedBox(width: 8),
          Text(
            session.status,
            style: const TextStyle(color: Color(0xffcdd7d6)),
          ),
          const SizedBox(width: 16),
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.close, color: Color(0xffcdd7d6)),
              tooltip: 'Close session',
              onPressed: onClose,
            )
          else
            const Icon(Icons.more_horiz, color: Color(0xffcdd7d6)),
        ],
      ),
    );
  }
}

class _PairingView extends StatefulWidget {
  const _PairingView({required this.onPair, required this.onCancel});

  final Future<void> Function(String pin) onPair;
  final VoidCallback onCancel;

  @override
  State<_PairingView> createState() => _PairingViewState();
}

class _PairingViewState extends State<_PairingView> {
  final TextEditingController _pinController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pinController.text
        .replaceAll(RegExp(r'\s+'), '')
        .toUpperCase()
        .replaceAll(RegExp(r'[IL]'), '1')
        .replaceAll('O', '0');
    final validChars = RegExp(r'^[0-9A-HJ-KM-NP-TV-Z]{8}$');
    if (!validChars.hasMatch(pin)) {
      setState(() {
        _errorMessage =
            'PIN must be 8 characters (letters and digits, excluding U)';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await widget.onPair(pin);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.security, color: Color(0xff7fd1c7), size: 28),
            const SizedBox(width: 12),
            const Text(
              'Pair Remote Device',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          'This Triage daemon requires pairing. Please run "triage pair" in your local terminal and enter the 8-character PIN below.',
          style: TextStyle(color: Color(0xffa5b1b4), fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _pinController,
          maxLength: 8,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(
            fontSize: 22,
            letterSpacing: 6,
            fontWeight: FontWeight.bold,
            color: Color(0xff7fd1c7),
          ),
          decoration: const InputDecoration(
            labelText: '8-Character PIN',
            labelStyle: TextStyle(
              fontSize: 14,
              letterSpacing: 0,
              color: Color(0xff7f8b8d),
            ),
            counterText: '',
            border: OutlineInputBorder(),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xff2a3437)),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xff7fd1c7)),
            ),
          ),
          onSubmitted: (_) => _isLoading ? null : _submit(),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorMessage!,
            style: const TextStyle(color: Color(0xffff6b6b), fontSize: 13),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _isLoading ? null : widget.onCancel,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xff7f8b8d),
              ),
              child: const Text('Cancel (Offline Mode)'),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: _isLoading ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xff2b6f6f),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text('Pair Device'),
            ),
          ],
        ),
      ],
    );
  }
}
