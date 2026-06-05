import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:triage_client/services/external_navigation.dart';
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:xterm/xterm.dart' as xt;
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/widgets/terminal_pane.dart';
import 'package:triage_client/services/storage.dart';
import 'package:triage_client/terminal/terminal_intent.dart';
import 'package:triage_client/terminal/terminal_store.dart';
import 'package:triage_client/terminal/terminal_controller_sink.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Restore the persisted client id / pairing token from secure storage before
  // the first frame so the app can reconnect without re-pairing on each launch.
  await loadCredentials();
  runApp(const TriageClientApp());
}

const int _defaultDaemonPort = 7777;
const double _sessionRailCollapsedWidth = 72;
const double _sessionRailExpandedWidth = 320;
const Duration _sessionRailAnimationDuration = Duration(milliseconds: 220);

@visibleForTesting
Uri defaultWebSocketUriForBase(Uri base) {
  if ((base.scheme == 'http' || base.scheme == 'https') &&
      base.host.isNotEmpty &&
      base.port == _defaultDaemonPort) {
    return Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      host: base.host,
      port: base.port,
      path: '/ws',
    );
  }

  return Uri.parse('ws://127.0.0.1:$_defaultDaemonPort/ws');
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

enum NewSessionShell {
  cmd('cmd.exe', 'Cmd'),
  bash('bash', 'Bash'),
  defaultPosix('/bin/sh', 'Default', ['-lc', 'exec "\${SHELL:-/bin/sh}"']);

  const NewSessionShell(this.command, this.label, [this.args = const []]);

  final String command;
  final String label;
  final List<String> args;
}

@visibleForTesting
List<NewSessionShell> newSessionShellMenuOrderForPlatform(
  TargetPlatform platform,
) {
  return platform == TargetPlatform.windows
      ? const [NewSessionShell.cmd, NewSessionShell.bash]
      : const [NewSessionShell.defaultPosix];
}

@visibleForTesting
bool showNewSessionShellMenuForPlatform(TargetPlatform platform) {
  return platform == TargetPlatform.windows;
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
    this.isExited = false,
  }) : terminalController = TerminalController() {
    terminal = xt.Terminal(
      maxLines: 10000,
      reflowEnabled: false,
      onResize: (w, h, pw, ph) => onTerminalResize?.call(w, h, pw, ph),
    );
    terminalController.addWriteListener((data) {
      terminal.write(data);
    });
    terminalController.addClearListener(() {
      try {
        terminal.useMainBuffer();
        terminal.mainBuffer.clear();
        terminal.altBuffer.clear();
        terminal.write('\x1b[H\x1b[2J\x1b[3J');
      } catch (_) {}
    });
    terminalController.addResizeListener((cols, rows) {
      terminal.resize(cols, rows);
    });
    store = TerminalStore(TerminalControllerSink(terminalController));
  }

  final String title;
  final String branch;
  String status;
  Color statusColor;
  final IconData icon;
  // Plain visible rows kept for the test fallback view and demo seeding only;
  // real rendering goes through [store]/[terminal] from raw bytes.
  final List<StyledRow> rows;
  final TerminalController terminalController;
  int outputSeq;
  final bool isRemote;
  bool isExited;
  int focusCursorRevision = 0;
  int? lastFittedCols;
  int? lastFittedRows;
  int? inFlightCols;
  int? inFlightRows;
  int resizeRequestSeq = 0;

  late final xt.Terminal terminal;
  // The single, ordered write path for all terminal output (live + history).
  // The sink wraps the controller, so both platform views render through their
  // existing listeners; decoding/buffering/CRLF/dedup all live in the store.
  late final TerminalStore store;
  void Function(int w, int h, int pw, int ph)? onTerminalResize;

  // Deferred history: replay must wait until the view is laid out and fitted, so
  // it re-emulates at the real terminal size. Writing before the first fit
  // renders at the default 80x24 and shows nothing until a resize refits.
  _PendingHistory? _pendingHistory;
  bool _viewReady = false;
  int _viewCols = 80;
  int _viewRows = 24;

  String? get remoteSessionId {
    if (!isRemote) return null;
    final parts = title.split(' / ');
    return parts.length > 1 ? parts[1] : null;
  }

  /// Begin the attach/resync lifecycle and stage the raw output-history tail.
  /// [Attach] is dispatched now so live chunks buffer in arrival order; the
  /// actual [HistoryBytes] replay is deferred until the view reports its fitted
  /// size (see [noteViewFit]). Live chunks at or below [throughOutputSeq] are
  /// dropped by the store as duplicates.
  void applyHistory(
    List<int> rawOutput, {
    required int cols,
    required int rows,
    int? throughOutputSeq,
  }) {
    _pendingHistory = _PendingHistory(rawOutput, throughOutputSeq);
    store.dispatch(const Attach());
    if (_viewReady) {
      _flushPendingHistory();
    }
  }

  /// The view fitted to a real grid size. Records it and replays any staged
  /// history at that size. Idempotent on subsequent fits (no staged history).
  void noteViewFit(int cols, int rows) {
    _viewCols = cols;
    _viewRows = rows;
    _viewReady = true;
    _flushPendingHistory();
  }

  void _flushPendingHistory() {
    final pending = _pendingHistory;
    if (pending == null) return;
    _pendingHistory = null;
    store.dispatch(
      HistoryBytes(
        pending.rawOutput,
        cols: _viewCols,
        rows: _viewRows,
        throughOutputSeq: pending.throughOutputSeq,
      ),
    );
  }

  /// Apply a live raw output chunk (remote PTY bytes) through the write path.
  void applyLiveBytes(List<int> bytes, {int? outputSeq}) {
    store.dispatch(LiveBytes(bytes, outputSeq: outputSeq));
  }

  /// Echo locally produced bytes for local/demo sessions (no remote PTY).
  void echoLocalBytes(List<int> bytes) {
    store.dispatch(LiveBytes(bytes));
  }

  void markExited() => store.dispatch(const Exited());

  void focusCursorOnNextDisplay() {
    focusCursorRevision += 1;
  }

  void dispose() {
    store.dispose();
    terminalController.dispose();
  }
}

