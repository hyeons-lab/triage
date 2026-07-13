import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:triage_client/services/external_navigation.dart';
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:xterm/xterm.dart' as xt;
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/widgets/terminal_pane.dart';
import 'package:triage_client/services/storage.dart';
import 'package:triage_client/terminal/terminal_intent.dart';
import 'package:triage_client/terminal/terminal_store.dart';
import 'package:triage_client/terminal/terminal_controller_sink.dart';
// Process-env access (home dir, marquee gating) behind a conditional import so
// the web client — which has no `dart:io` — compiles against web stubs.
import 'package:triage_client/platform_env_io.dart'
    if (dart.library.js_util) 'package:triage_client/platform_env_web.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Restore the persisted client id / pairing token from secure storage before
  // the first frame so the app can reconnect without re-pairing on each launch.
  await loadCredentials();
  // Restore the saved daemon address so we auto-connect (or, on first run, show
  // the connection screen).
  final savedAddress = await loadDaemonAddress();
  runApp(TriageClientApp(initialDaemonAddress: savedAddress));
}

const int _defaultDaemonPort = 7777;

/// shared_preferences key holding the raw daemon address the user entered.
const String _daemonAddressPrefKey = 'daemon_address_v1';

/// Parses a user-entered daemon address into a WebSocket [Uri], or null if it
/// can't be normalized. Accepts a bare host/IP (`host` → `ws://host:7777/ws`),
/// `host:port`, a bracketed IPv6 literal (`[::1]:7777`), or a full
/// `ws://`/`wss://`/`http://`/`https://` URL (http→ws, https→wss; path defaults
/// to `/ws`, port to 7777).
@visibleForTesting
Uri? parseDaemonAddress(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return null;

  final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(raw);
  if (hasScheme) {
    final parsed = Uri.tryParse(raw);
    if (parsed == null || parsed.host.isEmpty) return null;
    final scheme = switch (parsed.scheme.toLowerCase()) {
      'ws' || 'http' => 'ws',
      'wss' || 'https' => 'wss',
      _ => null,
    };
    if (scheme == null) return null;
    final port = parsed.hasPort ? parsed.port : _defaultDaemonPort;
    final path = (parsed.path.isEmpty || parsed.path == '/')
        ? '/ws'
        : parsed.path;
    return Uri(
      scheme: scheme,
      host: parsed.host,
      port: port,
      path: path,
      query: parsed.hasQuery ? parsed.query : null,
      fragment: parsed.hasFragment ? parsed.fragment : null,
    );
  }

  String host;
  var port = _defaultDaemonPort;
  final bracketedV6 = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(raw);
  if (bracketedV6 != null) {
    host = bracketedV6.group(1)!;
    final portStr = bracketedV6.group(2);
    if (portStr != null) {
      final p = int.tryParse(portStr);
      if (p == null || p < 1 || p > 65535) return null;
      port = p;
    }
  } else {
    final colons = ':'.allMatches(raw).length;
    if (colons == 1) {
      final idx = raw.indexOf(':');
      host = raw.substring(0, idx);
      final p = int.tryParse(raw.substring(idx + 1));
      if (p == null || p < 1 || p > 65535) return null;
      port = p;
    } else {
      // 0 colons → host/IPv4; 2+ colons → bare IPv6 literal (default port).
      host = raw;
    }
  }
  if (host.isEmpty) return null;
  return Uri(scheme: 'ws', host: host, port: port, path: '/ws');
}

/// Loads the saved raw daemon address, or null if none / on error.
Future<String?> loadDaemonAddress() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_daemonAddressPrefKey);
    return (value != null && value.trim().isNotEmpty) ? value : null;
  } catch (_) {
    return null;
  }
}

/// Persists the raw daemon address the user entered. Best-effort.
Future<void> saveDaemonAddress(String address) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_daemonAddressPrefKey, address);
  } catch (_) {}
}

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
  const TriageClientApp({super.key, this.client, this.initialDaemonAddress});

  final TriageWebSocketClient? client;
  // Raw saved daemon address (host/IP/URL) restored at startup. Null on first
  // run → the connection screen is shown instead of auto-connecting.
  final String? initialDaemonAddress;

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
      home: TriageHome(
        client: client,
        initialDaemonAddress: initialDaemonAddress,
      ),
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
    required this.status,
    required this.statusColor,
    required this.icon,
    required this.rows,
    this.branch,
    this.repoRoot,
    this.worktreeRoot,
    this.cwd,
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
  // Git context for this session, from the snapshot context and refreshed live
  // via `session_context_updated` pushes. All null when the session isn't in a
  // git repo (or the host is too old to report context).
  String? branch;
  // Absolute git repository root and worktree root for this session.
  String? repoRoot;
  String? worktreeRoot;
  // Absolute current working directory, shown in the rail in place of the git
  // line when the session isn't inside a repo. Mutable so live context pushes
  // can update it without recreating the view-model.
  String? cwd;
  String status;
  Color statusColor;
  // Local-LLM one-line description of what the session is doing, shown in the
  // side rail. Null until the daemon generates one (or summarization is off).
  String? snippet;
  // Local-LLM longer-form summary for the hover popover / future search. Null
  // until the daemon generates one (or summarization is off).
  String? snippetDetail;

  /// Last path segment of [repoRoot], for compact display (e.g. "triage").
  String? get repoName => _leafOf(repoRoot);

  /// Last path segment of [worktreeRoot], for compact display. Null when it is
  /// the repo root itself (not a separate worktree) so the rail can hide it.
  String? get worktreeName {
    final wt = worktreeRoot;
    if (wt == null || wt.isEmpty || wt == repoRoot) return null;
    return _leafOf(wt);
  }

  static String? _leafOf(String? path) {
    if (path == null || path.isEmpty) return null;
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final slash = trimmed.lastIndexOf('/');
    final leaf = slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
    return leaf.isEmpty ? null : leaf;
  }

  /// Human-facing name for the rail/header, so sessions are identifiable at a
  /// glance instead of all reading "triage / session-NN". Prefers
  /// "repo · worktree", falls back to "repo · branch" when there is no distinct
  /// worktree, then the working-directory leaf, then the stable [title]
  /// ("triage / <id>"). Distinct from [title], which stays an identity key.
  String get displayTitle {
    final repo = repoName;
    if (repo != null) {
      final wt = worktreeName;
      if (wt != null) return '$repo · $wt';
      final b = branch;
      if (b != null && b.trim().isNotEmpty) return '$repo · ${b.trim()}';
      return repo;
    }
    final cwdLeaf = _leafOf(cwd);
    if (cwdLeaf != null) return cwdLeaf;
    // No git context and no cwd: fall back to the stable title ("triage /
    // <id>") rather than a bare id, so a context-less session still reads
    // sensibly.
    return title;
  }

  final IconData icon;
  // Plain visible rows kept for the test fallback view and demo seeding only;
  // real rendering goes through [store]/[terminal] from raw bytes.
  final List<StyledRow> rows;
  final TerminalController terminalController;
  final bool isRemote;
  bool isExited;
  // True once this remote session has been subscribed/attached (lazy-loaded).
  // Non-selected sessions stay unloaded until the user opens them.
  bool loaded = false;
  int focusCursorRevision = 0;
  int? lastFittedCols;
  int? lastFittedRows;
  // Set once the view first reports its real fitted size after a fresh attach.
  // Gates the one-shot host re-sync to that size (see `_onSessionViewFit`).
  bool hasFitted = false;
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
  /// size (see [noteViewFit]) and replays at that size — the host capture size
  /// is intentionally not used. Live chunks at or below [throughOutputSeq] are
  /// dropped by the store as duplicates.
  void applyHistory(List<int> rawOutput, {int? throughOutputSeq}) {
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
  const TriageHome({super.key, this.client, this.initialDaemonAddress});

  final TriageWebSocketClient? client;
  final String? initialDaemonAddress;

  @override
  State<TriageHome> createState() => _TriageHomeState();
}

