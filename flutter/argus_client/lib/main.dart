import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:argus_client/services/argus_websocket_client.dart';
import 'package:argus_client/models/terminal_models.dart';
import 'package:argus_client/widgets/terminal_pane.dart';

void main() {
  runApp(const ArgusClientApp());
}

class ArgusClientApp extends StatelessWidget {
  const ArgusClientApp({super.key, this.client});

  final ArgusWebSocketClient? client;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Argus',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2b6f6f),
          brightness: Brightness.dark,
        ),
        fontFamily: 'Segoe UI',
        scaffoldBackgroundColor: const Color(0xff101416),
      ),
      home: ArgusHome(client: client),
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
  }) : terminalController = TerminalController();

  final String title;
  final String branch;
  String status;
  Color statusColor;
  final IconData icon;
  final List<StyledRow> rows;
  final TerminalController terminalController;
}

class ArgusHome extends StatefulWidget {
  const ArgusHome({super.key, this.client});

  final ArgusWebSocketClient? client;

  @override
  State<ArgusHome> createState() => _ArgusHomeState();
}

class _ArgusHomeState extends State<ArgusHome> {
  final TextEditingController _commandController = TextEditingController();
  final FocusNode _commandFocus = FocusNode();

  late final ArgusWebSocketClient _client;
  String _connectionStatus = 'Offline (Local Mock)';
  Color _connectionStatusColor = const Color(0xff7f8b8d);
  final String _clientId = 'argus-flutter-client';
  final Map<String, String> _subscriptionIds = {};

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
    _sessions = [
      SessionVm(
        title: 'argus / flutter-spike',
        branch: 'experiment/flutter-spike',
        status: 'awaiting input',
        statusColor: const Color(0xffffc857),
        icon: Icons.terminal,
        rows: [
          _promptRow('cargo run -p argus-daemon'),
          _plainRow('daemon listening on local session transport'),
          _plainRow(''),
          _promptRow('flutter run -d web-server --no-web-resources-cdn'),
          _plainRow('lib/main.dart is being served at http://127.0.0.1:8080'),
          _plainRow(''),
          _plainRow('awaiting input: define TerminalPane bridge boundary'),
        ],
      ),
      SessionVm(
        title: 'argus / websocket-session-api',
        branch: 'feat/websocket-session-api',
        status: 'running cargo test',
        statusColor: const Color(0xff7fd1c7),
        icon: Icons.sync,
        rows: [
          _promptRow('cargo test -p argus-transport-ws'),
          _plainRow('test protocol::tests::subscribe_streams_events ... ok'),
          _plainRow('test protocol::tests::invalid_json_returns_error ... ok'),
          _plainRow(''),
          _plainRow('running: websocket integration notes'),
        ],
      ),
      SessionVm(
        title: 'argus / main',
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
    }
    _initWebSocket();
  }

