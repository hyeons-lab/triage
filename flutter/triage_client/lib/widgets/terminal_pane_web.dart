// ignore_for_file: avoid_web_libraries_in_flutter, uri_does_not_exist, deprecated_member_use

import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'terminal_pane.dart';

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.terminalId,
    required this.controller,
    required this.fallbackRows,
  });

  final String terminalId;
  final TerminalController controller;
  final List<StyledRow> fallbackRows;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  static final Map<String, html.Element> _sessionContainers = {};
  static final Set<String> _registeredViewTypes = {};

  late final String _viewType;
  late final html.DivElement _container;
  late final dynamic _term;
  late final dynamic _fitAddon;
  late final dynamic _onDataSubscription;
  late final dynamic _onResizeSubscription;
  bool _initialized = false;

  double? _lastWidth;
  double? _lastHeight;

  @override
  void initState() {
    super.initState();
    final sanitizedId = widget.terminalId.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '_');
    _viewType = 'xterm-view-$sanitizedId';

    // 1. Create native container div
    _container = html.DivElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = '#0d1113'
      ..style.overflow = 'hidden';

    // Store/update the container for this session
    _sessionContainers[sanitizedId] = _container;

    _container.onClick.listen((event) {
      if (_initialized) {
        try {
          js_util.callMethod(_term, 'focus', []);
        } catch (_) {}
      }
    });

    // 2. Register the platform view factory only if not already registered
    if (!_registeredViewTypes.contains(_viewType)) {
      ui_web.platformViewRegistry.registerViewFactory(
        _viewType,
        (int viewId) => _sessionContainers[sanitizedId] ?? html.DivElement(),
      );
      _registeredViewTypes.add(_viewType);
    }

    _initTerminal();
  }

  void _initTerminal() {
    try {
      // 3. Create Terminal Options JSObject
      final options = js_util.newObject();
      final theme = js_util.newObject();
      js_util.setProperty(theme, 'background', '#0d1113');
      js_util.setProperty(theme, 'foreground', '#d9e5e3');
      js_util.setProperty(theme, 'cursor', '#7fd1c7');
      js_util.setProperty(options, 'theme', theme);
      js_util.setProperty(
        options,
        'fontFamily',
        'Consolas, Courier New, monospace',
      );
      js_util.setProperty(options, 'fontSize', 15);
      js_util.setProperty(options, 'cursorBlink', true);
      js_util.setProperty(
        options,
        'convertEol',
        true,
      ); // Normalizes \n to \r\n automatically!

      // 4. Instantiate Terminal
      final terminalConstructor = js_util.getProperty(html.window, 'Terminal');
      _term = js_util.callConstructor(terminalConstructor, [options]);

      // 5. Open Terminal in Container
      js_util.callMethod(_term, 'open', [_container]);

      // 6. Instantiate and Load FitAddon
      final fitAddonModule = js_util.getProperty(html.window, 'FitAddon');
      final fitAddonConstructor = js_util.getProperty(
        fitAddonModule,
        'FitAddon',
      );
      _fitAddon = js_util.callConstructor(fitAddonConstructor, []);
      js_util.callMethod(_term, 'loadAddon', [_fitAddon]);

      // Prevent Tab key from escaping focus in xterm.js (allowing shell autocomplete)
      try {
        js_util.callMethod(_term, 'attachCustomKeyEventHandler', [
          js_util.allowInterop((html.KeyboardEvent event) {
            if (event.key == 'Tab') {
              event.preventDefault();
            }
            return true;
          })
        ]);
      } catch (_) {}

      // 6b. Bind JS term.onData to controller
      final onDataCallback = js_util.allowInterop((String data, [dynamic _]) {
        widget.controller.sendInput(data);
      });
      _onDataSubscription = js_util.callMethod(_term, 'onData', [
        onDataCallback,
      ]);

      // 6c. Bind JS term.onResize to controller
      final onResizeCallback = js_util.allowInterop((
        dynamic size, [
        dynamic _,
      ]) {
        final cols = js_util.getProperty(size, 'cols') as int;
        final rows = js_util.getProperty(size, 'rows') as int;
        widget.controller.sendResizeOut(cols, rows);
      });
      _onResizeSubscription = js_util.callMethod(_term, 'onResize', [
        onResizeCallback,
      ]);

      // 7. Write fallback initial content
      _writeInitialContent();

      // 8. Bind listeners to the controller
      _initialized = true;
      _bindController();

      try {
        js_util.callMethod(_term, 'focus', []);
      } catch (_) {}

      // 9. Delayed fits to handle timing/sizing latency
      Future.delayed(const Duration(milliseconds: 50), _onFit);
      Future.delayed(const Duration(milliseconds: 200), _onFit);
      Future.delayed(const Duration(milliseconds: 600), _onFit);
    } catch (e) {
      debugPrint('Failed to initialize xterm.js: $e');
    }
  }

  void _writeInitialContent() {
    final sb = StringBuffer();
    for (var i = 0; i < widget.fallbackRows.length; i++) {
      sb.write(_styledRowToAnsi(widget.fallbackRows[i]));
      if (i < widget.fallbackRows.length - 1) {
        sb.write('\r\n');
      }
    }
    js_util.callMethod(_term, 'write', [sb.toString()]);
  }

  String _styledSpanToAnsi(StyledSpan span) {
    final sb = StringBuffer();
    final style = span.style;
    if (style.bold) sb.write('\x1B[1m');
    if (style.dim) sb.write('\x1B[2m');
    if (style.italic) sb.write('\x1B[3m');
    if (style.underline) sb.write('\x1B[4m');
    if (style.reverse) sb.write('\x1B[7m');
    final fg = style.foreground;
    if (fg != null) {
      sb.write('\x1B[38;2;${fg.red};${fg.green};${fg.blue}m');
    }
    final bg = style.background;
    if (bg != null) {
      sb.write('\x1B[48;2;${bg.red};${bg.green};${bg.blue}m');
    }
    sb.write(span.text);
    sb.write('\x1B[0m');
    return sb.toString();
  }

  String _styledRowToAnsi(StyledRow row) {
    final sb = StringBuffer();
    for (final span in row.spans) {
      sb.write(_styledSpanToAnsi(span));
    }
    return sb.toString();
  }

  void _bindController() {
    widget.controller.addWriteListener(_onWrite);
    widget.controller.addClearListener(_onClear);
    widget.controller.addResizeListener(_onResize);
    widget.controller.addFitListener(_onFit);
  }

  void _unbindController() {
    widget.controller.removeWriteListener(_onWrite);
    widget.controller.removeClearListener(_onClear);
    widget.controller.removeResizeListener(_onResize);
    widget.controller.removeFitListener(_onFit);
  }

  void _onWrite(String data) {
    if (!_initialized) return;
    js_util.callMethod(_term, 'write', [data]);
  }

  void _onClear() {
    if (!_initialized) return;
    js_util.callMethod(_term, 'clear', []);
  }

  void _onResize(int cols, int rows) {
    if (!_initialized) return;
    js_util.callMethod(_term, 'resize', [cols, rows]);
  }

  void _onFit() {
    if (!_initialized) return;
    try {
      js_util.callMethod(_fitAddon, 'fit', []);
    } catch (_) {}
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeWriteListener(_onWrite);
      oldWidget.controller.removeClearListener(_onClear);
      oldWidget.controller.removeResizeListener(_onResize);
      oldWidget.controller.removeFitListener(_onFit);
      _bindController();
      if (_initialized) {
        try {
          js_util.callMethod(_term, 'reset', []);
          _writeInitialContent();
          _onFit();
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    _unbindController();
    if (_initialized) {
      try {
        js_util.callMethod(_onDataSubscription, 'dispose', []);
        js_util.callMethod(_onResizeSubscription, 'dispose', []);
        js_util.callMethod(_term, 'dispose', []);
      } catch (_) {}
    }
    final sanitizedId = widget.terminalId.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '_');
    _sessionContainers.remove(sanitizedId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth != _lastWidth || constraints.maxHeight != _lastHeight) {
          _lastWidth = constraints.maxWidth;
          _lastHeight = constraints.maxHeight;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.controller.fit();
          });
        }
        return HtmlElementView(viewType: _viewType);
      },
    );
  }
}
