import 'dart:convert';

import 'package:flutter/material.dart';

import 'src/input_display.dart';
import 'src/remote/argus_ws_client.dart';
import 'src/remote/default_ws_url.dart';
import 'src/terminal/terminal_pane.dart';

void main() {
  runApp(const ArgusClientApp());
}

class ArgusClientApp extends StatelessWidget {
  const ArgusClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Argus',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2f6f73),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xff101316),
        useMaterial3: true,
      ),
      home: const TerminalSpikePage(),
    );
  }
}

class TerminalSpikePage extends StatefulWidget {
  const TerminalSpikePage({super.key});

  @override
  State<TerminalSpikePage> createState() => _TerminalSpikePageState();
}

class _TerminalSpikePageState extends State<TerminalSpikePage> {
  final TerminalPaneController _terminal = TerminalPaneController();
  final TextEditingController _wsUrl =
      TextEditingController(text: defaultWebSocketUrl());
  final List<String> _inputs = <String>[];
  final String _clientId =
      'flutter-web-${DateTime.now().microsecondsSinceEpoch}';
  ArgusWsClient? _client;
  String _connectionStatus = 'not connected';
  String? _sessionId;
  String? _subscriptionId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _terminal.write(
        'ARGUS TERMINAL SPIKE\n'
        '--------------------\n'
        'Flutter shell: running\n'
        'xterm.js bridge: mount attempted\n'
        'WebSocket session: not connected\n'
        '\n'
        'ready > ',
      );
      _terminal.focus();
    });
  }

  @override
  void dispose() {
    _client?.dispose();
    _wsUrl.dispose();
    _terminal.dispose();
    super.dispose();
  }

  Future<void> _connectWebSocket() async {
    setState(() {
      _connectionStatus = 'connecting';
    });

    final Uri? uri = Uri.tryParse(_wsUrl.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() {
        _connectionStatus = 'invalid url';
      });
      return;
    }

    await _client?.dispose();
    final ArgusWsClient client = ArgusWsClient(uri);
    _client = client;
    try {
      await client.connect(
        onMessage: (String message) {
          _handleWebSocketMessage(client, message);
        },
        onError: (Object error) {
          setState(() {
            _connectionStatus = 'error: $error';
            _client = null;
            _sessionId = null;
            _subscriptionId = null;
          });
          _terminal.write('\n\n[error] WebSocket error: $error\nready > ');
        },
        onDone: () {
          setState(() {
            _connectionStatus = 'closed';
            _client = null;
            _sessionId = null;
            _subscriptionId = null;
          });
          _terminal.write('\n\n[error] WebSocket connection closed\nready > ');
        },
      );
      setState(() {
        _connectionStatus = 'hello sent';
      });
    } catch (error) {
      setState(() {
        _connectionStatus = 'error: $error';
        _client = null;
        _sessionId = null;
        _subscriptionId = null;
      });
      _terminal.write('\n\n[error] Connection failed: $error\nready > ');
    }
  }

  void _handleWebSocketMessage(ArgusWsClient client, String message) {
    final Object? decoded = jsonDecode(message);
    if (decoded is! Map<String, dynamic>) {
      _terminal.write('\nws < $message\nready > ');
      return;
    }

    switch (decoded['type']) {
      case 'response':
        _handleResponse(client, decoded);
      case 'event':
        _handleEvent(decoded);
      case 'subscription_closed':
        setState(() {
          _connectionStatus = 'subscription closed';
          _client = null;
          _sessionId = null;
          _subscriptionId = null;
        });
        _terminal.write('\n\n[error] Session event stream closed\nready > ');
      case 'error':
        final Object? errObj = decoded['error'];
        String errMsg = errObj.toString();
        if (errObj is Map<String, dynamic>) {
          errMsg = errObj['message']?.toString() ??
              errObj['code']?.toString() ??
              errMsg;
        }
        setState(() {
          _connectionStatus = 'error: $errMsg';
          _client = null;
          _sessionId = null;
          _subscriptionId = null;
        });
        _terminal.write('\n\n[error] Server error: $errMsg\nready > ');
      default:
        _terminal.write('\nws < $message\nready > ');
    }
  }

  void _handleResponse(ArgusWsClient client, Map<String, dynamic> message) {
    final Object? result = message['result'];
    if (result is! Map<String, dynamic>) {
      return;
    }

    switch (result['result']) {
      case 'hello':
        client.startDemoSession();
        setState(() {
          _connectionStatus = 'starting demo session';
        });
      case 'session_id':
        final String sessionId = result['session_id'].toString();
        _sessionId = sessionId;
        client.attachInteractive(sessionId, _clientId);
        setState(() {
          _connectionStatus = 'attaching $sessionId';
        });
      case 'attach_session':
        final String? sessionId = _sessionId;
        if (sessionId != null) {
          client.subscribeSessionEvents(sessionId);
        }
        setState(() {
          _connectionStatus = 'subscribing';
        });
      case 'subscribed':
        _subscriptionId = result['subscription_id'].toString();
        _terminal.write(
          '\nREMOTE DAEMON SESSION READY\n'
          'session: $_sessionId\n'
          'subscription: $_subscriptionId\n'
          'Type here; bytes are sent over WebSocket to the daemon PTY.\n'
          '\nremote > ',
        );
        setState(() {
          _connectionStatus = 'remote session ready';
        });
    }
  }

  void _handleEvent(Map<String, dynamic> message) {
    final Object? envelope = message['envelope'];
    if (envelope is! Map<String, dynamic>) {
      return;
    }
    final Object? event = envelope['event'];
    if (event is! Map<String, dynamic>) {
      return;
    }
    final Object? output = event['Output'];
    if (output is Map<String, dynamic>) {
      final Object? bytes = output['bytes'];
      if (bytes is List<dynamic>) {
        _terminal.write(String.fromCharCodes(bytes.cast<int>()));
      }
    }
  }

  void _handleTerminalInput(String data) {
    setState(() {
      _inputs.add(data);
      final int overflow = _inputs.length - 12;
      if (overflow > 0) {
        _inputs.removeRange(0, overflow);
      }
    });

    if (data == '\r') {
      _sendInput(data);
    } else if (data == '\u007f') {
      _sendInput(data);
    } else {
      _sendInput(data);
    }
  }

  void _sendInput(String data) {
    final ArgusWsClient? client = _client;
    final String? sessionId = _sessionId;
    if (client != null && sessionId != null && _subscriptionId != null) {
      client.writeInput(sessionId, _clientId, data == '\r' ? '\n' : data);
    } else if (data == '\r') {
      _terminal.write('\nready > ');
    } else if (data == '\u007f') {
      _terminal.write('\b \b');
    } else {
      _terminal.write(data);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 256,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: Color(0xff171c20),
                  border: Border(
                    right: BorderSide(color: Color(0xff2c3338)),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Argus',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      const Text('Terminal bridge spike'),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _wsUrl,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                          labelText: 'WebSocket',
                        ),
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _connectWebSocket,
                          child: const Text('Connect'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _connectionStatus,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Recent input',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView(
                          children: _inputs
                              .map(
                                (String input) => Text(
                                  displayTerminalInput(input),
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: TerminalPane(
                    controller: _terminal,
                    onInput: _handleTerminalInput,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