class _TriageHomeState extends State<TriageHome> with WidgetsBindingObserver {
  late TriageWebSocketClient _client;
  // Remote session ids currently being attached (lazy-load), so a repeated
  // select can't open a second subscription for the same session.
  final Set<String> _loadingSessionIds = {};
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
  // Resolved daemon WebSocket URI + the raw address the user entered. Null until
  // a saved/entered address is resolved (then the connection screen is shown).
  Uri? _daemonUri;
  String? _daemonAddressRaw;
  // True when there is no daemon address yet (first run, native) — render the
  // connection screen instead of auto-connecting.
  bool _needsConnectionConfig = false;
  String _connectionStatus = 'Offline (Local Mock)';
  Color _connectionStatusColor = const Color(0xff7f8b8d);
  late final String _clientId;
  final Map<String, String> _subscriptionIds = {};
  // Session ids with an in-flight snapshot refresh. A refresh clears and
  // re-emulates the terminal from history, so two concurrent refreshes for the
  // same session race and the second blanks the first (e.g. the select + first
  // view-fit refreshes that both fire on a session's initial load).
  final Set<String> _refreshInFlight = {};
  final Map<String, List<Map<String, dynamic>>> _pendingEvents = {};
  final Queue<Map<String, dynamic>> _websocketEventQueue = Queue();
  bool _websocketProcessingEvent = false;

  late final List<SessionVm> _sessions;
  int _selectedIndex = 0;
  // Per-device side-rail order (remote session ids), loaded once at startup and
  // read synchronously when sessions load so the load path never awaits prefs.
  List<String> _savedSessionOrder = const [];
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

  // True while the app is occluded (screen sleep / hidden / backgrounded). Gates
  // the resume redraw so we only repaint after genuine occlusion, not on every
  // desktop focus change.
  bool _wasOccluded = false;