  void _setupSessionInputListener(SessionVm session) {
    session.terminalController.addInputListener((keys) async {
      if (_client.isConnected) {
        final parts = session.title.split(' / ');
        final sessionId = parts.length > 1 ? parts[1] : null;
        if (sessionId != null) {
          try {
            await _client.writeInput(
              sessionId: sessionId,
              clientId: _clientId,
              bytes: utf8.encode(keys),
            );
          } catch (_) {}
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
                session.rows.last.spans.last = StyledSpan(
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
            session.rows.last.spans.add(StyledSpan(text: keys, style: const TerminalStyle()));
            session.terminalController.write(keys);
          }
        });
      }
    });
  }

  void _initWebSocket() async {
    final client =
        widget.client ??
        ArgusWebSocketClient(Uri.parse('ws://127.0.0.1:7777/ws'));
    _client = client;

    setState(() {
      _connectionStatus = 'Connecting...';
      _connectionStatusColor = const Color(0xffffc857);
    });

    try {
      await _client.connect();

      setState(() {
        _connectionStatus = 'Connected to Daemon';
        _connectionStatusColor = const Color(0xff7fd1c7);
      });

      _client.events.listen(
        _onWebSocketEvent,
        onError: _onWebSocketError,
        onDone: _onWebSocketClosed,
      );

      await _client.hello();
      await _loadDaemonSessions();
    } catch (e) {
      setState(() {
        _connectionStatus = 'Offline (Local Mock)';
        _connectionStatusColor = const Color(0xff7f8b8d);
      });
    }
  }

  Future<void> _loadDaemonSessions() async {
    if (!_client.isConnected) return;

    try {
      final sessionIds = await _client.listSessions();
      final List<SessionVm> daemonSessions = [];

      for (final sid in sessionIds) {
        final attachRes = await _client.attachSession(
          sessionId: sid,
          clientId: _clientId,
          mode: 'Observer',
        );
        final snapshot = attachRes['snapshot'] as Map<String, dynamic>?;
        final contextObj = snapshot?['context'] as Map<String, dynamic>?;
        final branch = contextObj?['branch']?.toString() ?? 'main';

        final styledRowsJson = snapshot?['styled_rows'] as List<dynamic>?;
        final rows =
            styledRowsJson
                ?.map((e) => StyledRow.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];

        final session = SessionVm(
          title: 'argus / $sid',
          branch: branch,
          status: 'attached',
          statusColor: const Color(0xff7fd1c7),
          icon: Icons.terminal,
          rows: rows.isEmpty ? [_plainRow('Attached to session $sid')] : rows,
        );
        _setupSessionInputListener(session);
        daemonSessions.add(session);

        final subId = await _client.subscribeSessionEvents(sessionId: sid);
        if (subId.isNotEmpty) {
          _subscriptionIds[subId] = sid;
        }
      }

      if (daemonSessions.isNotEmpty) {
        setState(() {
          for (final s in _sessions) {
            s.terminalController.dispose();
          }
          _sessions.clear();
          _sessions.addAll(daemonSessions);
          _selectedIndex = 0;
        });
      }
    } catch (_) {
      // Fallback
    }
  }

  void _onWebSocketEvent(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type == 'event') {
      final subId = message['subscription_id']?.toString();
      final sessionId = _subscriptionIds[subId];
      if (sessionId == null) return;

      final envelope = message['envelope'] as Map<String, dynamic>?;
      final event = envelope?['event'] as Map<String, dynamic>?;
      if (event == null) return;

      if (event.containsKey('Output')) {
        final output = event['Output'] as Map<String, dynamic>;
        final bytes = (output['bytes'] as List<dynamic>).cast<int>();
        final text = utf8.decode(bytes, allowMalformed: true);

        final sessionIndex = _sessions.indexWhere(
          (s) => s.title == 'argus / $sessionId',
        );
        if (sessionIndex != -1) {
          setState(() {
            final rows = _sessions[sessionIndex].rows;
            final newLines = text.split('\n');
            if (rows.isNotEmpty &&
                rows.last.spans.length == 1 &&
                rows.last.spans.first.text.isEmpty) {
              rows.removeLast();
            }
            for (final line in newLines) {
              rows.add(_plainRow(line));
            }
          });
          _sessions[sessionIndex].terminalController.write(text);
        }
      } else if (event.containsKey('Exited')) {
        final sessionIndex = _sessions.indexWhere(
          (s) => s.title == 'argus / $sessionId',
        );
        if (sessionIndex != -1) {
          setState(() {
            _sessions[sessionIndex].status = 'exited';
            _sessions[sessionIndex].statusColor = const Color(0xff7f8b8d);
          });
        }
      }
    }
  }

  void _onWebSocketError(dynamic error) {
    setState(() {
      _connectionStatus = 'Error';
      _connectionStatusColor = const Color(0xffff6b6b);
    });
  }

  void _onWebSocketClosed() {
    setState(() {
      _connectionStatus = 'Connection Closed';
      _connectionStatusColor = const Color(0xff7f8b8d);
    });
  }

  @override
  void dispose() {
    _commandController.dispose();
    _commandFocus.dispose();
    _client.disconnect();
    for (final s in _sessions) {
      s.terminalController.dispose();
    }
    super.dispose();
  }

  void _selectSession(int index) {
    setState(() {
      _selectedIndex = index;
    });
    _commandFocus.requestFocus();
  }

  void _createSession() async {
    if (_client.isConnected) {
      setState(() {
        _connectionStatus = 'Creating session...';
        _connectionStatusColor = const Color(0xffffc857);
      });
      try {
        final sessionId = await _client.startSession(command: 'bash');
        if (sessionId.isNotEmpty) {
          final attachRes = await _client.attachSession(
            sessionId: sessionId,
            clientId: _clientId,
            mode: 'Observer',
          );
          final snapshot = attachRes['snapshot'] as Map<String, dynamic>?;
          final contextObj = snapshot?['context'] as Map<String, dynamic>?;
          final branch = contextObj?['branch']?.toString() ?? 'main';

          final styledRowsJson = snapshot?['styled_rows'] as List<dynamic>?;
          final rows =
              styledRowsJson
                  ?.map((e) => StyledRow.fromJson(e as Map<String, dynamic>))
                  .toList() ??
              [];

          final session = SessionVm(
            title: 'argus / $sessionId',
            branch: branch,
            status: 'attached',
            statusColor: const Color(0xff7fd1c7),
            icon: Icons.terminal,
            rows: rows.isEmpty
                ? [_plainRow('Attached to session $sessionId')]
                : rows,
          );
          _setupSessionInputListener(session);

          final subId = await _client.subscribeSessionEvents(
            sessionId: sessionId,
          );
          if (subId.isNotEmpty) {
            _subscriptionIds[subId] = sessionId;
          }

          setState(() {
            _sessions.insert(0, session);
            _selectedIndex = 0;
            _connectionStatus = 'Connected to Daemon';
            _connectionStatusColor = const Color(0xff7fd1c7);
          });
        }
      } catch (e) {
        setState(() {
          _connectionStatus = 'Error creating session';
          _connectionStatusColor = const Color(0xffff6b6b);
        });
      }
      _commandFocus.requestFocus();
      return;
    }

    final scratchId = _createdSessionCount + 1;
    final session = SessionVm(
      title: 'argus / scratch-$scratchId',
      branch: 'experiment/flutter-spike',
      status: 'idle',
      statusColor: const Color(0xff7f8b8d),
      icon: Icons.add_circle_outline,
      rows: [
        _promptRow('argus session new'),
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
    _commandFocus.requestFocus();
  }

  void _sendCommand() async {
    final command = _commandController.text.trim();
    if (command.isEmpty) {
      return;
    }

    if (_client.isConnected) {
      final parts = _selectedSession.title.split(' / ');
      final sessionId = parts.length > 1 ? parts[1] : null;

      if (sessionId != null) {
        setState(() {
          _selectedSession.rows
            ..add(_plainRow(''))
            ..add(_promptRow(command));
          _commandController.clear();
        });

        try {
          final bytes = utf8.encode('$command\n');
          await _client.writeInput(
            sessionId: sessionId,
            clientId: _clientId,
            bytes: bytes,
          );
        } catch (e) {
          setState(() {
            _selectedSession.rows.add(_plainRow('Failed to send: $e'));
          });
          _selectedSession.terminalController.write('\r\nFailed to send: $e\r\n');
        }
        _commandFocus.requestFocus();
        return;
      }
    }

    setState(() {
      _selectedSession.rows
        ..add(_plainRow(''))
        ..add(_promptRow(command))
        ..add(_plainRow('queued for daemon transport (local fallback)'));
      _selectedSession.status = 'running';
      _selectedSession.statusColor = const Color(0xff7fd1c7);
      _commandController.clear();
    });
    _selectedSession.terminalController.write(
      '\r\n\x1B[1;38;2;127;209;199m\$ \x1B[0m\x1B[1m$command\x1B[0m\r\nqueued for daemon transport (local fallback)\r\n',
    );
    _commandFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
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
            ),
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: Color(0xff263033),
            ),
            Expanded(
              child: SessionWorkspace(
                session: _selectedSession,
                commandController: _commandController,
                commandFocus: _commandFocus,
                onSubmitCommand: _sendCommand,
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
  });

  final List<SessionVm> sessions;
  final int selectedIndex;
  final ValueChanged<int> onSelectSession;
  final VoidCallback onCreateSession;
  final String connectionStatus;
  final Color connectionStatusColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      color: const Color(0xff151a1d),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Row(
              children: [
                const Icon(Icons.route, size: 24, color: Color(0xff7fd1c7)),
                const SizedBox(width: 10),
                const Text(
                  'Argus',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
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
    required this.commandController,
    required this.commandFocus,
    required this.onSubmitCommand,
  });

  final SessionVm session;
  final TextEditingController commandController;
  final FocusNode commandFocus;
  final VoidCallback onSubmitCommand;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        WorkspaceHeader(session: session),
        Expanded(
          child: TerminalPane(
            controller: session.terminalController,
            fallbackRows: session.rows,
          ),
        ),
        CommandBar(
          controller: commandController,
          focusNode: commandFocus,
          onSubmit: onSubmitCommand,
        ),
      ],
    );
  }
}

class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({super.key, required this.session});

  final SessionVm session;

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
          const Icon(Icons.more_horiz, color: Color(0xffcdd7d6)),
        ],
      ),
    );
  }
}

class CommandBar extends StatelessWidget {
  const CommandBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
      decoration: const BoxDecoration(
        color: Color(0xff151a1d),
        border: Border(top: BorderSide(color: Color(0xff263033))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onSubmitted: (_) => onSubmit(),
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: 'Send input to selected session...',
                hintStyle: const TextStyle(color: Color(0xff7f8b8d)),
                filled: true,
                fillColor: const Color(0xff0f1416),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xff2f3b3f)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xff7fd1c7)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton.filled(
            onPressed: onSubmit,
            tooltip: 'Send',
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}