/// Staged attach/resync history awaiting the view's first fit.
class _PendingHistory {
  const _PendingHistory(this.rawOutput, this.throughOutputSeq);

  final List<int> rawOutput;
  final int? throughOutputSeq;
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
  Timer? _credentialStorageTimer;
  StreamSubscription<Map<String, dynamic>>? _websocketSubscription;
  String? _bearerToken;
  bool _storageBackedClientId = false;
  bool _needsPairing = false;
  bool _pairingChallengeLoading = false;
  String? _pairingDeviceCode;
  Uri? _pairingVerificationUri;
  DateTime? _pairingExpiresAt;
  String? _pairingChallengeError;
  bool _sidebarCollapsed = false;
  String _connectionStatus = 'Offline (Local Mock)';
  Color _connectionStatusColor = const Color(0xff7f8b8d);
  late final String _clientId;
  final Map<String, String> _subscriptionIds = {};
  final Map<String, List<Map<String, dynamic>>> _pendingEvents = {};
  final Queue<Map<String, dynamic>> _websocketEventQueue = Queue();
  bool _websocketProcessingEvent = false;

  late final List<SessionVm> _sessions;
  int _selectedIndex = 0;
  int _createdSessionCount = 0;
  late NewSessionShell _newSessionShell;

  SessionVm get _selectedSession => _sessions[_selectedIndex];

  StyledRow _plainRow(String text) {
    return StyledRow(
      spans: [StyledSpan(text: text, style: const TerminalStyle())],
    );
  }