  // Wall-clock watchdog for system sleep. macOS does not background a running app
  // on display/system sleep, so the lifecycle hook may never fire — but the
  // process IS frozen during system sleep, which stalls this periodic timer. A
  // tick that arrives far later than its interval means we just woke; redraw then.
  Timer? _wakeWatchdogTimer;
  DateTime _lastWatchdogTick = DateTime.now();
  static const Duration _wakeWatchdogInterval = Duration(seconds: 4);
  static const Duration _wakeWatchdogGap = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Restore the per-device side-rail order in the background; it's read
    // synchronously from the cache when sessions load.
    unawaited(_restoreSessionOrder());
    _lastWatchdogTick = DateTime.now();
    _wakeWatchdogTimer = Timer.periodic(_wakeWatchdogInterval, (_) {
      final now = DateTime.now();
      final gap = now.difference(_lastWatchdogTick);
      _lastWatchdogTick = now;
      if (gap > _wakeWatchdogGap) {
        _refitActiveSession();
        _refocusActiveSessionOnResume();
      }
    });
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
      ),
    ];
    for (final s in _sessions) {
      _setupSessionInputListener(s);
      // Seed the demo/local sessions into the store's live phase so their
      // placeholder content renders and local echo works through one pipeline.
      s.applyHistory(_seedBytesFromRows(s.rows));
    }
    final isMockMode = Uri.base.queryParameters['mock'] == 'true';
    if (isMockMode) {
      _connectionStatus = 'Offline (Local Mock)';
      _connectionStatusColor = const Color(0xff7f8b8d);
    } else if (widget.client != null) {
      // Injected client (tests) connects directly, bypassing address config.
      _connectWebSocket();
    } else {
      // Resolve the saved daemon address. With one, auto-connect; on first run
      // (native) show the connection screen so the user picks a host. Web is
      // served by the daemon, so derive the URL from the page and connect.
      final raw = widget.initialDaemonAddress;
      final uri = raw == null ? null : parseDaemonAddress(raw);
      if (uri != null) {
        _daemonUri = uri;
        _daemonAddressRaw = raw;
        _connectWebSocket();
      } else if (kIsWeb) {
        _connectWebSocket();
      } else {
        _needsConnectionConfig = true;
        _connectionStatus = 'Not connected';
      }
    }
  }

  /// Applies a new daemon address: persists it, then tears down any existing
  /// connection and reconnects to the new host. Called from the connection
  /// screen / settings dialog after the input validates.
  Future<void> _applyDaemonAddress(String raw) async {
    final uri = parseDaemonAddress(raw);
    if (uri == null) return;
    await saveDaemonAddress(raw);
    if (!mounted) return;
    setState(() {
      _daemonUri = uri;
      _daemonAddressRaw = raw;
      _needsConnectionConfig = false;
      _needsPairing = false;
      _reconnectAttempt = 0;
    });
    // _connectWebSocket bumps the generation and disconnects any prior client.
    _connectWebSocket();
  }

  /// Opens the connection settings dialog (gear icon / connect-failure action).
  Future<void> _openConnectionSettings() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (context) =>
          ConnectionSettingsDialog(initialAddress: _daemonAddressRaw),
    );
    if (raw != null && raw.trim().isNotEmpty) {
      await _applyDaemonAddress(raw.trim());
    }
  }

  // After waking from sleep / un-hiding, the active terminal's buffer is wrapped
  // for a host PTY width that drifted from our view width, so the frame fragments
  // (words split mid-token, lines re-wrapped narrow). A manual resize fixes it
  // because it forces the host program to repaint over the live byte stream at
  // our width. Reproduce that on resume. Gated on prior occlusion so we don't
  // do it on every desktop focus change.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _wasOccluded = true;
        break;
      case AppLifecycleState.resumed:
        if (_wasOccluded) {
          _wasOccluded = false;
          // The lifecycle event handles this wake; reset the watchdog baseline so
          // its next tick doesn't also see the sleep gap and heal a second time.
          _lastWatchdogTick = DateTime.now();
          _refitActiveSession();
          _refocusActiveSessionOnResume();
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  // Re-assert this device's terminal size on the shared PTY and force a repaint.
  // Called on resume-from-occlusion and from the header "refit" button, so a user
  // switching between devices (each with its own width) can reclaim the PTY for
  // the device they are now on. Mimics a manual resize: jiggle the host PTY size
  // (one row shorter, then back to our real size) so the program receives
  // SIGWINCH and repaints over the live stream at our current width. We
  // deliberately do NOT replay history — re-emulating the raw-output tail
  // re-introduces the width-mismatched/truncated frame, which is what makes it
  // render correctly and then switch to incorrect. A same-size resize sends no
  // SIGWINCH, so the jiggle guarantees a repaint even when the host already
  // believes it is at our size.
  void _refitActiveSession() {
    // `_client` is `late` and only assigned by _connectWebSocket; in mock mode it
    // is never set, so guard on _clientInitialized before touching it.
    if (_disposed || !_clientInitialized || _sessions.isEmpty) return;
    if (!_client.isConnected) return;
    if (_selectedIndex < 0 || _selectedIndex >= _sessions.length) return;
    final session = _selectedSession;
    if (!session.isRemote || session.status != 'attached') return;
    final sessionId = _sessionIdFor(session);
    if (sessionId == null) return;
    // Target the xterm's ACTUAL grid size — the one true width the client renders
    // at. lastFittedCols can be polluted by host-size broadcasts from other
    // controllers, so jiggling to it repaints the program at the wrong width and
    // the frame stays fragmented. Matching the host to terminal.viewWidth makes
    // the program repaint at exactly our render width.
    final cols = session.terminal.viewWidth;
    final rows = session.terminal.viewHeight;
    if (cols < 2 || rows < 2) return;
    unawaited(() async {
      try {
        await _client.resizeSession(
          sessionId: sessionId,
          cols: cols,
          rows: rows - 1,
        );
        if (_disposed) return;
        await _client.resizeSession(
          sessionId: sessionId,
          cols: cols,
          rows: rows,
        );
      } catch (_) {}
    }());
  }

  // Resuming from sleep/occlusion drops the terminal's keyboard focus, so the
  // active session silently ignores input until the user switches sessions and
  // back. Re-request focus here through the same channel that the session
  // switch uses: bumping the session's focus revision makes the pane refocus on
  // its next rebuild (honored by both the native and web panes). Kept separate
  // from the resize-heal above so it also covers local / not-yet-attached
  // sessions, which that path intentionally skips.
  void _refocusActiveSessionOnResume() {
    if (_disposed || !mounted || _sessions.isEmpty) return;
    if (_selectedIndex < 0 || _selectedIndex >= _sessions.length) return;
    setState(() {
      _selectedSession.focusCursorOnNextDisplay();
    });
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
      // While the store replays history, the emulator auto-answers the
      // program's own terminal queries (DSR/cursor reports) re-fed from the
      // tail. Those answers surface here as emulator output; they must not be
      // forwarded to the host as fake user input.
      if (session.store.isSuppressingHostInput) {
        return;
      }
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
        widget.client ??
        TriageWebSocketClient(_daemonUri ?? _defaultWebSocketUri());
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
      final rawSessionIds = await _client.listSessions();
      // Apply the per-device saved order (cached at startup) before building
      // rows so selection, history-on-load, and rendering all flow from the
      // displayed order. Read synchronously — never await prefs on this path.
      final sessionIds = _applySavedOrder(rawSessionIds, _savedSessionOrder);
      if (_disposed) return;
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
        for (var i = 0; i < sessionIds.length; i++) {
          // Only the selected session loads now; the rest rest as rail rows
          // until selected (see the lazy-load note below).
          final session = _loadingDaemonSession(
            sessionIds[i],
            loading: i == targetSelectedIndex,
          );
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

      // Lazy-load: subscribe/attach ONLY the selected session on connect. The
      // rest stay as lightweight rail rows (title + snippet + git context from
      // the list calls) and load on demand when selected. Subscribing to every
      // session at once saturates the single WebSocket and the requests time out
      // over a network link — the "reconnect fails / load failed until I keep
      // switching sessions" storm — and only one session is ever shown at a time.
      if (sessionIds.isNotEmpty) {
        await _loadDaemonSessionInto(
          sessionIds[targetSelectedIndex],
          includeHistory: true,
          failedSessionIds: failedSessionIds,
        );
      }

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

      // Seed side-rail snippets and git context for all sessions (best-effort).
      // Context gives every session a "repo · worktree" title immediately;
      // snippets add the one-line summary. Live updates arrive via push events.
      // Independent best-effort requests — run concurrently to save a connect
      // round-trip (matters on high-latency mobile links).
      await Future.wait([_seedSessionSnippets(), _seedSessionContexts()]);

      // The active session re-syncs to its real width on its first view fit
      // (_onSessionViewFit). Doing it here would use an estimated size, since
      // the terminal view has not laid out yet.
    } catch (_) {
      // Fallback
    }
  }

  Future<void> _seedSessionSnippets() async {
    try {
      final snippets = await _client.listSessionSnippets();
      if (_disposed || snippets.isEmpty) return;
      setState(() {
        for (final session in _sessions) {
          final sid = session.remoteSessionId;
          final entry = sid == null ? null : snippets[sid];
          if (entry != null) {
            session.snippet = entry.snippet;
            session.snippetDetail = entry.detail;
          }
        }
      });
    } catch (_) {
      // Snippets are best-effort metadata; ignore failures.
    }
  }

  // Seed each session's git context on connect so the rail title reads
  // "repo · worktree" for every session immediately, instead of waiting for a
  // per-session load (which may never happen / may time out). Only sets the git
  // fields — the bulk response carries no cwd; live cwd arrives via
  // `session_context_updated`. Best-effort: an older daemon errors on the
  // unknown request, which is swallowed here.
  Future<void> _seedSessionContexts() async {
    try {
      final contexts = await _client.listSessionContexts();
      if (_disposed || contexts.isEmpty) return;
      setState(() {
        for (final session in _sessions) {
          final sid = session.remoteSessionId;
          final entry = sid == null ? null : contexts[sid];
          if (entry != null) {
            session.repoRoot = entry.repositoryRoot;
            session.worktreeRoot = entry.worktreeRoot;
            session.branch = entry.branch;
          }
        }
      });
    } catch (_) {
      // Context is best-effort rail metadata; a daemon without the request
      // (pre-upgrade) just leaves titles on their session-id fallback.
    }
  }

  // Placeholder rail row for a daemon session. [loading] true means it is being
  // attached now (the selected session); false is the lazy resting state for
  // sessions not yet opened — a muted row that carries only rail metadata until
  // the user selects it, at which point `_loadDaemonSessionInto` attaches it.
  SessionVm _loadingDaemonSession(String sessionId, {bool loading = true}) {
    return SessionVm(
      title: 'triage / $sessionId',
      status: loading ? 'loading' : 'idle',
      statusColor: loading
          ? const Color(0xffffc857)
          : const Color(0xff7f8b8d),
      icon: Icons.terminal,
      rows: loading ? [_plainRow('Loading session $sessionId...')] : const [],
      isRemote: true,
    );
  }

  // Attaches one daemon session (subscribe + attach + snapshot) and swaps it into
  // the rail in place, or marks it failed. Guarded against concurrent re-entry so
  // a double-select can't open two subscriptions. Extracted so both the connect
  // path and on-demand selection load a session the same way.
  Future<void> _loadDaemonSessionInto(
    String sid, {
    required bool includeHistory,
    required List<String> failedSessionIds,
  }) async {
    if (_loadingSessionIds.contains(sid)) return;
    _loadingSessionIds.add(sid);
    // Show the row as loading (covers the on-demand-select case, where the row
    // was resting).
    if (!_disposed) {
      setState(() {
        final i = _sessions.indexWhere((s) => s.remoteSessionId == sid);
        if (i != -1 && !_sessions[i].loaded) {
          _sessions[i].status = 'loading';
          _sessions[i].statusColor = const Color(0xffffc857);
        }
      });
    }
    try {
      final session = await _loadDaemonSession(sid, includeHistory: includeHistory);
      session.loaded = true;
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
    } finally {
      _loadingSessionIds.remove(sid);
    }
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
      // Fall back to the prepared snapshot only when it carries history: the
      // restore path's snapshot does, but a resize snapshot never does, and
      // replaying its empty history would clear the terminal to a blank screen.
      if (replayTargetSize != null &&
          preparedSnapshot != null &&
          _rawOutputFromSnapshot(preparedSnapshot).isNotEmpty &&
          !_snapshotSizeMatches(snapshot, replayTargetSize)) {
        snapshot = preparedSnapshot;
      }

      final contextObj = snapshot?['context'] as Map<String, dynamic>?;
      final branch = contextObj?['branch']?.toString();
      final repoRoot = contextObj?['repository_root']?.toString();
      final worktreeRoot = contextObj?['worktree_root']?.toString();
      final cwd = snapshot?['current_working_directory']?.toString();

      final plainRows = _plainRowsFromSnapshot(snapshot);
      final exited = snapshot?['exited'] as bool? ?? false;
      final outputSeq = snapshot?['output_seq'] as int? ?? 0;

      final session = SessionVm(
        title: 'triage / $sid',
        branch: branch,
        repoRoot: repoRoot,
        worktreeRoot: worktreeRoot,
        cwd: cwd,
        status: exited ? 'exited' : 'attached',
        statusColor: exited ? const Color(0xff7f8b8d) : const Color(0xff7fd1c7),
        icon: Icons.terminal,
        rows: plainRows.isEmpty
            ? [_plainRow('Attached to session $sid')]
            : plainRows,
        isRemote: true,
        isExited: exited,
      );
      // Snapshot carries the current snippet for the attached session (the list
      // seed + push events cover the rest).
      session.snippet = snapshot?['snippet'] as String?;
      session.snippetDetail = snapshot?['snippet_detail'] as String?;
      // Replay the raw output-history tail through the single write path. Live
      // chunks already covered by this snapshot are dropped by output_seq.
      session.applyHistory(
        _rawOutputFromSnapshot(snapshot ?? const {}),
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

    if (type == 'session_snippet_updated') {
      final sessionId = message['session_id'] as String?;
      if (sessionId == null) return;
      final snippet = message['snippet'] as String?;
      final detail = message['detail'] as String?;
      final index = _sessions.indexWhere((s) => s.remoteSessionId == sessionId);
      if (index == -1) return;
      void apply() {
        _sessions[index].snippet = snippet;
        // A regeneration always reports the current detail; null means the
        // detail pass produced nothing this round, so clear the stale one.
        _sessions[index].snippetDetail = detail;
      }

      if (mounted) {
        setState(apply);
      } else {
        apply();
      }
      return;
    }

    if (type == 'session_context_updated') {
      final sessionId = message['session_id'] as String?;
      if (sessionId == null) return;
      final index = _sessions.indexWhere((s) => s.remoteSessionId == sessionId);
      if (index == -1) return;
      // Each push carries the full current context, so a null field genuinely
      // means "absent" (e.g. cd'd out of a repo) — assign directly, don't merge.
      void apply() {
        final session = _sessions[index];
        session.cwd = message['current_working_directory']?.toString();
        session.repoRoot = message['repository_root']?.toString();
        session.worktreeRoot = message['worktree_root']?.toString();
        session.branch = message['branch']?.toString();
      }

      if (mounted) {
        setState(apply);
      } else {
        apply();
      }
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

        // Single write path: raw bytes flow through the store, which owns UTF-8
        // carry, CRLF normalization, buffering, and all output_seq
        // de-duplication (against both the history high-water and re-deliveries).
        session.applyLiveBytes(bytes, outputSeq: outputSeq);
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
    Map<String, dynamic> snapshot, {
    (int, int)? renderSize,
  }) async {
    // Bail if this SessionVm was disposed/replaced (e.g. a reconnect ran
    // _loadDaemonSessions) while the refresh was in flight — applying to a
    // disposed store is a use-after-dispose, and the live same-id object is
    // refreshed by its own load path.
    if (_disposed || !_sessions.contains(session)) return;
    final sizeObj = snapshot['size'] as Map<String, dynamic>?;
    final cols = sizeObj?['cols'] as int? ?? 80;
    final rowsVal = sizeObj?['rows'] as int? ?? 24;
    // The grid the content is actually rendered at: the caller's replay target
    // (the view's fitted size) when known, else the snapshot's own size. Using
    // the snapshot size when it carries the *host* width — e.g. the resize
    // branch keeps the host-sized attach snapshot — would poison lastFittedCols
    // and drive the next refresh to resize the host back and forth.
    final fittedCols = renderSize?.$2 ?? cols;
    final fittedRows = renderSize?.$1 ?? rowsVal;
    final rawOutput = _rawOutputFromSnapshot(snapshot);
    final snapshotOutputSeq = snapshot['output_seq'] as int?;
    final exited = snapshot['exited'] as bool? ?? false;

    // Replay history through the single write path — raw PTY bytes, not the
    // lossy styled-row reconstruction. The store clears and re-emulates, then
    // resumes live (de-duplicating by output_seq).
    session.applyHistory(rawOutput, throughOutputSeq: snapshotOutputSeq);

    setState(() {
      // Plain mirror for the test fallback view only; not used for real render.
      session.rows
        ..clear()
        ..addAll(_plainRowsFromSnapshot(snapshot));
      session.isExited = exited;
      session.status = exited ? 'exited' : 'attached';
      session.statusColor = exited
          ? const Color(0xff7f8b8d)
          : const Color(0xff7fd1c7);
      session.lastFittedCols = fittedCols;
      session.lastFittedRows = fittedRows;
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
        final spans =
            (row as Map<String, dynamic>?)?['spans'] as List<dynamic>?;
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
    WidgetsBinding.instance.removeObserver(this);
    _wakeWatchdogTimer?.cancel();
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

  /// The terminal view reported its fitted grid size. Always replay any staged
  /// history at that size; on the *first* fit after a fresh attach, also re-sync
  /// the host to it. The attach snapshot's raw output was authored at the host
  /// PTY width, which may differ from ours — replaying it at our width
  /// wrap-fragments the frame. Resizing the host to our real width (the same
  /// thing the select path does) makes the program redraw at our width and the
  /// live stream paint a clean frame. One-shot per attach so ordinary window
  /// resizes still self-heal through the live stream, not a re-snapshot.
  void _onSessionViewFit(SessionVm session, int cols, int rows) {
    session.lastFittedCols = cols;
    session.lastFittedRows = rows;
    session.noteViewFit(cols, rows);
    if (!session.hasFitted) {
      session.hasFitted = true;
      if (session.isRemote && _client.isConnected) {
        unawaited(_refreshSessionSnapshot(session, includeHistory: true));
      }
    }
  }

  // Client-local, per-device side-rail ordering. Persisted as an ordered list of
  // remote session ids; not shared with the TUI or other clients.
  static const String _sessionOrderKey = 'session_order_v1';

  /// Reorders the side rail in response to a drag, keeping the current
  /// selection pointed at the same session, and persists the new order.
  void _reorderSessions(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _sessions.length) return;
    setState(() {
      // ReorderableListView reports newIndex in the pre-removal coordinate space.
      if (newIndex > oldIndex) newIndex -= 1;
      final selected =
          (_selectedIndex >= 0 && _selectedIndex < _sessions.length)
          ? _sessions[_selectedIndex]
          : null;
      final moved = _sessions.removeAt(oldIndex);
      _sessions.insert(newIndex.clamp(0, _sessions.length), moved);
      if (selected != null) {
        final reselected = _sessions.indexOf(selected);
        if (reselected != -1) _selectedIndex = reselected;
      }
    });
    unawaited(_persistSessionOrder());
  }

  Future<void> _restoreSessionOrder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _savedSessionOrder = prefs.getStringList(_sessionOrderKey) ?? const [];
    } catch (_) {
      // Ordering is a best-effort convenience; ignore load failures.
    }
  }

  Future<void> _persistSessionOrder() async {
    final ids = _sessions
        .map((s) => s.remoteSessionId)
        .whereType<String>()
        .toList();
    _savedSessionOrder = ids;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_sessionOrderKey, ids);
    } catch (_) {
      // Ordering is a best-effort convenience; ignore persistence failures.
    }
  }

  /// Stable-sorts daemon session ids by the saved per-device order: known ids
  /// first in saved order, then any new ids in the daemon's original order.
  List<String> _applySavedOrder(List<String> ids, List<String> savedOrder) {
    if (savedOrder.isEmpty) return ids;
    final rank = <String, int>{
      for (var i = 0; i < savedOrder.length; i++) savedOrder[i]: i,
    };
    final daemonRank = <String, int>{
      for (var i = 0; i < ids.length; i++) ids[i]: i,
    };
    final ordered = [...ids];
    ordered.sort((a, b) {
      final ra = rank[a];
      final rb = rank[b];
      if (ra != null && rb != null) return ra.compareTo(rb);
      if (ra != null) return -1; // known (saved) ids sort before new ones
      if (rb != null) return 1;
      return (daemonRank[a] ?? 0).compareTo(daemonRank[b] ?? 0);
    });
    return ordered;
  }

  void _selectSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    final session = _sessions[index];
    // On a session's first load the view-fit handler issues the initial refresh
    // at the real fitted size; refreshing here too would race it (and use an
    // estimated size). Only refresh on re-select of an already-fitted session.
    final canRefresh =
        _client.isConnected &&
        session.isRemote &&
        _sessionIdFor(session) != null;
    setState(() {
      session.focusCursorOnNextDisplay();
      _selectedIndex = index;
    });
    if (!canRefresh) return;
    // Lazy-load: an unopened session has no live subscription yet (the connect
    // path only attached the initially-selected one), so attach it now instead
    // of refreshing a snapshot it never subscribed to.
    if (!session.loaded) {
      final sid = _sessionIdFor(session);
      if (sid != null) {
        unawaited(
          _loadDaemonSessionInto(
            sid,
            includeHistory: true,
            failedSessionIds: <String>[],
          ),
        );
      }
      return;
    }
    if (session.hasFitted) {
      // Already fitted: refresh now at the known real size.
      unawaited(_refreshSessionSnapshot(session, includeHistory: true));
    } else {
      // Not yet fitted: the first view-fit issues the initial refresh at the
      // real size; refreshing here too would race it with an estimated size.
      // Guard against a pane that never reports a fit (zero-size or a reused
      // pane that skips onViewFit) by refreshing after the frame if it still
      // hasn't fitted, so the session can't be stranded on stale content.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed &&
            !session.hasFitted &&
            identical(_selectedSession, session) &&
            _client.isConnected) {
          unawaited(_refreshSessionSnapshot(session, includeHistory: true));
        }
      });
    }
  }

  Future<void> _refreshSessionSnapshot(
    SessionVm session, {
    bool includeHistory = false,
  }) async {
    if (!_client.isConnected || !session.isRemote) return;
    final sessionId = _sessionIdFor(session);
    if (sessionId == null) return;
    // Coalesce concurrent refreshes for the same session: a second one would
    // clear the terminal and replay history underneath the first, blanking it.
    if (!_refreshInFlight.add(sessionId)) return;
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
            // restoreSession re-spawns a brand-new daemon actor; our prior
            // subscription was bound to the old (now shut-down) actor and
            // receives no further output. Re-subscribe before the fresh attach
            // so live updates from the revived shell keep flowing.
            await _resubscribeSessionEvents(sessionId);
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
          // Resize the host so its program repaints at our width, but keep the
          // history-bearing attach snapshot for rendering. The resize response
          // carries no raw_output (resize snapshots never do), so using it would
          // make applyHistory clear the terminal and blank it; history replays
          // at the fitted size client-side anyway.
          try {
            await _client.resizeSession(
              sessionId: sessionId,
              rows: replayTargetSize.$1,
              cols: replayTargetSize.$2,
            );
          } catch (_) {}
        }
        await _applySnapshotToSession(
          session,
          sessionId,
          finalSnapshot,
          renderSize: replayTargetSize,
        );
      }
    } catch (_) {
    } finally {
      _refreshInFlight.remove(sessionId);
    }
  }

  /// Re-subscribes to a session's events, dropping any stale subscription ids
  /// for it. Used after a restore, whose new daemon actor leaves the previous
  /// subscription bound to a shut-down actor that emits nothing further.
  Future<void> _resubscribeSessionEvents(String sessionId) async {
    _subscriptionIds.removeWhere((_, sid) => sid == sessionId);
    final subId = await _client.subscribeSessionEvents(sessionId: sessionId);
    if (subId.isNotEmpty) {
      _subscriptionIds[subId] = sessionId;
    }
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
          final branch = contextObj?['branch']?.toString();
          final repoRoot = contextObj?['repository_root']?.toString();
          final worktreeRoot = contextObj?['worktree_root']?.toString();
          final cwd = snapshot?['current_working_directory']?.toString();

          final plainRows = _plainRowsFromSnapshot(snapshot);
          final exited = snapshot?['exited'] as bool? ?? false;
          final outputSeq = snapshot?['output_seq'] as int? ?? 0;

          final session = SessionVm(
            title: 'triage / $sessionId',
            branch: branch,
            repoRoot: repoRoot,
            worktreeRoot: worktreeRoot,
            cwd: cwd,
            status: exited ? 'exited' : 'attached',
            statusColor: exited
                ? const Color(0xff7f8b8d)
                : const Color(0xff7fd1c7),
            icon: Icons.terminal,
            rows: plainRows.isEmpty
                ? [_plainRow('Attached to session $sessionId')]
                : plainRows,
            isRemote: true,
            isExited: exited,
          );
          session.snippet = snapshot?['snippet'] as String?;
          session.snippetDetail = snapshot?['snippet_detail'] as String?;
          _setupSessionInputListener(session);
          session.applyHistory(
            _rawOutputFromSnapshot(snapshot ?? const {}),
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
          // Host re-sync to our real width is deferred to the first view fit
          // (_onSessionViewFit); doing it here would use an estimated size,
          // since the terminal view has not laid out yet.
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
    );
    _setupSessionInputListener(session);

    setState(() {
      _createdSessionCount = scratchId;
      _sessions.insert(0, session);
      _selectedIndex = 0;
    });
  }

  Future<void> _closeSession(SessionVm session) async {
    final confirmed = await _confirmCloseSession(session);
    if (confirmed != true) return;

    final sessionId = session.remoteSessionId;

    if (_client.isConnected && sessionId != null) {
      try {
        await _client.shutdownSession(sessionId: sessionId);
      } catch (e) {
        debugPrint('Failed to shutdown session: ${e.toString()}');
      }
    }

    // The dialog and shutdown RPC both await; the State may have been disposed
    // in the meantime, so guard setState to avoid throwing on a dead widget.
    if (!mounted) return;

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

  Future<bool?> _confirmCloseSession(SessionVm session) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xff161b1d),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xff2a3437)),
          ),
          title: const Text(
            'Close session?',
            style: TextStyle(
              color: Color(0xffcdd7d6),
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Text(
            session.isRemote
                ? 'This ends the terminal session "${session.title}" and its '
                      'running processes. This cannot be undone.'
                : 'This closes the terminal session "${session.title}". This '
                      'cannot be undone.',
            style: const TextStyle(color: Color(0xff9aa6a8), height: 1.4),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xff7f8b8d),
              ),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xffb3443f),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Close session'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_needsConnectionConfig) {
      return Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConnectionSettingsForm(
              initialAddress: _daemonAddressRaw,
              submitLabel: 'Connect',
              title: 'Connect to a Triage daemon',
              subtitle:
                  'Enter the host, IP, or URL of the device running triaged. '
                  'For example 100.64.2.7, 192.168.1.5:7777, or '
                  'wss://my-mac.tailnet:7777.',
              onSubmit: (raw) => _applyDaemonAddress(raw),
            ),
          ),
        ),
      );
    }

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

    // On a phone the rail can't sit beside the workspace — it would squeeze the
    // terminal to a sliver. Mobile shows a full-screen workspace with the rail
    // as a scrim-backed overlay that dismisses on select; desktop keeps the
    // side-by-side layout.
    // The widget tests assert the desktop side-by-side layout, so keep it in the
    // test harness even though the default test platform is android.
    final isMobile =
        !runningUnderFlutterTest() &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);

    void collapseRail() {
      if (!_sidebarCollapsed) setState(() => _sidebarCollapsed = true);
    }

    void openRail() {
      if (_sidebarCollapsed) setState(() => _sidebarCollapsed = false);
    }

    final rail = SessionRail(
      sessions: _sessions,
      selectedIndex: _selectedIndex,
      // On mobile, selecting or creating a session dismisses the overlay so the
      // terminal takes the full screen.
      onSelectSession: (index) {
        _selectSession(index);
        if (isMobile) collapseRail();
      },
      onReorderSession: _reorderSessions,
      onCreateSession: (shell) {
        _createSession(shell);
        if (isMobile) collapseRail();
      },
      selectedShell: _newSessionShell,
      shellOptions: newSessionShellMenuOrderForPlatform(defaultTargetPlatform),
      showShellMenu: showNewSessionShellMenuForPlatform(defaultTargetPlatform),
      connectionStatus: _connectionStatus,
      connectionStatusColor: _connectionStatusColor,
      onOpenSettings: _openConnectionSettings,
      // Mobile: the rail always shows full content (the overlay slide handles
      // show/hide) and its collapse button closes the overlay. Desktop: the
      // button shrinks the rail to its icon strip in place.
      isCollapsed: isMobile ? false : _sidebarCollapsed,
      onToggleCollapse: isMobile
          ? collapseRail
          : () {
              setState(() {
                _sidebarCollapsed = !_sidebarCollapsed;
              });
            },
    );

    const emptyWorkspace = Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.terminal, size: 64, color: Color(0xff263033)),
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
            style: TextStyle(fontSize: 14, color: Color(0xff7f8b8d)),
          ),
        ],
      ),
    );

    final workspace = _sessions.isEmpty
        ? emptyWorkspace
        : SessionWorkspace(
            session: _selectedSession,
            onCloseSession: () => _closeSession(_selectedSession),
            onViewFit: (cols, rows) =>
                _onSessionViewFit(_selectedSession, cols, rows),
            // The header's menu button reopens the overlay on mobile only.
            onOpenRail: isMobile ? openRail : null,
            // Manual escape hatch for reclaiming the shared PTY size when
            // switching back to this device (auto-refit only fires on resume).
            onRefit: _refitActiveSession,
          );

    if (isMobile) {
      final screenWidth = MediaQuery.of(context).size.width;
      final overlayWidth = screenWidth < _sessionRailExpandedWidth
          ? screenWidth
          : _sessionRailExpandedWidth;
      return Scaffold(
        body: SafeArea(
          // The rail and scrim stay mounted and animate on the collapsed flag
          // (slide + fade) rather than popping in/out, so open/close is smooth.
          child: Stack(
            children: [
              Positioned.fill(child: workspace),
              // A menu affordance when the rail is dismissed and there is no
              // workspace header to host one (no sessions yet).
              if (_sidebarCollapsed && _sessions.isEmpty)
                Positioned(
                  top: 4,
                  left: 4,
                  child: IconButton(
                    icon: const Icon(Icons.menu, color: Color(0xffcdd7d6)),
                    tooltip: 'Sessions',
                    onPressed: openRail,
                  ),
                ),
              // Scrim: fades in with the rail; ignores taps while collapsed so
              // input passes through to the terminal.
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: _sidebarCollapsed,
                  child: AnimatedOpacity(
                    opacity: _sidebarCollapsed ? 0.0 : 1.0,
                    duration: _sessionRailAnimationDuration,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: collapseRail,
                      child: const ColoredBox(color: Color(0x99000000)),
                    ),
                  ),
                ),
              ),
              // Rail: slides in from the left edge.
              AnimatedPositioned(
                duration: _sessionRailAnimationDuration,
                curve: Curves.easeOutCubic,
                top: 0,
                bottom: 0,
                left: _sidebarCollapsed ? -overlayWidth : 0,
                width: overlayWidth,
                child: Material(
                  elevation: 16,
                  color: const Color(0xff0d1113),
                  child: rail,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            rail,
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: Color(0xff263033),
            ),
            Expanded(child: workspace),
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
    required this.onReorderSession,
    required this.onCreateSession,
    required this.selectedShell,
    required this.shellOptions,
    required this.showShellMenu,
    required this.connectionStatus,
    required this.connectionStatusColor,
    required this.onOpenSettings,
    required this.isCollapsed,
    required this.onToggleCollapse,
  });

  final List<SessionVm> sessions;
  final int selectedIndex;
  final ValueChanged<int> onSelectSession;
  final void Function(int oldIndex, int newIndex) onReorderSession;
  final ValueChanged<NewSessionShell> onCreateSession;
  final NewSessionShell selectedShell;
  final List<NewSessionShell> shellOptions;
  final bool showShellMenu;
  final String connectionStatus;
  final Color connectionStatusColor;
  final VoidCallback onOpenSettings;
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
          const SizedBox(height: 8),
          IconButton(
            onPressed: onOpenSettings,
            tooltip: 'Connection settings',
            icon: const Icon(
              Icons.settings,
              color: Color(0xff7f8b8d),
              size: 20,
            ),
          ),
          const SizedBox(height: 12),
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
              const Expanded(
                child: Text(
                  'Triage',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
              ),
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
              const SizedBox(width: 4),
              IconButton(
                onPressed: onOpenSettings,
                tooltip: 'Connection settings',
                icon: const Icon(
                  Icons.settings,
                  color: Color(0xff7f8b8d),
                  size: 20,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 4),
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
          // Tapping the status opens connection settings — the recovery path
          // when a connect attempt fails.
          child: InkWell(
            onTap: onOpenSettings,
            borderRadius: BorderRadius.circular(8),
            child: _ConnectionStatus(
              status: connectionStatus,
              color: connectionStatusColor,
            ),
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
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            buildDefaultDragHandles: false,
            onReorder: onReorderSession,
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              final key = ValueKey<String>(
                session.remoteSessionId ?? 'local:${session.title}',
              );
              final tile = SessionListTile(
                selected: index == selectedIndex,
                title: session.displayTitle,
                subtitle: session.status,
                statusColor: session.statusColor,
                icon: session.icon,
                branch: session.branch,
                repoName: session.repoName,
                worktreeName: session.worktreeName,
                cwd: session.cwd,
                snippet: session.snippet,
                snippetDetail: session.snippetDetail,
                onTap: () => onSelectSession(index),
              );
              // Touch: a plain drag must scroll the list, so reordering waits for
              // a long-press (ReorderableDelayedDragStartListener). Mouse: the
              // whole row is an immediate drag handle; a click still selects
              // since a tap registers no movement.
              final isTouch =
                  !runningUnderFlutterTest() &&
                  (defaultTargetPlatform == TargetPlatform.iOS ||
                      defaultTargetPlatform == TargetPlatform.android);
              return isTouch
                  ? ReorderableDelayedDragStartListener(
                      key: key,
                      index: index,
                      child: tile,
                    )
                  : ReorderableDragStartListener(
                      key: key,
                      index: index,
                      child: tile,
                    );
            },
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

/// Modal wrapper around [ConnectionSettingsForm]. Pops with the entered raw
/// address (or null if cancelled).
class ConnectionSettingsDialog extends StatelessWidget {
  const ConnectionSettingsDialog({super.key, this.initialAddress});

  final String? initialAddress;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xff161b1d),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConnectionSettingsForm(
            initialAddress: initialAddress,
            submitLabel: 'Connect',
            title: 'Connection settings',
            subtitle:
                'Host, IP, or URL of the device running triaged (e.g. '
                '100.64.2.7 or 192.168.1.5:7777).',
            onCancel: () => Navigator.of(context).pop(),
            onSubmit: (raw) => Navigator.of(context).pop(raw),
          ),
        ),
      ),
    );
  }
}

