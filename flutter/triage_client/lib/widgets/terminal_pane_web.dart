// ignore_for_file: avoid_web_libraries_in_flutter, uri_does_not_exist, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'terminal_pane.dart';
import 'terminal_replay.dart';

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.terminalId,
    required this.controller,
    required this.fallbackRows,
    this.initialCursorRow,
    this.initialCursorCol,
    this.isExited = false,
    this.replayRevision = 0,
    this.replayPending = false,
  });

  final String terminalId;
  final TerminalController controller;
  final List<StyledRow> fallbackRows;
  final int? initialCursorRow;
  final int? initialCursorCol;
  final bool isExited;
  final int replayRevision;
  final bool replayPending;

  static void destroySession(String terminalId) {
    final sanitizedId = terminalId.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '_');
    _TerminalPaneState._discardCachedSession(sanitizedId);
  }

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  static final Map<String, html.Element> _sessionContainers = {};
  static final Map<String, dynamic> _sessionTerms = {};
  static final Map<String, dynamic> _sessionFitAddons = {};
  static final Map<String, dynamic> _sessionOnDataSubscriptions = {};
  static final Map<String, dynamic> _sessionOnResizeSubscriptions = {};
  static final TerminalSessionInputRouter _sessionInputRouter =
      TerminalSessionInputRouter();
  static final Set<String> _registeredViewTypes = {};

  static void _discardCachedSession(String sanitizedId) {
    _TerminalPaneState._sessionContainers.remove(sanitizedId);
    final term = _TerminalPaneState._sessionTerms.remove(sanitizedId);
    if (term != null) {
      try {
        js_util.callMethod(term, 'dispose', []);
      } catch (_) {}
    }
    _TerminalPaneState._sessionFitAddons.remove(sanitizedId);
    _TerminalPaneState._sessionInputRouter.remove(sanitizedId);
    final onData = _TerminalPaneState._sessionOnDataSubscriptions.remove(
      sanitizedId,
    );
    if (onData != null) {
      try {
        js_util.callMethod(onData, 'dispose', []);
      } catch (_) {}
    }
    final onResize = _TerminalPaneState._sessionOnResizeSubscriptions.remove(
      sanitizedId,
    );
    if (onResize != null) {
      try {
        js_util.callMethod(onResize, 'dispose', []);
      } catch (_) {}
    }
  }

  late final String _viewType;
  late final String _sanitizedId;
  late final html.DivElement _container;
  late final html.DivElement _terminalWrapper;
  late final dynamic _term;
  late final dynamic _fitAddon;
  dynamic _onDataSubscription;
  dynamic _onResizeSubscription;
  dynamic _resizeObserver;
  late Object _inputRouteToken;
  late final FocusNode _focusNode;
  late final void Function(html.Event) _windowKeyDownListener;
  late final StreamSubscription<html.MouseEvent> _containerClickSubscription;
  late final StreamSubscription<html.KeyboardEvent>
  _containerKeyDownSubscription;
  late final void Function(html.Event) _containerPasteListener;
  bool _initialized = false;
  bool _initialContentWritten = false;
  bool _styleSheetLoaded = false;
  final List<String> _pendingLiveWriteBuffer = [];

  double? _lastWidth;
  double? _lastHeight;
  bool _liveOutputReceived = false;
  int? _lastFittedRows;
  int? _lastFittedCols;
  int _replaySuppressGeneration = 0;
  bool _suppressInput = false;
  Timer? _resizeDebounceTimer;
  double? _stableWidth;
  double? _stableHeight;
  Timer? _stabilityTimer;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    final sanitizedId = widget.terminalId.replaceAll(
      RegExp(r'[^a-zA-Z0-9-]'),
      '_',
    );
    _sanitizedId = sanitizedId;
    _viewType = 'xterm-view-$sanitizedId';

    _discardCachedSession(sanitizedId);
    _container = html.DivElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = '#0d1113'
      ..style.overflow = 'hidden';

    // Inject xterm.css directly inside the container so it penetrates the Flutter Web platform view Shadow DOM
    final link = html.LinkElement()
      ..rel = 'stylesheet'
      ..href = 'xterm.css';
    link.onLoad.listen((_) {
      if (mounted) {
        // Wait for the browser to parse CSS and apply font styles to the Shadow DOM
        Timer(const Duration(milliseconds: 150), () {
          if (mounted) {
            _styleSheetLoaded = true;
            try {
              _resetTerminalSafe();
              _initialContentWritten = false;
              _stableWidth = null;
              _stableHeight = null;
              _liveOutputReceived = false;
              _triggerFitWithDelayedRetries();
            } catch (_) {}
          }
        });
      }
    });
    _container.append(link);

    // Safety fallback in case stylesheet onLoad fails or is slow
    Timer(const Duration(milliseconds: 600), () {
      if (mounted && !_styleSheetLoaded) {
        _styleSheetLoaded = true;
        if (_initialized) {
          try {
            _resetTerminalSafe();
            _initialContentWritten = false;
            _stableWidth = null;
            _stableHeight = null;
            _liveOutputReceived = false;
            _triggerFitWithDelayedRetries();
          } catch (_) {}
        }
      }
    });

    _terminalWrapper = html.DivElement()
      ..style.width = 'calc(100% - 32px)'
      ..style.height = '100%'
      ..style.marginLeft = '16px'
      ..style.marginRight = '16px'
      ..style.overflow = 'hidden';

    _container.append(_terminalWrapper);
    _sessionContainers[sanitizedId] = _container;

    _initTerminal(sanitizedId);
    _bindContainerEvents();

    _windowKeyDownListener = (html.Event event) {
      if (event is html.KeyboardEvent) {
        if (!widget.isExited) {
          if (event.key == 'Tab' || event.keyCode == 9 || event.code == 'Tab') {
            event.preventDefault();
            event.stopPropagation();
            if (event.shiftKey) {
              _sendInput('\x1B[Z');
            } else {
              _sendInput('\t');
            }
          } else if ((event.ctrlKey || event.metaKey) && event.key == 'c') {
            var selection = '';
            final selectionObj = html.window.getSelection();
            if (selectionObj != null) {
              try {
                selection = js_util.callMethod(selectionObj, 'toString', []) as String? ?? '';
              } catch (_) {}
            }
            if (selection == 'Instance of \'Selection\'') {
              selection = '';
            }
            if (selection.isEmpty) {
              try {
                selection =
                    js_util.callMethod(_term, 'getSelection', []) as String? ??
                    '';
              } catch (_) {}
            }
            if (selection.isNotEmpty) {
              event.preventDefault();
              event.stopPropagation();
              html.window.navigator.clipboard
                  ?.writeText(selection)
                  .catchError((_) {});
            }
          } else if ((event.ctrlKey || event.metaKey) && event.key == 'v') {
            event.preventDefault();
            event.stopPropagation();
            html.window.navigator.clipboard
                ?.readText()
                .then((text) {
                  if (text.isNotEmpty) {
                    _sendInput(text);
                  }
                })
                .catchError((_) {});
          } else {
            final input = _keyboardEventToInput(event);
            if (input != null) {
              event.preventDefault();
              event.stopPropagation();
              _sendInput(input);
            }
          }
        }
      }
    };
    html.window.addEventListener('keydown', _windowKeyDownListener, true);

    if (!_registeredViewTypes.contains(_viewType)) {
      ui_web.platformViewRegistry.registerViewFactory(
        _viewType,
        (int viewId) => _sessionContainers[sanitizedId] ?? html.DivElement(),
      );
      _registeredViewTypes.add(_viewType);
    }
  }

  void _sendInput(String data) {
    _sessionInputRouter.sendInput(_sanitizedId, data);
    if (_initialized && !widget.isExited) {
      try {
        _focusNode.requestFocus();
        js_util.callMethod(_term, 'focus', []);
      } catch (_) {}
    }
  }

  void _activateTerminal() {
    if (!_initialized) return;
    _focusNode.requestFocus();
    try {
      js_util.callMethod(_term, 'focus', []);
    } catch (_) {}
    Future.delayed(const Duration(milliseconds: 0), () {
      if (!mounted) return;
      _focusNode.requestFocus();
      try {
        js_util.callMethod(_term, 'focus', []);
      } catch (_) {}
    });
    Future.delayed(const Duration(milliseconds: 75), () {
      if (!mounted) return;
      _focusNode.requestFocus();
      try {
        js_util.callMethod(_term, 'focus', []);
      } catch (_) {}
    });
  }

  void _initTerminal(String sanitizedId) {
    try {
      final options = js_util.newObject();
      final theme = js_util.newObject();
      js_util.setProperty(theme, 'background', '#0d1113');
      js_util.setProperty(theme, 'foreground', '#d9e5e3');
      if (widget.isExited) {
        js_util.setProperty(theme, 'cursor', 'transparent');
      } else {
        js_util.setProperty(theme, 'cursor', '#7fd1c7');
      }

      js_util.setProperty(theme, 'black', '#1f2b30');
      js_util.setProperty(theme, 'red', '#f2777a');
      js_util.setProperty(theme, 'green', '#99cc99');
      js_util.setProperty(theme, 'yellow', '#ffcc66');
      js_util.setProperty(theme, 'blue', '#6699cc');
      js_util.setProperty(theme, 'magenta', '#cc99cc');
      js_util.setProperty(theme, 'cyan', '#66cccc');
      js_util.setProperty(theme, 'white', '#d9e5e3');
      js_util.setProperty(theme, 'brightBlack', '#74838a');
      js_util.setProperty(theme, 'brightRed', '#f2777a');
      js_util.setProperty(theme, 'brightGreen', '#99cc99');
      js_util.setProperty(theme, 'brightYellow', '#ffcc66');
      js_util.setProperty(theme, 'brightBlue', '#6699cc');
      js_util.setProperty(theme, 'brightMagenta', '#cc99cc');
      js_util.setProperty(theme, 'brightCyan', '#66cccc');
      js_util.setProperty(theme, 'brightWhite', '#ffffff');

      js_util.setProperty(options, 'theme', theme);
      js_util.setProperty(
        options,
        'fontFamily',
        'Consolas, Courier New, monospace',
      );
      js_util.setProperty(options, 'fontSize', 15);
      js_util.setProperty(options, 'cursorStyle', 'block');
      js_util.setProperty(options, 'cursorInactiveStyle', 'block');
      js_util.setProperty(options, 'cursorBlink', !widget.isExited);
      js_util.setProperty(options, 'convertEol', true);

      final terminalConstructor = js_util.getProperty(html.window, 'Terminal');
      _term = js_util.callConstructor(terminalConstructor, [options]);
      _sessionTerms[sanitizedId] = _term;
      js_util.setProperty(html.window, 'activeTerm', _term);

      js_util.callMethod(_term, 'open', [_terminalWrapper]);

      final fitAddonModule = js_util.getProperty(html.window, 'FitAddon');
      final fitAddonConstructor = js_util.getProperty(
        fitAddonModule,
        'FitAddon',
      );
      _fitAddon = js_util.callConstructor(fitAddonConstructor, []);
      _sessionFitAddons[sanitizedId] = _fitAddon;
      js_util.callMethod(_term, 'loadAddon', [_fitAddon]);

      _bindTerminalSubscriptions();

      _initialized = true;
      _bindController();

      try {
        _activateTerminal();
      } catch (_) {}

      _triggerFitWithDelayedRetries();

      try {
        final fonts = js_util.getProperty(html.document, 'fonts');
        if (fonts != null) {
          final readyPromise = js_util.getProperty(fonts, 'ready');
          if (readyPromise != null) {
            js_util.promiseToFuture(readyPromise).then((_) {
              _onFit();
            });
          }
        }
      } catch (_) {}
    } catch (e) {
      debugPrint('Failed to initialize xterm.js: $e');
    }
  }

  StyledRow _clipRowToCols(StyledRow row, int cols) {
    if (cols <= 0 || row.spans.isEmpty) return row;
    final clippedSpans = <StyledSpan>[];
    var used = 0;
    for (final span in row.spans) {
      if (used >= cols) break;
      final remaining = cols - used;
      if (span.text.length <= remaining) {
        clippedSpans.add(span);
        used += span.text.length;
      } else {
        clippedSpans.add(
          StyledSpan(
            text: span.text.substring(0, remaining),
            style: span.style,
          ),
        );
        break;
      }
    }
    return StyledRow(spans: clippedSpans);
  }

  void _writeInitialContent() {
    if (widget.replayPending) {
      return;
    }
    final fittedRowsNum = js_util.getProperty(_term, 'rows') as num;
    final fittedColsNum = js_util.getProperty(_term, 'cols') as num;
    final fittedRows = fittedRowsNum.toInt();
    final fittedCols = fittedColsNum.toInt();
    final cursor = computeReplayCursorPlacement(
      fallbackRows: widget.fallbackRows,
      fittedRows: fittedRows,
      initialCursorRow: widget.initialCursorRow,
      initialCursorCol: widget.initialCursorCol,
    );

    final sb = StringBuffer();
    if (widget.isExited) {
      sb.write('\x1b[?25l');
    } else {
      sb.write('\x1b[?25h');
    }
    // Write historical rows first to fill the scrollback buffer
    for (var i = 0; i < cursor.startRow; i++) {
      final trimmedRow = _clipRowToCols(
        trimReplayTrailingWhitespace(widget.fallbackRows[i]),
        fittedCols,
      );
      sb.write(_styledRowToAnsi(trimmedRow));
      sb.write('\r\n');
    }
    // Write the active viewport rows
    for (var i = cursor.startRow; i < cursor.endRow; i++) {
      final trimmedRow = _clipRowToCols(
        trimReplayTrailingWhitespace(widget.fallbackRows[i]),
        fittedCols,
      );
      sb.write(_styledRowToAnsi(trimmedRow));
      if (i < cursor.endRow - 1) {
        sb.write('\r\n');
      }
    }

    sb.write('\x1B[${cursor.terminalRow};${cursor.terminalCol}H');
    _writeReplayContent(sb.toString());
  }

  void _writeReplayContent(String data) {
    final generation = ++_replaySuppressGeneration;
    _suppressInput = true;

    // Safety timeout to ensure key input is never permanently blocked
    Timer(const Duration(milliseconds: 150), () {
      if (mounted && _replaySuppressGeneration == generation) {
        _suppressInput = false;
      }
    });

    final complete = js_util.allowInterop(() {
      Timer(const Duration(milliseconds: 50), () {
        if (mounted && _replaySuppressGeneration == generation) {
          _suppressInput = false;
        }
      });
    });
    try {
      js_util.callMethod(_term, 'write', [data, complete]);
    } catch (_) {
      if (_replaySuppressGeneration == generation) {
        _suppressInput = false;
      }
    }
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

  void _resetTerminalSafe() {
    if (!_initialized) return;
    try {
      js_util.callMethod(_term, 'clear', []);
      js_util.callMethod(_term, 'write', ['\x1b[2J\x1b[3J\x1b[H']);
    } catch (_) {}
  }

  void _bindTerminalSubscriptions() {
    _inputRouteToken = _sessionInputRouter.bind(
      _sanitizedId,
      widget.controller,
    );

    _onDataSubscription = _sessionOnDataSubscriptions[_sanitizedId];
    if (_onDataSubscription == null) {
      final sessionId = _sanitizedId;
      final onDataCallback = js_util.allowInterop((String data, [dynamic _]) {
        if (_suppressInput) {
          return;
        }
        _sessionInputRouter.sendInput(sessionId, data);
      });
      _onDataSubscription = js_util.callMethod(_term, 'onData', [
        onDataCallback,
      ]);
      _sessionOnDataSubscriptions[_sanitizedId] = _onDataSubscription;
    }

    _onResizeSubscription = _sessionOnResizeSubscriptions[_sanitizedId];
    if (_onResizeSubscription == null) {
      final onResizeCallback = js_util.allowInterop((
        dynamic size, [
        dynamic _,
      ]) {
        if (!_initialContentWritten) {
          return;
        }
        final colsNum = js_util.getProperty(size, 'cols') as num;
        final rowsNum = js_util.getProperty(size, 'rows') as num;
        final cols = colsNum.toInt();
        final rows = rowsNum.toInt();
        _sessionInputRouter.sendResizeOut(_sanitizedId, cols, rows);
      });
      _onResizeSubscription = js_util.callMethod(_term, 'onResize', [
        onResizeCallback,
      ]);
      _sessionOnResizeSubscriptions[_sanitizedId] = _onResizeSubscription;
    }

    try {
      js_util.callMethod(_term, 'attachCustomKeyEventHandler', [
        js_util.allowInterop((dynamic event) {
          final key = js_util.getProperty(event, 'key') as String?;
          if (key == 'Tab') {
            js_util.callMethod(event, 'preventDefault', []);
            js_util.callMethod(event, 'stopPropagation', []);
            final shiftKey =
                js_util.getProperty(event, 'shiftKey') as bool? ?? false;
            if (shiftKey) {
              _sessionInputRouter.sendInput(_sanitizedId, '\x1B[Z');
            } else {
              _sessionInputRouter.sendInput(_sanitizedId, '\t');
            }
            return false;
          }
          return true;
        }),
      ]);
    } catch (_) {}

    try {
      final resizeObserverConstructor = js_util.getProperty(
        html.window,
        'ResizeObserver',
      );
      if (resizeObserverConstructor != null) {
        final callback = js_util.allowInterop((
          dynamic entries,
          dynamic observer,
        ) {
          if (mounted) {
            _onFit();
          }
        });
        _resizeObserver = js_util.callConstructor(resizeObserverConstructor, [
          callback,
        ]);
        js_util.callMethod(_resizeObserver, 'observe', [_terminalWrapper]);
      }
    } catch (_) {}
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

  void _bindContainerEvents() {
    _containerClickSubscription = _container.onClick.listen((event) {
      _focusNode.requestFocus();
      if (_initialized) {
        try {
          _activateTerminal();
          _triggerFitWithDelayedRetries();
        } catch (_) {}
      }
    });

    _containerKeyDownSubscription = _container.onKeyDown.listen((event) {
      if (event.key == 'Tab') {
        event.preventDefault();
      }
    });

    _containerPasteListener = (html.Event event) {
      if (event is html.ClipboardEvent) {
        event.preventDefault();
        event.stopPropagation();
        final clipboardData = event.clipboardData;
        final text = clipboardData?.getData('text/plain') ?? '';
        if (text.isNotEmpty) {
          _sendInput(text);
        }
      }
    };
    _container.addEventListener('paste', _containerPasteListener, true);
  }

  void _onWrite(String data) {
    if (!_initialized) return;
    if (!_initialContentWritten) {
      _pendingLiveWriteBuffer.add(data);
    } else {
      _liveOutputReceived = true;
      js_util.callMethod(_term, 'write', [data]);
    }
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
      final width = _terminalWrapper.clientWidth;
      final height = _terminalWrapper.clientHeight;
      if (width > 0 && height > 0) {
        js_util.callMethod(_fitAddon, 'fit', []);
        _activateTerminal();
        final fittedRowsNum = js_util.getProperty(_term, 'rows') as num;
        final fittedColsNum = js_util.getProperty(_term, 'cols') as num;
        final fittedRows = fittedRowsNum.toInt();
        final fittedCols = fittedColsNum.toInt();

        if (fittedRows >= 5 && fittedCols >= 10) {
          final sizeChanged =
              _lastFittedRows != fittedRows || _lastFittedCols != fittedCols;
          _lastFittedRows = fittedRows;
          _lastFittedCols = fittedCols;
          if (sizeChanged && _initialContentWritten) {
            _resizeDebounceTimer?.cancel();
            _resizeDebounceTimer = Timer(const Duration(milliseconds: 100), () {
              if (mounted) {
                _sessionInputRouter.sendResizeOut(
                  _sanitizedId,
                  fittedCols,
                  fittedRows,
                );
              }
            });
          }

          if (!_initialContentWritten) {
            if (widget.replayPending) {
              return;
            }
            if (!_styleSheetLoaded) {
              return;
            }
            if (fittedCols < 35) {
              // Wait until the layout has expanded to a reasonable size to prevent premature narrow wrapping
              return;
            }
            final dWidth = width.toDouble();
            final dHeight = height.toDouble();
            if (_stableWidth != dWidth || _stableHeight != dHeight) {
              _stableWidth = dWidth;
              _stableHeight = dHeight;
              _stabilityTimer?.cancel();
              _stabilityTimer = Timer(const Duration(milliseconds: 250), () {
                if (mounted && !_initialContentWritten && !widget.replayPending) {
                  _initialContentWritten = true;
                  _writeInitialContent();
                  _pendingLiveWriteBuffer.clear();
                  _sessionInputRouter.sendResizeOut(
                    _sanitizedId,
                    fittedCols,
                    fittedRows,
                  );
                }
              });
              return;
            }
            if (_stabilityTimer == null || !_stabilityTimer!.isActive) {
              _initialContentWritten = true;
              _writeInitialContent();
              _pendingLiveWriteBuffer.clear();
              _sessionInputRouter.sendResizeOut(
                _sanitizedId,
                fittedCols,
                fittedRows,
              );
            }
          } else if (widget.isExited) {
            _resetTerminalSafe();
            _writeInitialContent();
          } else if (sizeChanged && !_liveOutputReceived) {
            _resetTerminalSafe();
            _writeInitialContent();
          }
        }
      }
    } catch (_) {}
  }

  void _triggerFitWithDelayedRetries() {
    _onFit();
    Future.delayed(const Duration(milliseconds: 50), _onFit);
    Future.delayed(const Duration(milliseconds: 200), _onFit);
    Future.delayed(const Duration(milliseconds: 600), _onFit);
    Future.delayed(const Duration(milliseconds: 1500), _onFit);
  }

  String? _keyboardEventToInput(html.KeyboardEvent event) {
    final key = event.key;
    if (key == null) return null;

    if (event.ctrlKey || event.metaKey || event.altKey) {
      if (event.ctrlKey && key.toLowerCase() == 'c') {
        return '\x03';
      }
      return null;
    }

    switch (key) {
      case 'Enter':
        return '\r';
      case 'Backspace':
        return '\x7f';
      case 'Escape':
        return '\x1b';
      case 'ArrowUp':
        return '\x1b[A';
      case 'ArrowDown':
        return '\x1b[B';
      case 'ArrowRight':
        return '\x1b[C';
      case 'ArrowLeft':
        return '\x1b[D';
      case 'Home':
        return '\x1b[H';
      case 'End':
        return '\x1b[F';
      case 'PageUp':
        return '\x1b[5~';
      case 'PageDown':
        return '\x1b[6~';
      case 'Delete':
        return '\x1b[3~';
    }

    if (key.length == 1) {
      return key;
    }
    return null;
  }

  void _updateCursorOptions() {
    final options = js_util.getProperty(_term, 'options');
    var theme = js_util.getProperty(options, 'theme');
    theme ??= js_util.newObject();
    js_util.setProperty(
      theme,
      'cursor',
      widget.isExited ? 'transparent' : '#7fd1c7',
    );
    js_util.setProperty(options, 'theme', theme);
    js_util.setProperty(options, 'cursorBlink', !widget.isExited);
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isExited != widget.isExited) {
      if (_initialized) {
        try {
          _updateCursorOptions();
          _resetTerminalSafe();
          _pendingLiveWriteBuffer.clear();
          _initialContentWritten = false;
          _stableWidth = null;
          _stableHeight = null;
          _liveOutputReceived = false;
          _triggerFitWithDelayedRetries();
        } catch (_) {}
      }
    }
    if (oldWidget.replayRevision != widget.replayRevision) {
      if (_initialized) {
        try {
          _resetTerminalSafe();
          _pendingLiveWriteBuffer.clear();
          _initialContentWritten = false;
          _stableWidth = null;
          _stableHeight = null;
          _liveOutputReceived = false;
          _triggerFitWithDelayedRetries();
        } catch (_) {}
      }
    }
    if (oldWidget.replayPending && !widget.replayPending) {
      if (_initialized) {
        try {
          _resetTerminalSafe();
          _pendingLiveWriteBuffer.clear();
          _initialContentWritten = false;
          _stableWidth = null;
          _stableHeight = null;
          _liveOutputReceived = false;
          _triggerFitWithDelayedRetries();
        } catch (_) {}
      }
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeWriteListener(_onWrite);
      oldWidget.controller.removeClearListener(_onClear);
      oldWidget.controller.removeResizeListener(_onResize);
      oldWidget.controller.removeFitListener(_onFit);
      _sessionInputRouter.unbind(_sanitizedId, _inputRouteToken);
      _inputRouteToken = _sessionInputRouter.bind(
        _sanitizedId,
        widget.controller,
      );
      _bindController();
      if (_initialized) {
        try {
          _resetTerminalSafe();
          _pendingLiveWriteBuffer.clear();
          _initialContentWritten = false;
          _stableWidth = null;
          _stableHeight = null;
          _liveOutputReceived = false;
          _triggerFitWithDelayedRetries();
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    _resizeDebounceTimer?.cancel();
    _stabilityTimer?.cancel();
    html.window.removeEventListener('keydown', _windowKeyDownListener, true);
    _containerClickSubscription.cancel();
    _containerKeyDownSubscription.cancel();
    _container.removeEventListener('paste', _containerPasteListener, true);
    _sessionInputRouter.unbind(_sanitizedId, _inputRouteToken);
    if (_resizeObserver != null) {
      try {
        js_util.callMethod(_resizeObserver, 'disconnect', []);
      } catch (_) {}
    }
    _focusNode.dispose();
    _unbindController();
    _discardCachedSession(_sanitizedId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activateTerminal();
    });
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (node, event) {
        if (event.logicalKey == LogicalKeyboardKey.tab) {
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth != _lastWidth ||
              constraints.maxHeight != _lastHeight) {
            _lastWidth = constraints.maxWidth;
            _lastHeight = constraints.maxHeight;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.controller.fit();
            });
          }
          return Container(
            color: const Color(0xff0d1113),
            child: HtmlElementView(viewType: _viewType),
          );
        },
      ),
    );
  }
}