  /// Flattens demo/local placeholder rows into plain CRLF-terminated bytes for
  /// seeding a session's store (styling is dropped — these are placeholders).
  List<int> _seedBytesFromRows(List<StyledRow> rows) {
    final text = rows
        .map((row) => row.spans.map((span) => span.text).join())
        .join('\r\n');
    return utf8.encode(text);
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
    _startCredentialStorageWatcher();
    _newSessionShell = newSessionShellMenuOrderForPlatform(
      defaultTargetPlatform,
    ).first;
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
      // Seed the demo/local sessions into the store's live phase so their
      // placeholder content renders and local echo works through one pipeline.
      s.applyHistory(_seedBytesFromRows(s.rows), cols: 80, rows: 24);
    }
    final isMockMode = Uri.base.queryParameters['mock'] == 'true';
    if (isMockMode) {
      _connectionStatus = 'Offline (Local Mock)';
      _connectionStatusColor = const Color(0xff7f8b8d);
    } else {
      _connectWebSocket();
    }
  }

  String _loadOrCreateClientId() {
    final storedClientId = retrieveClientId();
    if (storedClientId != null && storedClientId.trim().isNotEmpty) {
      _storageBackedClientId = true;
      return storedClientId;
    }

    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final clientId = 'triage-flutter-client-$suffix';
    persistClientId(clientId);
    _storageBackedClientId = retrieveClientId() == clientId;
    return clientId;
  }

  void _refreshBearerTokenFromStorage() {
    final storedClientId = retrieveClientId();
    final storedToken = retrieveToken();
    if (!_storageBackedClientId) {
      if (storedClientId == _clientId) {
        _storageBackedClientId = true;
      }
      if (storedToken?.trim().isNotEmpty == true) {
        _bearerToken = storedToken;
      }
      return;
    }

    if (storedClientId == null || storedClientId.trim().isEmpty) {
      _bearerToken = null;
      persistClientId(_clientId);
      _storageBackedClientId = retrieveClientId() == _clientId;
      return;
    }
    if (storedClientId != _clientId) {
      _bearerToken = null;
      return;
    }
    _bearerToken = storedToken?.trim().isEmpty == false ? storedToken : null;
  }

  void _startCredentialStorageWatcher() {
    _credentialStorageTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _checkCredentialStorageStillMatches();
    });
  }

  void _checkCredentialStorageStillMatches() {
    if (_disposed ||
        !_storageBackedClientId ||
        !_clientInitialized ||
        !_client.isConnected ||
        _needsPairing ||
        _bearerToken == null) {
      return;
    }

    if (retrieveClientId() == _clientId && retrieveToken() == _bearerToken) {
      return;
    }

    _bearerToken = null;
    _reconnectAttempt = 0;
    unawaited(_connectWebSocket(isReconnect: true));
  }

  Uri _defaultWebSocketUri() {
    return defaultWebSocketUriForBase(Uri.base);
  }

  Uri? _verificationUriForClient(
    TriageWebSocketClient client, {
    String? deviceCode,
  }) {
    final wsUri = client.uri;
    if (!_isLocalVerificationHost(wsUri.host)) {
      return null;
    }

    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    final verificationUri = wsUri.replace(
      scheme: scheme,
      path: '/pair',
      query: '',
      fragment: '',
    );
    if (deviceCode == null || deviceCode.trim().isEmpty) {
      return verificationUri;
    }
    return verificationUri.replace(
      queryParameters: {'device_code': deviceCode},
    );
  }

  bool _isLocalVerificationHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '::1' ||
        normalized == '0:0:0:0:0:0:0:1' ||
        normalized == '::ffff:127.0.0.1' ||
        normalized.startsWith('127.');
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
        // Local/demo session: echo keystrokes through the same single write
        // path the remote stream uses, so there is one rendering pipeline.
        if (keys == '\r') {
          session.echoLocalBytes(const [0x0d, 0x0a]); // CR LF
        } else if (keys == '\x7f' || keys == '\x08') {
          session.echoLocalBytes(const [0x08, 0x20, 0x08]); // backspace-erase
        } else {
          session.echoLocalBytes(utf8.encode(keys));
        }
      }
    });

    session.terminalController.addResizeOutListener((cols, rows) {
      if (_client.isConnected && session.status == 'attached') {
        final parts = session.title.split(' / ');
        final sessionId = parts.length > 1 ? parts[1] : null;
        if (sessionId != null) {
          ++session.resizeRequestSeq;
          // Tell the host its new PTY size; the program repaints and the live
          // byte stream self-heals the view. No history replay on resize.
          session.lastFittedCols = cols;
          session.lastFittedRows = rows;
          unawaited(() async {
            try {
              await _client.resizeSession(
                sessionId: sessionId,
                cols: cols,
                rows: rows,
              );
            } catch (_) {}
          }());
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
    if (_disposed ||
        (_needsPairing && _client.isConnected) ||
        _reconnectTimer?.isActive == true) {
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

  Future<void> _connectWebSocket({bool isReconnect = false}) async {
    if (_disposed || _isConnecting) return;
    _isConnecting = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final generation = ++_connectGeneration;
    _refreshBearerTokenFromStorage();
    if (_clientInitialized) {
      final subscription = _websocketSubscription;
      _websocketSubscription = null;
      try {
        await subscription?.cancel().timeout(const Duration(milliseconds: 250));
      } catch (_) {}
      try {
        await _client.disconnect();
      } catch (_) {}
    }

    if (_disposed || generation != _connectGeneration) {
      _isConnecting = false;
      return;
    }

    final client =
        widget.client ?? TriageWebSocketClient(_defaultWebSocketUri());
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
        await _showPairingChallenge(generation);
        _isConnecting = false;
        return;
      }

      setState(() {
        _needsPairing = false;
        _pairingChallengeLoading = false;
        _pairingChallengeError = null;
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
        await _showPairingChallenge(generation);
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

  Future<void> _showPairingChallenge(int generation) async {
    _bearerToken = null;
    clearToken();
    if (_disposed || generation != _connectGeneration) {
      return;
    }

    setState(() {
      _needsPairing = true;
      _pairingChallengeLoading = true;
      _pairingChallengeError = null;
      _connectionStatus = 'Awaiting Pairing';
      _connectionStatusColor = const Color(0xffffc857);
    });

    await _requestPairingChallenge(generation: generation);
  }

  Future<void> _requestPairingChallenge({int? generation}) async {
    if (_disposed || (generation != null && generation != _connectGeneration)) {
      return;
    }

    if (!_client.isConnected) {
      setState(() {
        _pairingChallengeLoading = false;
        _pairingChallengeError =
            'Connection closed before the pairing challenge could be requested.';
      });
      _scheduleReconnect();
      return;
    }

    setState(() {
      _pairingChallengeLoading = true;
      _pairingChallengeError = null;
    });

    try {
      final challenge = await _client.pairingChallenge(clientId: _clientId);
      if (_disposed ||
          (generation != null && generation != _connectGeneration)) {
        return;
      }

      final expiresAtSeconds = challenge['expires_at'];
      setState(() {
        _pairingDeviceCode = challenge['device_code']?.toString();
        _pairingVerificationUri = _verificationUriForClient(
          _client,
          deviceCode: _pairingDeviceCode,
        );
        _pairingExpiresAt = expiresAtSeconds is int
            ? DateTime.fromMillisecondsSinceEpoch(
                expiresAtSeconds * 1000,
                isUtc: true,
              ).toLocal()
            : null;
        _pairingChallengeLoading = false;
      });
    } catch (e) {
      if (_disposed ||
          (generation != null && generation != _connectGeneration)) {
        return;
      }
      setState(() {
        _pairingChallengeLoading = false;
        _pairingChallengeError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _onPairRequested(String pin) async {
    final String token;
    try {
      token = await _client.pair(code: pin, clientId: _clientId);
    } catch (_) {
      await _requestPairingChallenge();
      rethrow;
    }
    if (token.isNotEmpty) {
      setState(() {
        _bearerToken = token;
        persistClientId(_clientId);
        persistToken(token);
        _storageBackedClientId = retrieveClientId() == _clientId;
        _pairingChallengeError = null;
      });
      _reconnectAttempt = 0;
      _isConnecting = false;
      await _connectWebSocket();
    } else {
      throw Exception('Server returned empty pairing token');
    }
  }

  Future<void> _loadDaemonSessions() async {
    if (!_client.isConnected) return;

    try {
      final sessionIds = await _client.listSessions();
      final List<String> failedSessionIds = [];
      final targetSelectedIndex = _selectedIndex >= sessionIds.length
          ? (sessionIds.isEmpty ? 0 : sessionIds.length - 1)
          : _selectedIndex;

      if (_disposed) return;
      final loadingSessionTitles = {
        for (final sid in sessionIds) 'triage / $sid',
      };
      setState(() {
        for (final s in _sessions) {
          s.terminalController.dispose();
          if (!loadingSessionTitles.contains(s.title)) {
            TerminalPane.destroySession(s.title);
          }
        }
        _sessions.clear();
        for (final sid in sessionIds) {
          final session = _loadingDaemonSession(sid);
          _setupSessionInputListener(session);
          _sessions.add(session);
        }
        if (_selectedIndex >= _sessions.length) {
          _selectedIndex = _sessions.isEmpty ? 0 : _sessions.length - 1;
        } else {
          _selectedIndex = targetSelectedIndex;
        }
        if (sessionIds.isEmpty) {
          _connectionStatus = 'Connected to Daemon';
          _connectionStatusColor = const Color(0xff7fd1c7);
        } else {
          _connectionStatus = 'Loading ${sessionIds.length} sessions...';
          _connectionStatusColor = const Color(0xffffc857);
        }
      });

      final loadTasks = <Future<void>>[];
      for (var idx = 0; idx < sessionIds.length; idx++) {
        final sid = sessionIds[idx];
        final includeHistory = idx == targetSelectedIndex;
        loadTasks.add(() async {
          try {
            final session = await _loadDaemonSession(
              sid,
              includeHistory: includeHistory,
            );
            if (_disposed) return;
            setState(() {
              final existingIndex = _sessions.indexWhere(
                (s) => s.remoteSessionId == sid,
              );
              if (existingIndex == -1) return;
              final oldSession = _sessions[existingIndex];
              oldSession.dispose();
              if (oldSession.title != session.title) {
                TerminalPane.destroySession(oldSession.title);
              }
              _sessions[existingIndex] = session;
            });
            _drainPendingEvents(sid);
          } catch (e) {
            failedSessionIds.add(sid);
            if (_disposed) return;
            setState(() {
              final existingIndex = _sessions.indexWhere(
                (s) => s.remoteSessionId == sid,
              );
              if (existingIndex == -1) return;
              _sessions[existingIndex].status = 'load failed';
              _sessions[existingIndex].statusColor = const Color(0xffff6b6b);
              _sessions[existingIndex].rows
                ..clear()
                ..add(_plainRow('Failed to load session $sid'));
            });
            debugPrint('Failed to load session $sid: ${e.toString()}');
          }
        }());
      }

      await Future.wait(loadTasks);

      if (!_disposed) {
        setState(() {
          final loadedCount = _sessions
              .where((s) => s.isRemote && s.status == 'attached')
              .length;
          if (failedSessionIds.isEmpty) {
            _connectionStatus = 'Connected to Daemon';
            _connectionStatusColor = const Color(0xff7fd1c7);
          } else {
            _connectionStatus =
                'Loaded $loadedCount; failed ${failedSessionIds.join(', ')}';
            _connectionStatusColor = const Color(0xffffc857);
          }
        });
      }

      if (_sessions.isNotEmpty) {
        final activeSession = _sessions[_selectedIndex];
        if (activeSession.status == 'attached') {
          unawaited(
            _refreshSessionSnapshot(
              activeSession,
              includeHistory: true,
            ),
          );
        }
      }
    } catch (_) {
      // Fallback
    }
  }

  SessionVm _loadingDaemonSession(String sessionId) {
    return SessionVm(
      title: 'triage / $sessionId',
      branch: 'main',
      status: 'loading',
      statusColor: const Color(0xffffc857),
      icon: Icons.terminal,
      rows: [_plainRow('Loading session $sessionId...')],
      outputSeq: 0,
      isRemote: true,
    );
  }

  Future<SessionVm> _loadDaemonSession(
    String sid, {
    required bool includeHistory,
  }) async {
    String? subId;
    try {
      var preAttachSnapshot = <String, dynamic>{};
      try {
        final snapshotRes = await _client.snapshotSession(sessionId: sid);
        preAttachSnapshot =
            snapshotRes['snapshot'] as Map<String, dynamic>? ?? {};
      } catch (_) {}

      final replayTargetSize = includeHistory
          ? _estimatedTerminalRestoreSize(
              preAttachSnapshot['size'] as Map<String, dynamic>?,
            )
          : null;
      Map<String, dynamic>? preparedSnapshot;
      if (preAttachSnapshot['exited'] == true) {
        final sizeObj = preAttachSnapshot['size'] as Map<String, dynamic>?;
        final restoreSize =
            replayTargetSize ?? _savedOrEstimatedTerminalRestoreSize(sizeObj);
        try {
          preparedSnapshot = _snapshotFromResponse(
            await _client.restoreSession(
              sessionId: sid,
              rows: restoreSize.$1,
              cols: restoreSize.$2,
            ),
          );
          if (preparedSnapshot != null) {
            preAttachSnapshot = preparedSnapshot;
          }
        } catch (_) {}
      } else if (replayTargetSize != null &&
          !_snapshotSizeMatches(preAttachSnapshot, replayTargetSize)) {
        try {
          preparedSnapshot = _snapshotFromResponse(
            await _client.resizeSession(
              sessionId: sid,
              rows: replayTargetSize.$1,
              cols: replayTargetSize.$2,
            ),
          );
          if (preparedSnapshot != null) {
            preAttachSnapshot = preparedSnapshot;
          }
        } catch (_) {}
      }

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
      var snapshot = responseObj?['snapshot'] as Map<String, dynamic>?;
      if (replayTargetSize != null &&
          preparedSnapshot != null &&
          !_snapshotSizeMatches(snapshot, replayTargetSize)) {
        snapshot = preparedSnapshot;
      }

      final contextObj = snapshot?['context'] as Map<String, dynamic>?;
      final branch = contextObj?['branch']?.toString() ?? 'main';

      final plainRows = _plainRowsFromSnapshot(snapshot);
      final exited = snapshot?['exited'] as bool? ?? false;
      final sizeObj = snapshot?['size'] as Map<String, dynamic>?;
      final cols = sizeObj?['cols'] as int? ?? 80;
      final rowsVal = sizeObj?['rows'] as int? ?? 24;
      final outputSeq = snapshot?['output_seq'] as int? ?? 0;

      final session = SessionVm(
        title: 'triage / $sid',
        branch: branch,
        status: exited ? 'exited' : 'attached',
        statusColor: exited ? const Color(0xff7f8b8d) : const Color(0xff7fd1c7),
        icon: Icons.terminal,
        rows: plainRows.isEmpty
            ? [_plainRow('Attached to session $sid')]
            : plainRows,
        outputSeq: outputSeq,
        isRemote: true,
        isExited: exited,
      );
      // Replay the raw output-history tail through the single write path. Live
      // chunks already covered by this snapshot are dropped by output_seq.
      session.applyHistory(
        _rawOutputFromSnapshot(snapshot ?? const {}),
        cols: cols,
        rows: rowsVal,
        throughOutputSeq: outputSeq,
      );
      _setupSessionInputListener(session);
      return session;
    } catch (e) {
      // Roll back the subscription bookkeeping and drop any events buffered
      // for a session we will never expose, so they don't accumulate forever.
      if (subId != null && subId.isNotEmpty) {
        _subscriptionIds.remove(subId);
      }
      _pendingEvents.remove(sid);
      rethrow;
    }
  }

  void _drainPendingEvents(String sid) {
    final pending = _pendingEvents.remove(sid);
    if (pending != null) {
      for (final msg in pending) {
        _onWebSocketEvent(msg);
      }
    }
  }

  (int, int) _estimatedTerminalRestoreSize(Map<String, dynamic>? fallbackSize) {
    final viewportSize = MediaQuery.maybeSizeOf(context);
    if (viewportSize == null) {
      return (
        fallbackSize?['rows'] as int? ?? 24,
        fallbackSize?['cols'] as int? ?? 80,
      );
    }

    const headerHeight = 68.0;
    const padding = 44.0; // 22.0 on each side of the terminal view
    const averageCellWidth = 9.92;
    const averageCellHeight = 18.0;
    final sidebarWidth = _sidebarCollapsed ? 72.0 : 320.0;
    final terminalWidth = viewportSize.width - sidebarWidth - 1 - padding;
    final terminalHeight = viewportSize.height - headerHeight - padding;
    final cols = (terminalWidth / averageCellWidth).floor().clamp(80, 240);
    final rows = (terminalHeight / averageCellHeight).floor().clamp(10, 80);
    return (rows, cols);
  }

  (int, int) _savedOrEstimatedTerminalRestoreSize(
    Map<String, dynamic>? fallbackSize,
  ) {
    final cols = fallbackSize?['cols'] as int?;
    final rows = fallbackSize?['rows'] as int?;
    if (cols != null && rows != null) {
      return (rows, cols);
    }
    return _estimatedTerminalRestoreSize(fallbackSize);
  }

  (int, int) _currentReplayTerminalSize(
    SessionVm session,
    Map<String, dynamic>? fallbackSize,
  ) {
    final cols = session.lastFittedCols;
    final rows = session.lastFittedRows;
    if (cols != null && rows != null) {
      return (rows, cols);
    }
    return _estimatedTerminalRestoreSize(fallbackSize);
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  Map<String, dynamic>? _snapshotFromResponse(Map<String, dynamic> response) {
    return _asMap(response['snapshot']) ??
        _asMap(_asMap(response['response'])?['snapshot']);
  }

  bool _snapshotSizeMatches(
    Map<String, dynamic>? snapshot,
    (int, int) targetSize,
  ) {
    final sizeObj = snapshot?['size'] as Map<String, dynamic>?;
    return sizeObj?['rows'] == targetSize.$1 &&
        sizeObj?['cols'] == targetSize.$2;
  }

  void _onWebSocketEvent(Map<String, dynamic> message) {
    if (_disposed) return;
    _websocketEventQueue.add(message);
    unawaited(_processWebsocketEventQueue());
  }

  Future<void> _processWebsocketEventQueue() async {
    if (_websocketProcessingEvent || _websocketEventQueue.isEmpty) return;
    _websocketProcessingEvent = true;
    try {
      while (_websocketEventQueue.isNotEmpty && !_disposed) {
        final message = _websocketEventQueue.removeFirst();
        try {
          await _processWebSocketEvent(message);
        } catch (_) {}
      }
    } finally {
      _websocketProcessingEvent = false;
    }
  }

  Future<void> _processWebSocketEvent(Map<String, dynamic> message) async {
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
      } else if (event.containsKey('Snapshot')) {
        sessionId = event['Snapshot']['session_id'] as String?;
      } else if (event.containsKey('ResyncRequired')) {
        sessionId = event['ResyncRequired']['session_id'] as String?;
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
      if (session.status == 'loading') {
        _pendingEvents.putIfAbsent(sessionId, () => []).add(message);
        return;
      }

      if (event.containsKey('Output')) {
        final output = event['Output'] as Map<String, dynamic>;
        final outputSeq = output['output_seq'] as int? ?? 0;
        final bytes = (output['bytes'] as List<dynamic>).cast<int>();

        // Drop output already incorporated into the attach snapshot; the store
        // also de-duplicates against the history high-water seq.
        if (outputSeq <= session.outputSeq) {
          return;
        }
        // Single write path: raw bytes flow through the store, which owns UTF-8
        // carry, CRLF normalization, buffering, and output_seq de-duplication.
        session.applyLiveBytes(bytes, outputSeq: outputSeq);
        session.outputSeq = outputSeq;
      } else if (event.containsKey('Exited')) {
        session.markExited();
        if (mounted) {
          setState(() {
            session.status = 'exited';
            session.statusColor = const Color(0xff7f8b8d);
            session.isExited = true;
          });
        }
      } else if (event.containsKey('Snapshot')) {
        // Resize-driven snapshot broadcast. Raw clients re-emulate from the live
        // byte stream (the program repaints on resize), so there is no history
        // to replay here — ignore it. Track the settled size for resize bookkeeping.
        final snapshot = event['Snapshot']['snapshot'] as Map<String, dynamic>?;
        final size = snapshot?['size'] as Map<String, dynamic>?;
        final cols = size?['cols'] as int?;
        final rows = size?['rows'] as int?;
        if (cols != null && rows != null) {
          session.lastFittedCols = cols;
          session.lastFittedRows = rows;
        }
      } else if (event.containsKey('ResyncRequired')) {
        final snapshot =
            event['ResyncRequired']['snapshot'] as Map<String, dynamic>?;
        if (snapshot != null) {
          await _applySnapshotToSession(session, sessionId, snapshot);
        }
      }
    }
  }

  Future<void> _applySnapshotToSession(
    SessionVm session,
    String sessionId,
    Map<String, dynamic> snapshot,
  ) async {
    if (_disposed) return;
    final sizeObj = snapshot['size'] as Map<String, dynamic>?;
    final cols = sizeObj?['cols'] as int? ?? 80;
    final rowsVal = sizeObj?['rows'] as int? ?? 24;
    final rawOutput = _rawOutputFromSnapshot(snapshot);
    final snapshotOutputSeq = snapshot['output_seq'] as int?;
    final exited = snapshot['exited'] as bool? ?? false;

    // Replay history through the single write path — raw PTY bytes, not the
    // lossy styled-row reconstruction. The store clears and re-emulates, then
    // resumes live (de-duplicating by output_seq).
    session.applyHistory(
      rawOutput,
      cols: cols,
      rows: rowsVal,
      throughOutputSeq: snapshotOutputSeq,
    );

    setState(() {
      // Plain mirror for the test fallback view only; not used for real render.
      session.rows
        ..clear()
        ..addAll(_plainRowsFromSnapshot(snapshot));
      if (snapshotOutputSeq != null) {
        session.outputSeq = max(session.outputSeq, snapshotOutputSeq);
      }
      session.isExited = exited;
      session.status = exited ? 'exited' : 'attached';
      session.statusColor = exited
          ? const Color(0xff7f8b8d)
          : const Color(0xff7fd1c7);
      session.lastFittedCols = cols;
      session.lastFittedRows = rowsVal;
      session.inFlightCols = null;
      session.inFlightRows = null;
    });
  }

  /// Extracts the raw output-history tail from a parsed snapshot map. Empty when
  /// the host did not carry history (old host, or a resize broadcast).
  List<int> _rawOutputFromSnapshot(Map<String, dynamic> snapshot) {
    final raw = snapshot['raw_output'];
    return raw is List ? raw.cast<int>() : const <int>[];
  }

  /// Builds a plain-row mirror of a snapshot, used only by the FLUTTER_TEST
  /// fallback view; production rendering is driven by the store from raw bytes.
  /// Prefers visible_rows, falling back to the flattened text of styled_rows.
  List<StyledRow> _plainRowsFromSnapshot(Map<String, dynamic>? snapshot) {
    if (snapshot == null) return const <StyledRow>[];
    final visible = snapshot['visible_rows'] as List<dynamic>?;
    if (visible != null && visible.isNotEmpty) {
      return visible.map((row) => _plainRow(row?.toString() ?? '')).toList();
    }
    final styled = snapshot['styled_rows'] as List<dynamic>?;
    if (styled != null && styled.isNotEmpty) {
      return styled.map((row) {
        final spans = (row as Map<String, dynamic>?)?['spans'] as List<dynamic>?;
        final text =
            spans
                ?.map(
                  (span) =>
                      (span as Map<String, dynamic>?)?['text']?.toString() ??
                      '',
                )
                .join() ??
            '';
        return _plainRow(text);
      }).toList();
    }
    return const <StyledRow>[];
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
      if (_needsPairing) {
        _pairingChallengeLoading = false;
        _pairingChallengeError =
            'Connection closed before the pairing challenge could be requested.';
      }
      _markAttachedSessionsDisconnected();
    });
    _scheduleReconnect();
  }

  @override
  void dispose() {
    _disposed = true;
    _connectGeneration++;
    _reconnectTimer?.cancel();
    _credentialStorageTimer?.cancel();
    if (_clientInitialized) {
      _client.disconnect();
      _websocketSubscription?.cancel();
    }
    for (final s in _sessions) {
      s.dispose();
      TerminalPane.destroySession(s.title);
    }
    super.dispose();
  }

  void _selectSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    final session = _sessions[index];
    final shouldRefresh =
        _client.isConnected &&
        session.isRemote &&
        _sessionIdFor(session) != null;
    setState(() {
      session.focusCursorOnNextDisplay();
      _selectedIndex = index;
    });
    if (shouldRefresh) {
      unawaited(
        _refreshSessionSnapshot(
          session,
          includeHistory: true,
        ),
      );
    }
  }

  Future<void> _refreshSessionSnapshot(
    SessionVm session, {
    bool includeHistory = false,
  }) async {
    if (!_client.isConnected || !session.isRemote) return;
    final sessionId = _sessionIdFor(session);
    if (sessionId == null) return;
    try {
      final attachRes = await _client.attachSession(
        sessionId: sessionId,
        clientId: _clientId,
        mode: 'InteractiveController',
      );
      final responseObj = attachRes['response'] as Map<String, dynamic>?;
      final snapshot = responseObj?['snapshot'] as Map<String, dynamic>?;
      if (snapshot != null && !_disposed) {
        var finalSnapshot = snapshot;
        final sizeObj = snapshot['size'] as Map<String, dynamic>?;
        final replayTargetSize = includeHistory
            ? _currentReplayTerminalSize(session, sizeObj)
            : null;
        if (snapshot['exited'] == true) {
          debugPrint(
            'Session $sessionId is exited/historical during snapshot refresh; calling restoreSession',
          );
          final restoreSize =
              replayTargetSize ?? _savedOrEstimatedTerminalRestoreSize(sizeObj);
          try {
            final restoredSnapshot = _snapshotFromResponse(
              await _client.restoreSession(
                sessionId: sessionId,
                rows: restoreSize.$1,
                cols: restoreSize.$2,
              ),
            );
            if (restoredSnapshot != null) {
              finalSnapshot = restoredSnapshot;
            }
            final freshAttachRes = await _client.attachSession(
              sessionId: sessionId,
              clientId: _clientId,
              mode: 'InteractiveController',
            );
            final freshResponseObj =
                freshAttachRes['response'] as Map<String, dynamic>?;
            final freshSnapshot =
                freshResponseObj?['snapshot'] as Map<String, dynamic>?;
            if (freshSnapshot != null) {
              if (replayTargetSize == null ||
                  _snapshotSizeMatches(freshSnapshot, replayTargetSize)) {
                finalSnapshot = freshSnapshot;
              }
            }
          } catch (e) {
            debugPrint(
              'Failed to restore session $sessionId during refresh: ${e.toString()}',
            );
          }
        } else if (replayTargetSize != null &&
            !_snapshotSizeMatches(snapshot, replayTargetSize)) {
          try {
            final resizedSnapshot = _snapshotFromResponse(
              await _client.resizeSession(
                sessionId: sessionId,
                rows: replayTargetSize.$1,
                cols: replayTargetSize.$2,
              ),
            );
            if (resizedSnapshot != null) {
              finalSnapshot = resizedSnapshot;
            }
          } catch (_) {}
        }
        await _applySnapshotToSession(session, sessionId, finalSnapshot);
      }
    } catch (_) {}
  }

  String? _sessionIdFor(SessionVm session) {
    final parts = session.title.split(' / ');
    return parts.length > 1 ? parts[1] : null;
  }

  void _createSession(NewSessionShell preferredShell) async {
    if (_client.isConnected) {
      final fallbackShell = switch (preferredShell) {
        NewSessionShell.cmd => NewSessionShell.bash,
        NewSessionShell.bash => NewSessionShell.cmd,
        NewSessionShell.defaultPosix => null,
      };
      setState(() {
        _newSessionShell = preferredShell;
        _connectionStatus = 'Creating session...';
        _connectionStatusColor = const Color(0xffffc857);
      });
      String sessionId = '';
      String? subId;
      try {
        try {
          sessionId = await _client.startSession(
            command: preferredShell.command,
            args: preferredShell.args,
          );
        } catch (_) {
          if (fallbackShell == null) {
            rethrow;
          }
          sessionId = await _client.startSession(
            command: fallbackShell.command,
            args: fallbackShell.args,
          );
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

          final plainRows = _plainRowsFromSnapshot(snapshot);
          final exited = snapshot?['exited'] as bool? ?? false;
          final sizeObj = snapshot?['size'] as Map<String, dynamic>?;
          final cols = sizeObj?['cols'] as int? ?? 80;
          final rowsVal = sizeObj?['rows'] as int? ?? 24;
          final outputSeq = snapshot?['output_seq'] as int? ?? 0;

          final session = SessionVm(
            title: 'triage / $sessionId',
            branch: branch,
            status: exited ? 'exited' : 'attached',
            statusColor: exited
                ? const Color(0xff7f8b8d)
                : const Color(0xff7fd1c7),
            icon: Icons.terminal,
            rows: plainRows.isEmpty
                ? [_plainRow('Attached to session $sessionId')]
                : plainRows,
            outputSeq: outputSeq,
            isRemote: true,
            isExited: exited,
          );
          _setupSessionInputListener(session);
          session.applyHistory(
            _rawOutputFromSnapshot(snapshot ?? const {}),
            cols: cols,
            rows: rowsVal,
            throughOutputSeq: outputSeq,
          );

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
          unawaited(
            _refreshSessionSnapshot(
              session,
              includeHistory: true,
            ),
          );
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
    final sessionId = session.remoteSessionId;

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
        session.dispose();
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
              width: 520,
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
                deviceCode: _pairingDeviceCode,
                verificationUri: _pairingVerificationUri,
                expiresAt: _pairingExpiresAt,
                isChallengeLoading: _pairingChallengeLoading,
                challengeError: _pairingChallengeError,
                onRefreshChallenge: () => _requestPairingChallenge(),
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
              selectedShell: _newSessionShell,
              shellOptions: newSessionShellMenuOrderForPlatform(
                defaultTargetPlatform,
              ),
              showShellMenu: showNewSessionShellMenuForPlatform(
                defaultTargetPlatform,
              ),
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
    required this.selectedShell,
    required this.shellOptions,
    required this.showShellMenu,
    required this.connectionStatus,
    required this.connectionStatusColor,
    required this.isCollapsed,
    required this.onToggleCollapse,
  });

  final List<SessionVm> sessions;
  final int selectedIndex;
  final ValueChanged<int> onSelectSession;
  final ValueChanged<NewSessionShell> onCreateSession;
  final NewSessionShell selectedShell;
  final List<NewSessionShell> shellOptions;
  final bool showShellMenu;
  final String connectionStatus;
  final Color connectionStatusColor;
  final bool isCollapsed;
  final VoidCallback onToggleCollapse;

  @override
  Widget build(BuildContext context) {
    final railWidth = isCollapsed
        ? _sessionRailCollapsedWidth
        : _sessionRailExpandedWidth;

    return AnimatedContainer(
      duration: _sessionRailAnimationDuration,
      curve: Curves.easeOutCubic,
      width: railWidth,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(color: Color(0xff151a1d)),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            alignment: Alignment.topLeft,
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          );
        },
        child: OverflowBox(
          key: ValueKey<bool>(isCollapsed),
          alignment: Alignment.topLeft,
          minWidth: railWidth,
          maxWidth: railWidth,
          child: SizedBox(
            width: railWidth,
            child: isCollapsed ? _buildCollapsedRail() : _buildExpandedRail(),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsedRail() {
    if (isCollapsed) {
      return Column(
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
          _NewSessionMenu(
            selectedShell: selectedShell,
            shellOptions: shellOptions,
            showShellMenu: showShellMenu,
            onCreateSession: onCreateSession,
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
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildExpandedRail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 10, 16),
          child: Row(
            children: [
              const Icon(Icons.terminal, size: 24, color: Color(0xff7fd1c7)),
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
              _NewSessionMenu(
                selectedShell: selectedShell,
                shellOptions: shellOptions,
                showShellMenu: showShellMenu,
                onCreateSession: onCreateSession,
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

class _NewSessionMenu extends StatelessWidget {
  const _NewSessionMenu({
    required this.selectedShell,
    required this.shellOptions,
    required this.showShellMenu,
    required this.onCreateSession,
  });

  final NewSessionShell selectedShell;
  final List<NewSessionShell> shellOptions;
  final bool showShellMenu;
  final ValueChanged<NewSessionShell> onCreateSession;

  @override
  Widget build(BuildContext context) {
    if (!showShellMenu || shellOptions.length <= 1) {
      final shell = shellOptions.isEmpty ? selectedShell : shellOptions.first;
      return IconButton(
        tooltip: 'New session',
        icon: const Icon(Icons.add, color: Color(0xffcdd7d6)),
        onPressed: () => onCreateSession(shell),
      );
    }

    return PopupMenuButton<NewSessionShell>(
      tooltip: 'New session',
      icon: const Icon(Icons.add, color: Color(0xffcdd7d6)),
      onSelected: onCreateSession,
      itemBuilder: (context) => [
        for (final shell in shellOptions)
          CheckedPopupMenuItem<NewSessionShell>(
            value: shell,
            checked: shell == selectedShell,
            child: Text('${shell.label} (${shell.command})'),
          ),
      ],
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
            terminal: session.terminal,
            fallbackRows: session.rows,
            onTerminalResizeBind: (callback) {
              session.onTerminalResize = callback;
            },
            onViewFit: (cols, rows) => session.noteViewFit(cols, rows),
            focusCursorRevision: session.focusCursorRevision,
            isExited: session.status == 'exited',
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
  const _PairingView({
    required this.deviceCode,
    required this.verificationUri,
    required this.expiresAt,
    required this.isChallengeLoading,
    required this.challengeError,
    required this.onRefreshChallenge,
    required this.onPair,
    required this.onCancel,
  });

  final String? deviceCode;
  final Uri? verificationUri;
  final DateTime? expiresAt;
  final bool isChallengeLoading;
  final String? challengeError;
  final Future<void> Function() onRefreshChallenge;
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

  String _expiryLabel(DateTime? expiresAt) {
    if (expiresAt == null) return '';
    final hour = expiresAt.hour.toString().padLeft(2, '0');
    final minute = expiresAt.minute.toString().padLeft(2, '0');
    return 'Expires at $hour:$minute';
  }

  Future<void> _copyText(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        duration: const Duration(milliseconds: 1400),
      ),
    );
  }

  Future<void> _openVerificationUri(Uri uri) async {
    final opened = await openExternalUri(uri);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          opened ? 'Verification page opened' : 'Open this URL in a browser',
        ),
        duration: const Duration(milliseconds: 1400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deviceCode = widget.deviceCode;
    final verificationUri = widget.verificationUri;
    final hasVerificationUri = verificationUri != null;
    final expiryLabel = _expiryLabel(widget.expiresAt);

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
        Text(
          hasVerificationUri
              ? 'This browser is not paired with the Triage daemon. Open the verification URL, enter this device code to get a PIN, then enter the PIN below.'
              : 'This browser is not paired with the Triage daemon. Approve pairing from the computer running triaged, then enter the PIN below.',
          style: const TextStyle(
            color: Color(0xffa5b1b4),
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 18),
        if (widget.isChallengeLoading && deviceCode == null)
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xff7fd1c7)),
              ),
            ),
          )
        else ...[
          if (hasVerificationUri) ...[
            const Text(
              'Verification URL',
              style: TextStyle(color: Color(0xff7f8b8d), fontSize: 12),
            ),
            const SizedBox(height: 6),
            Tooltip(
              message: 'Open verification URL',
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _openVerificationUri(verificationUri!),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      verificationUri.toString(),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor: const Color(0xff7fd1c7),
                    side: const BorderSide(color: Color(0xff344145)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ),
          ] else ...[
            const Text(
              'Local approval required',
              style: TextStyle(color: Color(0xff7f8b8d), fontSize: 12),
            ),
            const SizedBox(height: 6),
            const Text(
              'Use the daemon host pairing page or run triage pair.',
              style: TextStyle(color: Color(0xffcdd7d6), fontSize: 14),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xff101517),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xff344145)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Device Code',
                        style: TextStyle(
                          color: Color(0xff7f8b8d),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              deviceCode ?? '--------',
                              style: const TextStyle(
                                color: Color(0xffedf7f6),
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 4,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Copy device code',
                            onPressed: deviceCode == null
                                ? null
                                : () => _copyText('Device code', deviceCode),
                            icon: const Icon(Icons.copy, size: 20),
                            color: const Color(0xff7fd1c7),
                          ),
                        ],
                      ),
                      if (expiryLabel.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          expiryLabel,
                          style: const TextStyle(
                            color: Color(0xff7f8b8d),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                onPressed: widget.isChallengeLoading
                    ? null
                    : () => widget.onRefreshChallenge(),
                icon: widget.isChallengeLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xff7fd1c7),
                          ),
                        ),
                      )
                    : const Icon(Icons.refresh),
                tooltip: 'Refresh device code',
                color: const Color(0xffcdd7d6),
              ),
            ],
          ),
        ],
        if (widget.challengeError != null) ...[
          const SizedBox(height: 12),
          Text(
            widget.challengeError!,
            style: const TextStyle(color: Color(0xffff6b6b), fontSize: 13),
          ),
        ],
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
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 12,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: _isLoading ? null : widget.onCancel,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xff7f8b8d),
              ),
              child: const Text('Cancel (Offline Mode)'),
            ),
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