/// Smart single-field form for the daemon address. Validates input with
/// [parseDaemonAddress] and calls [onSubmit] with the raw (un-normalized) text
/// so the caller can persist exactly what the user typed.
class ConnectionSettingsForm extends StatefulWidget {
  const ConnectionSettingsForm({
    super.key,
    required this.onSubmit,
    this.onCancel,
    this.initialAddress,
    this.submitLabel = 'Connect',
    this.title = 'Connect to a Triage daemon',
    this.subtitle,
  });

  final ValueChanged<String> onSubmit;
  final VoidCallback? onCancel;
  final String? initialAddress;
  final String submitLabel;
  final String title;
  final String? subtitle;

  @override
  State<ConnectionSettingsForm> createState() => _ConnectionSettingsFormState();
}

class _ConnectionSettingsFormState extends State<ConnectionSettingsForm> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialAddress ?? '127.0.0.1',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _controller.text.trim();
    final uri = parseDaemonAddress(raw);
    if (uri == null) {
      setState(
        () => _error =
            'Enter a valid host, host:port, or ws://, wss://, http://, or https:// URL.',
      );
      return;
    }
    widget.onSubmit(raw);
  }

  @override
  Widget build(BuildContext context) {
    final preview = parseDaemonAddress(_controller.text.trim());
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.dns_outlined, color: Color(0xff7fd1c7), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (widget.subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.subtitle!,
            style: const TextStyle(color: Color(0xff9aa6a8), fontSize: 13),
          ),
        ],
        const SizedBox(height: 18),
        TextField(
          controller: _controller,
          autofocus: true,
          onChanged: (_) {
            // Single rebuild: clears any stale error and refreshes the preview.
            setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Daemon address',
            hintText: '100.64.2.7  ·  192.168.1.5:7777  ·  wss://host:7777',
            errorText: _error,
            prefixIcon: const Icon(Icons.lan_outlined, size: 20),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          preview == null ? 'Will connect to: —' : 'Will connect to: $preview',
          style: const TextStyle(color: Color(0xff7f8b8d), fontSize: 12),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (widget.onCancel != null) ...[
              TextButton(
                onPressed: widget.onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
            ],
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.link, size: 18),
              label: Text(widget.submitLabel),
            ),
          ],
        ),
      ],
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

