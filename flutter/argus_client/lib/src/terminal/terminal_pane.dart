import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

@JS('argusTerminalBridge.create')
external _TerminalHandle _createTerminal(JSString elementId, JSFunction statusCallback);

extension type _TerminalHandle(JSObject _) implements JSObject {
  external void dispose();
  external void fit();
  external void focus();
  external void setInputHandler(JSFunction callback);
  external void write(JSString data);
}

class TerminalPaneController {
  _TerminalPaneState? _state;
  final List<String> _pendingWrites = <String>[];
  final ValueNotifier<String> bridgeStatus = ValueNotifier<String>('waiting for host');
  final ValueNotifier<String> transcript = ValueNotifier<String>('');

  void write(String data) {
    transcript.value += _plainText(data);
    final _TerminalPaneState? state = _state;
    if (state == null || !state.isTerminalAttached) {
      _pendingWrites.add(data);
      return;
    }
    state._write(data);
  }

  void focus() {
    _state?._focus();
  }

  void fit() {
    _state?._fit();
  }

  void dispose() {
    _state?._disposeTerminal();
    bridgeStatus.dispose();
    transcript.dispose();
  }
}

String _plainText(String data) {
  return data
      .replaceAll(RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]'), '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
}

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    required this.controller,
    this.onInput,
    super.key,
  });

  final TerminalPaneController controller;
  final ValueChanged<String>? onInput;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  late final String _viewType;
  late final String _elementId;
  _TerminalHandle? _terminal;
  bool _bridgeOpened = false;

  bool get isTerminalAttached => _terminal != null;

  @override
  void initState() {
    super.initState();
    _viewType = 'argus-terminal-${identityHashCode(this)}';
    _elementId = '$_viewType-element';
    _registerViewFactory();
    _attachController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _attachTerminalWhenReady());
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._state = null;
      _attachController();
    }
  }

  @override
  void dispose() {
    _disposeTerminal();
    _detachController();
    super.dispose();
  }

  void _registerViewFactory() {
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final web.HTMLDivElement element = web.HTMLDivElement()
        ..id = _elementId
        ..textContent = 'Starting terminal...'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.minHeight = '240px'
        ..style.overflow = 'hidden'
        ..style.backgroundColor = '#0b0f12';
      return element;
    });
  }

  void _attachController() {
    widget.controller._state = this;
  }

  void _detachController() {
    if (widget.controller._state == this) {
      widget.controller._state = null;
    }
  }

  void _attachTerminalWhenReady() {
    if (!mounted || _terminal != null) {
      return;
    }
    if (web.document.getElementById(_elementId) == null) {
      widget.controller.bridgeStatus.value = 'waiting for host';
      Timer(const Duration(milliseconds: 16), _attachTerminalWhenReady);
      return;
    }

    widget.controller.bridgeStatus.value = 'opening xterm';
    final _TerminalHandle terminal = _createTerminal(_elementId.toJS, ((JSString status) {
      _setBridgeStatus(status.toDart);
    }).toJS);
    terminal.setInputHandler(((JSString data) {
      widget.onInput?.call(data.toDart);
    }).toJS);

    _terminal = terminal;
    for (final String data in widget.controller._pendingWrites) {
      _write(data);
    }
    widget.controller._pendingWrites.clear();
    _fit();
    Timer(const Duration(milliseconds: 50), _fit);
    Timer(const Duration(milliseconds: 250), _fit);
  }

  void _setBridgeStatus(String status) {
    if (!mounted) {
      return;
    }
    setState(() {
      _bridgeOpened = status.startsWith('opened');
      widget.controller.bridgeStatus.value = status;
    });
  }

  void _write(String data) {
    _terminal?.write(data.toJS);
  }

  void _focus() {
    _terminal?.focus();
  }

  void _fit() {
    _terminal?.fit();
  }

  void _disposeTerminal() {
    _terminal?.dispose();
    _terminal = null;
    _bridgeOpened = false;
    _detachController();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: ColoredBox(
            color: const Color(0xff0b0f12),
            child: HtmlElementView(viewType: _viewType),
          ),
        ),
        if (!_bridgeOpened)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: const BoxDecoration(color: Color(0xff0b0f12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: ValueListenableBuilder<String>(
                    valueListenable: widget.controller.transcript,
                    builder: (BuildContext context, String transcript, Widget? child) {
                      return Text(
                        transcript.isEmpty ? 'Starting terminal...' : transcript,
                        style: const TextStyle(
                          color: Color(0xffd7dde2),
                          fontFamily: 'monospace',
                          fontSize: 14,
                          height: 1.25,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          right: 8,
          top: 8,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xcc171c20),
                border: Border.all(color: const Color(0xff3c464d)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: ValueListenableBuilder<String>(
                  valueListenable: widget.controller.bridgeStatus,
                  builder: (BuildContext context, String status, Widget? child) {
                    return Text(
                      'bridge: $status',
                      style: const TextStyle(
                        color: Color(0xffd7dde2),
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
