// ignore_for_file: avoid_web_libraries_in_flutter, uri_does_not_exist, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'terminal_pane.dart';

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.terminalId,
    required this.controller,
    required this.terminal,
    required this.fallbackRows,
    required this.onTerminalResizeBind,
    required this.focusCursorRevision,
    this.onViewFit,
    this.isExited = false,
  });

  final String terminalId;
  final TerminalController controller;
  final dynamic terminal;

  /// Plain rows; unused by the live web view but kept for parity with native.
  final List<StyledRow> fallbackRows;

  final void Function(void Function(int w, int h, int pw, int ph)? callback)?
  onTerminalResizeBind;

  /// Reports the fitted grid size after layout so the session replays its staged
  /// history (through the store -> controller -> this view's write listener) at
  /// the real terminal size.
  final void Function(int cols, int rows)? onViewFit;

  final int focusCursorRevision;
  final bool isExited;

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
  late final StreamSubscription<html.MouseEvent>
  _containerMouseDownSubscription;
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
  int? _lastFittedRows;
  int? _lastFittedCols;
  bool _focusCursorAfterReplay = false;
  Timer? _resizeDebounceTimer;
  double? _stableWidth;
  double? _stableHeight;
  Timer? _stabilityTimer;
  Timer? _scrollToCursorTimer;

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

    final cachedContainer = _sessionContainers[sanitizedId];
    final cachedTerm = _sessionTerms[sanitizedId];
    final cachedFitAddon = _sessionFitAddons[sanitizedId];
    if (cachedContainer != null &&
        cachedTerm != null &&
        cachedFitAddon != null &&
        cachedContainer.children.isNotEmpty) {
      _container = cachedContainer as html.DivElement;
      _terminalWrapper =
          _container.children.firstWhere((el) => el is html.DivElement)
              as html.DivElement;
      _term = cachedTerm;
      _fitAddon = cachedFitAddon;
      _initialized = true;
      _initialContentWritten = true;
      _styleSheetLoaded = true;
      _bindController();
      _bindTerminalSubscriptions();
      if (widget.focusCursorRevision > 0) {
        _focusCursorNowAndAfterReplay();
      }
    } else {
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
    }

    _windowKeyDownListener = (html.Event event) {
      if (event is html.KeyboardEvent) {
        if (!widget.isExited && _eventTargetsTerminal(event)) {
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
                selection =
                    js_util.callMethod(selectionObj, 'toString', [])
                        as String? ??
                    '';
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
        "'JetBrains Mono', Consolas, 'Courier New', monospace",
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
      if (widget.focusCursorRevision > 0) {
        _focusCursorNowAndAfterReplay();
      }

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

  void _writeInitialContent() {
    // Signal the fitted size; the session replays its staged history through the
    // store -> controller -> this view's write listener at the real size. The
    // single source of truth is the raw byte stream, not styled-row rebuilds.
    final fittedRows = (js_util.getProperty(_term, 'rows') as num).toInt();
    final fittedCols = (js_util.getProperty(_term, 'cols') as num).toInt();
    widget.onViewFit?.call(fittedCols, fittedRows);
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
    _containerMouseDownSubscription = _container.onMouseDown.listen((event) {
      _focusNode.requestFocus();
      if (_initialized) {
        try {
          _activateTerminal();
        } catch (_) {}
      }
    });

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

  bool _eventTargetsTerminal(html.Event event) {
    if (_focusNode.hasFocus) {
      return true;
    }

    try {
      final path = js_util.callMethod(event, 'composedPath', []) as List?;
      if (path != null && path.contains(_container)) {
        return true;
      }
    } catch (_) {}

    final target = event.target;
    if (target is html.Node) {
      try {
        return _container.contains(target);
      } catch (_) {}
    }
    return false;
  }

  void _onWrite(String data) {
    if (!_initialContentWritten) {
      _pendingLiveWriteBuffer.add(data);
    } else {
      if (!_initialized) return;
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

  void _finishInitialContent(int fittedCols, int fittedRows) {
    _initialContentWritten = true;
    _writeInitialContent();
    _flushPendingLiveWrites();
    _afterReplayContentWritten(initialReplay: true);
    _sessionInputRouter.sendResizeOut(_sanitizedId, fittedCols, fittedRows);
  }

  void _flushPendingLiveWrites() {
    if (_pendingLiveWriteBuffer.isEmpty) {
      return;
    }
    final pendingWrites = List<String>.from(_pendingLiveWriteBuffer);
    _pendingLiveWriteBuffer.clear();
    for (final data in pendingWrites) {
      js_util.callMethod(_term, 'write', [data]);
    }
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
            if (!_styleSheetLoaded) {
              return;
            }
            if (fittedCols < 10) {
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
                if (mounted && !_initialContentWritten) {
                  _finishInitialContent(fittedCols, fittedRows);
                }
              });
              return;
            }
            if (_stabilityTimer == null || !_stabilityTimer!.isActive) {
              _finishInitialContent(fittedCols, fittedRows);
            }
          }
          // No clear-and-rewrite on resize: `_writeInitialContent` only signals
          // the fitted size now (it no longer writes content), so clearing here
          // would blank the terminal — for an exited session permanently, since
          // no live repaint follows. xterm.js reflows its own buffer on fit(),
          // and active sessions repaint via the live stream after the resize-out.
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

  void _afterReplayContentWritten({required bool initialReplay}) {
    final shouldFocus = _focusCursorAfterReplay;
    if (initialReplay || shouldFocus) {
      _focusCursorAfterReplay = false;
      _scrollToCursor(requestFocus: true);
    }
  }

  void _focusCursorNowAndAfterReplay() {
    _focusCursorAfterReplay = true;
    _scrollToCursor(requestFocus: true);
  }

  void _scrollToCursor({required bool requestFocus}) {
    void jump() {
      if (!mounted || !_initialized) return;
      try {
        js_util.callMethod(_term, 'scrollToBottom', []);
      } catch (_) {}
      if (requestFocus) {
        _activateTerminal();
      }
    }

    Future.delayed(Duration.zero, jump);
    _scrollToCursorTimer?.cancel();
    _scrollToCursorTimer = Timer(const Duration(milliseconds: 50), jump);
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

  void _triggerFullReplayOrReset() {
    if (!_initialized) return;
    try {
      if (_initialContentWritten) {
        _resetTerminalSafe();
        _writeInitialContent();
        _afterReplayContentWritten(initialReplay: false);
      } else {
        _resetTerminalSafe();
        _pendingLiveWriteBuffer.clear();
        _initialContentWritten = false;
        _stableWidth = null;
        _stableHeight = null;
        _triggerFitWithDelayedRetries();
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isExited != widget.isExited) {
      if (_initialized) {
        try {
          _updateCursorOptions();
        } catch (_) {}
      }
      _triggerFullReplayOrReset();
    }
    if (oldWidget.focusCursorRevision != widget.focusCursorRevision) {
      _focusCursorNowAndAfterReplay();
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
      _triggerFullReplayOrReset();
    }
  }

  @override
  void dispose() {
    _resizeDebounceTimer?.cancel();
    _stabilityTimer?.cancel();
    _scrollToCursorTimer?.cancel();
    html.window.removeEventListener('keydown', _windowKeyDownListener, true);
    _containerMouseDownSubscription.cancel();
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