class SessionListTile extends StatefulWidget {
  const SessionListTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.statusColor,
    required this.icon,
    required this.onTap,
    this.branch,
    this.repoName,
    this.worktreeName,
    this.cwd,
    this.snippet,
    this.snippetDetail,
    this.selected = false,
  });

  final String title;
  final String subtitle;
  final Color statusColor;
  final IconData icon;
  final VoidCallback onTap;
  // Git context for the glance row + hover popover; hidden when null.
  final String? branch;
  final String? repoName;
  final String? worktreeName;
  // Absolute current working directory, shown in place of the git line when the
  // session isn't inside a repo.
  final String? cwd;
  // Local-LLM one-line description of the session; hidden when null/empty.
  final String? snippet;
  // Local-LLM longer-form summary, shown in the hover popover.
  final String? snippetDetail;
  final bool selected;

  @override
  State<SessionListTile> createState() => _SessionListTileState();
}

class _SessionListTileState extends State<SessionListTile> {
  final OverlayPortalController _popover = OverlayPortalController();
  final LayerLink _link = LayerLink();

  /// One-line "repo · branch · worktree" summary, omitting absent parts. Null
  /// when the session has no git context — the rail then falls back to the cwd.
  String? get _gitMeta {
    final parts = <String>[
      if (widget.repoName != null) widget.repoName!,
      if (widget.branch != null && widget.branch!.isNotEmpty) widget.branch!,
      if (widget.worktreeName != null && widget.worktreeName != widget.branch)
        widget.worktreeName!,
    ];
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  void _showPopover() {
    if (!_popover.isShowing) _popover.show();
  }

  void _hidePopover() {
    if (_popover.isShowing) _popover.hide();
  }

  @override
  void dispose() {
    _hidePopover();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The rail meta line is the git "repo · branch · worktree" summary when the
    // session is in a repo; otherwise it falls back to the working directory.
    final gitMeta = _gitMeta;
    final cwd = widget.cwd;
    final hasCwdFallback = gitMeta == null && cwd != null && cwd.isNotEmpty;
    final metaIcon = gitMeta != null
        ? Icons.account_tree_outlined
        : Icons.folder_outlined;
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) => _showPopover(),
        onExit: (_) => _hidePopover(),
        child: OverlayPortal(
          controller: _popover,
          overlayChildBuilder: (context) => Positioned(
            width: 320,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(10, 0),
              child: IgnorePointer(
                child: _SessionGlanceCard(
                  title: widget.title,
                  status: widget.subtitle,
                  statusColor: widget.statusColor,
                  repoName: widget.repoName,
                  branch: widget.branch,
                  worktreeName: widget.worktreeName,
                  cwd: widget.cwd,
                  snippet: widget.snippet,
                  detail: widget.snippetDetail,
                ),
              ),
            ),
          ),
          child: Semantics(
            button: true,
            selected: widget.selected,
            label: widget.title,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? const Color(0xff233033)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: widget.selected
                        ? const Color(0xff3b5356)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(widget.icon, size: 20, color: const Color(0xffcdd7d6)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          if (gitMeta != null || hasCwdFallback) ...[
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Icon(
                                  metaIcon,
                                  size: 12,
                                  color: const Color(0xff7f8b8d),
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: _MetaLineText(
                                    // Git meta is already compact (leaf names);
                                    // the cwd fallback shows the absolute path,
                                    // collapsing to ~/… or scrolling when long.
                                    full: gitMeta ?? cwd!,
                                    abbreviated: gitMeta == null
                                        ? _homeAbbreviatedPath(cwd!)
                                        : null,
                                    // Marquee only the selected row, to keep the
                                    // rail quiet (per design).
                                    animate: widget.selected,
                                    style: const TextStyle(
                                      color: Color(0xff8b9799),
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: widget.statusColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  widget.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xff9aa6a8),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (widget.snippet != null &&
                              widget.snippet!.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              widget.snippet!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xff6f7b7d),
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rich hover popover for a session row: full git context + the longer-form
/// LLM detail summary (falls back to the one-liner, then a placeholder).
class _SessionGlanceCard extends StatelessWidget {
  const _SessionGlanceCard({
    required this.title,
    required this.status,
    required this.statusColor,
    required this.repoName,
    required this.branch,
    required this.worktreeName,
    required this.cwd,
    required this.snippet,
    required this.detail,
  });

  final String title;
  final String status;
  final Color statusColor;
  final String? repoName;
  final String? branch;
  final String? worktreeName;
  final String? cwd;
  final String? snippet;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final summary = (detail != null && detail!.isNotEmpty)
        ? detail!
        : (snippet != null && snippet!.isNotEmpty
              ? snippet!
              : 'No summary yet.');
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xff1b2327),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xff334044)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
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
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                Text(
                  status,
                  style: const TextStyle(
                    color: Color(0xff9aa6a8),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (repoName != null)
              _GlanceRow(icon: Icons.folder_outlined, label: repoName!),
            if (branch != null && branch!.isNotEmpty)
              _GlanceRow(icon: Icons.account_tree_outlined, label: branch!),
            if (worktreeName != null && worktreeName != branch)
              _GlanceRow(icon: Icons.alt_route, label: worktreeName!),
            // The full working directory, wrapping across lines so the whole
            // path is readable here even when the rail line had to truncate it.
            if (cwd != null && cwd!.isNotEmpty)
              _GlanceRow(
                icon: Icons.subdirectory_arrow_right,
                label: cwd!,
                wrap: true,
              ),
            if (repoName != null ||
                (branch != null && branch!.isNotEmpty) ||
                worktreeName != null ||
                (cwd != null && cwd!.isNotEmpty))
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Divider(height: 1, color: Color(0xff2b363a)),
              ),
            Text(
              summary,
              style: const TextStyle(
                color: Color(0xffc4cecd),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlanceRow extends StatelessWidget {
  const _GlanceRow({
    required this.icon,
    required this.label,
    this.wrap = false,
  });

  final IconData icon;
  final String label;
  // When true the label wraps across lines instead of truncating — used for the
  // full working-directory path so it stays fully readable in the popover.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: wrap
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 13, color: const Color(0xff7f8b8d)),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              maxLines: wrap ? null : 1,
              overflow: wrap ? TextOverflow.clip : TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xffb4bfc0), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapses a leading local-home prefix to `~` — e.g. `/Users/me/dev` →
/// `~/dev`. Returns null when [path] is not under the local home (e.g. a path
/// from a remote daemon), so callers fall back to showing it in full.
String? _homeAbbreviatedPath(String path) {
  final home = localHomeDir();
  if (home == null || home.isEmpty) return null;
  final normalized = home.endsWith('/')
      ? home.substring(0, home.length - 1)
      : home;
  if (path == normalized) return '~';
  if (path.startsWith('$normalized/')) {
    return '~${path.substring(normalized.length)}';
  }
  return null;
}

/// Renders a single-line meta string that adapts to the available width: shows
/// [full] when it fits; else [abbreviated] (e.g. a `~/…` path) when that fits;
/// else scrolls it as a marquee when [animate] is set, or truncates with an
/// ellipsis. The marquee is reserved for the selected row so the rail stays
/// quiet.
class _MetaLineText extends StatelessWidget {
  const _MetaLineText({
    required this.full,
    required this.abbreviated,
    required this.animate,
    required this.style,
  });

  final String full;
  final String? abbreviated;
  final bool animate;
  final TextStyle style;

  bool _fits(String text, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width <= maxWidth;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (maxWidth.isFinite && _fits(full, maxWidth)) {
          return Text(full, style: style, maxLines: 1, softWrap: false);
        }
        final abbr = abbreviated;
        if (abbr != null && maxWidth.isFinite && _fits(abbr, maxWidth)) {
          return Text(abbr, style: style, maxLines: 1, softWrap: false);
        }
        if (animate && marqueeAnimationsEnabled()) {
          return _MarqueeText(text: full, style: style);
        }
        // Static fallback: prefer the abbreviated form so the most meaningful
        // tail still shows before the ellipsis.
        return Text(
          abbr ?? full,
          style: style,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

/// Horizontally scrolls [text] back and forth so an over-long single line stays
/// fully readable. One there-and-back cycle takes [cyclePeriod] with a brief
/// pause at each end. Renders as static text when the content already fits.
class _MarqueeText extends StatefulWidget {
  const _MarqueeText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  /// One full there-and-back scroll cycle takes roughly this long.
  static const Duration cyclePeriod = Duration(seconds: 15);

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  late final AnimationController _controller = AnimationController(
    vsync: this,
    // Half a cycle per direction; repeat(reverse:) gives the full there-and-back.
    duration: _MarqueeText.cyclePeriod ~/ 2,
  );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didUpdateWidget(_MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  void _start() {
    if (!mounted || !_scroll.hasClients) return;
    if (_scroll.position.maxScrollExtent <= 0) {
      _controller
        ..stop()
        ..value = 0;
      return;
    }
    if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  void _onTick() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return;
    _scroll.jumpTo(max * _holdEased(_controller.value));
  }

  /// Eases 0→1 with a hold at each end so the scroll pauses before reversing.
  double _holdEased(double v) {
    const hold = 0.12;
    if (v <= hold) return 0;
    if (v >= 1 - hold) return 1;
    return Curves.easeInOut.transform((v - hold) / (1 - 2 * hold));
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}

class SessionWorkspace extends StatelessWidget {
  const SessionWorkspace({
    super.key,
    required this.session,
    this.onCloseSession,
    this.onViewFit,
    this.onOpenRail,
    this.onRefit,
  });

  final SessionVm session;
  final VoidCallback? onCloseSession;
  final void Function(int cols, int rows)? onViewFit;
  // Mobile only: opens the session rail overlay from the workspace header.
  final VoidCallback? onOpenRail;
  // Re-asserts this device's terminal size on the shared PTY.
  final VoidCallback? onRefit;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        WorkspaceHeader(
          session: session,
          onClose: onCloseSession,
          onOpenRail: onOpenRail,
          onRefit: onRefit,
        ),
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
            onViewFit: (cols, rows) =>
                (onViewFit ?? session.noteViewFit)(cols, rows),
            focusCursorRevision: session.focusCursorRevision,
            isExited: session.status == 'exited',
          ),
        ),
      ],
    );
  }
}

class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({
    super.key,
    required this.session,
    this.onClose,
    this.onOpenRail,
    this.onRefit,
  });

  final SessionVm session;
  final VoidCallback? onClose;
  // Mobile only: opens the session rail overlay. Null on desktop, where the
  // rail is always visible beside the workspace.
  final VoidCallback? onOpenRail;
  // Re-asserts this device's terminal size on the shared PTY, so switching back
  // to this device reclaims the size from whichever device resized it last.
  final VoidCallback? onRefit;

  @override
  Widget build(BuildContext context) {
    // Header subtitle: the branch when in a repo, else the working directory
    // (home-abbreviated), so a non-repo session still shows where it is.
    final cwd = session.cwd;
    final branch = session.branch;
    // Treat an empty/whitespace branch as absent (the daemon may send "") so the
    // subtitle falls back to the cwd instead of going blank.
    final headerMeta = (branch != null && branch.trim().isNotEmpty)
        ? branch
        : (cwd != null && cwd.isNotEmpty
              ? (_homeAbbreviatedPath(cwd) ?? cwd)
              : '');
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: const BoxDecoration(
        color: Color(0xff151a1d),
        border: Border(bottom: BorderSide(color: Color(0xff263033))),
      ),
      child: Row(
        children: [
          if (onOpenRail != null) ...[
            IconButton(
              icon: const Icon(Icons.menu, color: Color(0xffcdd7d6)),
              tooltip: 'Sessions',
              onPressed: onOpenRail,
            ),
            const SizedBox(width: 4),
          ],
          Icon(session.icon, color: const Color(0xff7fd1c7)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  headerMeta,
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
          const SizedBox(width: 8),
          if (onRefit != null)
            IconButton(
              icon: const Icon(Icons.fit_screen, color: Color(0xffcdd7d6)),
              tooltip: 'Refit terminal to this device',
              onPressed: onRefit,
            ),
          const SizedBox(width: 8),
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
