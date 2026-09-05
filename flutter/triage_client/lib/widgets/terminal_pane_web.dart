// ignore_for_file: avoid_web_libraries_in_flutter, uri_does_not_exist, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/terminal/control_bytes.dart';
import 'package:triage_client/terminal/terminal_paste.dart';
import 'package:triage_client/widgets/terminal_accessory_bar.dart';
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

  static void setBracketedPasteMode(String terminalId, bool enabled) {
    final sanitizedId = terminalId.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '_');
    final term = _TerminalPaneState._sessionTerms[sanitizedId];
    if (term != null) {
      try {
        final modes = js_util.getProperty(term, 'modes');
        if (modes != null) {
          js_util.setProperty(modes, 'bracketedPasteMode', enabled);
        }
      } catch (_) {}
    }
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
  static final Map<String, dynamic> _sessionOnScrollSubscriptions = {};
  static final Map<String, int> _sessionSavedViewportY = {};
  static final TerminalSessionInputRouter _sessionInputRouter =
      TerminalSessionInputRouter();
  static final Set<String> _registeredViewTypes = {};
  // The pane a session's container and cached terminal currently belong to.
  //
  // A container outlives the pane that built it, and a rebuild mounts the
  // replacement before disposing the pane it replaces. For that overlap both
  // panes hold the same element, so the incoming one takes the listeners off its
  // predecessor as it binds: a paste landing in the gap is delivered once rather
  // than twice, and the focus work on mousedown and click runs once. It also
  // tells `dispose` whether it is the last pane out, and so whether the cached
  // session is still its to discard.
  //
  // It does not cover `_windowKeyDownListener`, which is per pane, added to the
  // window rather than the container, and guarded by `_eventTargetsTerminal`
  // instead. Overlapping panes both still see keydowns.
  static final Map<String, _TerminalPaneState> _containerEventOwners = {};

  static void _discardCachedSession(String sanitizedId) {
    _TerminalPaneState._sessionCtrlArmed.remove(sanitizedId);
    _TerminalPaneState._sessionCtrlRebuild.remove(sanitizedId);
    _TerminalPaneState._sessionSavedViewportY.remove(sanitizedId);
    // Dropped alongside the container it refers to. A pane still mounted over a
    // destroyed session unbinds itself when it goes, so leaving the entry here
    // would only strand a dead `State` in a static map.
    _TerminalPaneState._containerEventOwners.remove(sanitizedId);
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
    final onScroll = _TerminalPaneState._sessionOnScrollSubscriptions.remove(
      sanitizedId,
    );
    if (onScroll != null) {
      try {
        js_util.callMethod(onScroll, 'dispose', []);
      } catch (_) {}
    }
  }

  late final String _viewType;
  late final String _sanitizedId;
  late final html.DivElement _container;
  late final html.DivElement _terminalWrapper;
  late final dynamic _term;
  late final dynamic _fitAddon;
  dynamic _resizeObserver;
  late Object _inputRouteToken;
  late final FocusNode _focusNode;
  late final void Function(html.Event) _windowKeyDownListener;
  // Bound together by [_bindContainerEvents] and taken off together by
  // [_unbindContainerEvents]. Nullable rather than `late final` because they are
  // not always held: a pane whose container has been taken over by its
  // replacement gives them up while still alive, and `dispose` has to run
  // through either state without throwing partway and abandoning the teardown
  // below it.
  StreamSubscription<html.MouseEvent>? _containerMouseDownSubscription;
  StreamSubscription<html.MouseEvent>? _containerClickSubscription;
  StreamSubscription<html.KeyboardEvent>? _containerKeyDownSubscription;
  StreamSubscription<html.WheelEvent>? _containerWheelSubscription;
  void Function(html.Event)? _containerPasteListener;
  ModalRoute<dynamic>? _currentRoute;
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
  // Backstop for the first-fit handshake: armed once at the first valid sized
  // fit and NOT reset on subsequent size changes, unlike _stabilityTimer. If
  // the size never holds still long enough for the stability debounce to fire,
  // this force-finalizes the initial content (and thus calls onViewFit, which
  // flushes the session's staged history) using the last fitted size.
  Timer? _forceFinalizeTimer;
  Timer? _scrollToCursorTimer;
  // Bumped on every explicit refit so a superseded refit's delayed retries stop
  // firing. `_lastRefit*` dedupes host resize-outs across a single refit's
  // retries so a settled refit jiggles the host once, not once per tick.
  int _refitGeneration = 0;
  int? _lastRefitCols;
  int? _lastRefitRows;
  html.TextAreaElement? _cachedTextarea;

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
    // Point the session's sticky-Ctrl rebuild hook at this (now current-mounted)
    // instance, so the cached onData fold can un-highlight the bar after folding.
    // Overwritten by the next instance for this session; safe when stale (the
    // mounted guard makes it a no-op) and cleared on session destroy.
    _sessionCtrlRebuild[sanitizedId] = () {
      if (mounted) setState(() {});
    };

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
      try {
        final rowsNum = js_util.getProperty(_term, 'rows') as num?;
        final colsNum = js_util.getProperty(_term, 'cols') as num?;
        if (rowsNum != null && colsNum != null) {
          _lastFittedRows = rowsNum.toInt();
          _lastFittedCols = colsNum.toInt();
        }
      } catch (_) {}
      _bindController();
      _bindTerminalSubscriptions();
      _bindContainerEvents();
      _restoreScrollPosition(requestFocus: widget.focusCursorRevision > 0);
      _triggerFitWithDelayedRetries();
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
                _forceFinalizeTimer?.cancel();
                _forceFinalizeTimer = null;
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
              _forceFinalizeTimer?.cancel();
              _forceFinalizeTimer = null;
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _initialized) {
        if (cachedContainer != null) {
          _writeInitialContent();
        }
        _activateTerminal();
      }
    });

    _windowKeyDownListener = (html.Event event) {
      if (event is html.KeyboardEvent) {
        final isCurrent = _currentRoute?.isCurrent ?? true;
        if (!widget.isExited && isCurrent && _eventTargetsTerminal(event)) {
          if (event.key == 'Tab' || event.keyCode == 9 || event.code == 'Tab') {
            event.preventDefault();
            event.stopPropagation();
            if (event.shiftKey) {
              _sendInput('\x1B[Z');
            } else {
              _sendInput('\t');
            }
          } else if ((event.ctrlKey || event.metaKey) && event.key == 'c') {
            // Prefer xterm.js's own selection: it rebuilds the row text from the
            // buffer with the inter-column spaces intact. The browser-native
            // window.getSelection() serializes the DOM-renderer's per-cell spans
            // instead, which concatenates the columns and drops those spaces —
            // so only fall back to it when xterm has no selection of its own.
            var selection = '';
            try {
              selection =
                  js_util.callMethod(_term, 'getSelection', []) as String? ??
                  '';
            } catch (_) {}
            if (selection.isEmpty) {
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
            }
            if (selection.isNotEmpty) {
              event.preventDefault();
              event.stopPropagation();
              // Logged rather than swallowed: a rejected write and an empty
              // selection both present as "the copy did nothing", and with the
              // error dropped there was no way to tell them apart from the
              // console. Failure is still non-fatal, so the terminal keeps its
              // keystroke handling either way.
              html.window.navigator.clipboard?.writeText(selection).catchError((
                Object error,
              ) {
                debugPrint('Terminal copy failed: $error');
              });
            }
          } else if ((event.ctrlKey || event.metaKey) &&
              (event.key == 'v' || event.key == 'V')) {
            // Deliberately not handled here: paste is left to the browser.
            //
            // Calling `preventDefault` on this keydown is what suppresses the
            // native paste action, and with it the `paste` event that
            // `_containerPasteListener` is waiting for. What was left was
            // `navigator.clipboard.readText()`, which needs the `clipboard-read`
            // permission; that sits at `prompt` until the user accepts, and a
            // single dismissal denies it for the origin from then on. The
            // rejection was swallowed, so paste simply stopped working with
            // nothing logged.
            //
            // Letting the event through costs nothing and needs no permission: a
            // user-initiated paste hands the page its own text on the `paste`
            // event. The branch is inert, and deleting it would behave exactly
            // the same, since `_keyboardEventToInput` already returns null for a
            // ctrl/meta-modified "v". It is kept only as the marker saying the
            // interception was removed on purpose, sitting next to the reason.
          } else {
            // When the xterm.js helper textarea is NOT yet the active element in the DOM
            // (e.g. after clicking outside or on initial interaction), the browser fires
            // keydown on body and does NOT deliver text input to a textarea focused in-flight.
            // We immediately forward this first keystroke to the session and focus the textarea
            // with preventDefault so subsequent keystrokes flow natively through xterm.onData.
            if (!_isActiveElementInTerminal()) {
              final input = _keyboardEventToInput(event);
              if (input != null && input.isNotEmpty) {
                event.preventDefault();
                event.stopPropagation();
                _sendInput(input);
              }
              _activateTerminal();
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currentRoute = ModalRoute.of(context);
    _syncPointerEvents();
  }

  void _syncPointerEvents() {
    final isCurrent = _currentRoute?.isCurrent ?? true;
    final target = isCurrent ? 'auto' : 'none';
    if (_initialized || _sessionContainers.containsKey(_sanitizedId)) {
      if (_container.style.pointerEvents != target) {
        _container.style.pointerEvents = target;
      }
    }
  }

  void _sendInput(String data) {
    _sessionSavedViewportY.remove(_sanitizedId);
    try {
      js_util.callMethod(_term, 'scrollToBottom', []);
    } catch (_) {}
    _sessionInputRouter.sendInput(_sanitizedId, data);
    _focusTerminal();
  }

  // Refocus the terminal without sending anything, so a bar tap never steals
  // focus and so never dismisses the soft keyboard.
  void _focusTerminal() {
    if (_initialized && !widget.isExited) {
      try {
        final textarea = _cachedTextarea ??=
            _container.querySelector('textarea') as html.TextAreaElement?;
        if (textarea != null) {
          final opts = js_util.newObject();
          js_util.setProperty(opts, 'preventScroll', true);
          js_util.callMethod(textarea, 'focus', [opts]);
        } else {
          js_util.callMethod(_term, 'focus', []);
        }
      } catch (_) {}
    }
  }

  // Sticky Ctrl for the on-screen accessory bar (mobile web): when armed, the
  // next single character typed on the soft keyboard is folded into its control
  // byte instead of being sent literally. Mirrors the native pane.
  //
  // Keyed by *session*, not held on the State: the pane caches one xterm terminal
  // and its `onData` callback per session id and reuses them across State
  // instances (session switch and return). That cached fold can't close over a
  // field of whichever instance created it — it would go stale — so the arm flag
  // lives here and a rebuild hook lets the fold un-highlight the mounted bar.
  static final Map<String, bool> _sessionCtrlArmed = {};
  static final Map<String, VoidCallback> _sessionCtrlRebuild = {};

  bool get _ctrlArmed => _sessionCtrlArmed[_sanitizedId] ?? false;

  void _setCtrlArmed(bool value) {
    if (_ctrlArmed == value) return;
    _sessionCtrlArmed[_sanitizedId] = value;
    if (mounted) setState(() {});
  }

  void _toggleCtrl() {
    _setCtrlArmed(!_ctrlArmed);
  }

  // Send a raw byte sequence from an accessory-bar key, then disarm sticky Ctrl
  // (a bare Ctrl toggle arms it via _toggleCtrl instead of coming through here).
  // Does not request focus so tapping shortcuts does not pop open the soft keyboard.
  void _sendAccessory(String bytes) {
    _sessionInputRouter.sendInput(_sanitizedId, bytes);
    _setCtrlArmed(false);
  }

  // Touch clients (mobile-OS browser) get the on-screen accessory bar; desktop
  // browsers keep the full-height terminal and their hardware keyboard.
  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  void _activateTerminal() {
    if (!_initialized || widget.isExited) return;
    final active = html.document.activeElement;
    if (active is html.InputElement ||
        (active is html.TextAreaElement && !_container.contains(active)) ||
        (active != null && active.isContentEditable == true)) {
      return;
    }
    try {
      final textarea = _cachedTextarea ??=
          _container.querySelector('textarea') as html.TextAreaElement?;
      if (textarea != null) {
        final opts = js_util.newObject();
        js_util.setProperty(opts, 'preventScroll', true);
        js_util.callMethod(textarea, 'focus', [opts]);
      } else {
        js_util.callMethod(_term, 'focus', []);
      }
    } catch (_) {}
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
      js_util.setProperty(options, 'scrollback', 50000);
      js_util.setProperty(options, 'cursorStyle', 'block');
      js_util.setProperty(options, 'cursorInactiveStyle', 'block');
      js_util.setProperty(options, 'cursorBlink', !widget.isExited);
      js_util.setProperty(options, 'allowProposedApi', true);

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

      try {
        final unicode11Module = js_util.getProperty(
          html.window,
          'Unicode11Addon',
        );
        if (unicode11Module != null) {
          final unicode11Constructor = js_util.getProperty(
            unicode11Module,
            'Unicode11Addon',
          );
          if (unicode11Constructor != null) {
            final unicode11Addon = js_util.callConstructor(
              unicode11Constructor,
              [],
            );
            js_util.callMethod(_term, 'loadAddon', [unicode11Addon]);
            final unicode = js_util.getProperty(_term, 'unicode');
            if (unicode != null) {
              js_util.setProperty(unicode, 'activeVersion', '11');
            }
          }
        }
      } catch (e, stackTrace) {
        debugPrint('Failed to load Unicode11Addon: $e\n$stackTrace');
      }

      _bindTerminalSubscriptions();

      _initialized = true;
      _bindController();

      try {
        _activateTerminal();
      } catch (_) {}

      _triggerFitWithDelayedRetries();
      if (widget.focusCursorRevision > 0) {
        _restoreScrollPosition(requestFocus: true);
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

  void _writeInitialContent({int? overrideCols, int? overrideRows}) {
    // Signal the fitted size; the session replays its staged history through the
    // store -> controller -> this view's write listener at the real size. The
    // single source of truth is the raw byte stream, not styled-row rebuilds.
    //
    // Callers that already hold a validated size (the first-fit finalize, incl.
    // the force-finalize backstop) pass it in so we don't re-read `_term` here:
    // during the size churn the backstop guards against, `_term` can momentarily
    // sit below the minimum grid, and signaling that too-narrow size leaves the
    // store unsized, which suppresses the live-output flush. The re-replay path
    // (content already written, layout settled) passes nothing and reads the
    // real current size, which is what it wants.
    final fittedRows =
        overrideRows ??
        ((js_util.getProperty(_term, 'rows') as num?)?.toInt() ??
            _lastFittedRows ??
            24);
    final fittedCols =
        overrideCols ??
        ((js_util.getProperty(_term, 'cols') as num?)?.toInt() ??
            _lastFittedCols ??
            80);
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

    var onDataSubscription = _sessionOnDataSubscriptions[_sanitizedId];
    if (onDataSubscription == null) {
      final sessionId = _sanitizedId;
      final onDataCallback = js_util.allowInterop((String data, [dynamic _]) {
        _sessionSavedViewportY.remove(sessionId);
        try {
          final term = _sessionTerms[sessionId];
          if (term != null) {
            js_util.callMethod(term, 'scrollToBottom', []);
          }
        } catch (_) {}
        // Sticky Ctrl (accessory bar): fold an armed Ctrl into the next single
        // character before it reaches the session: arming Ctrl then typing "c"
        // on the soft keyboard sends 0x03 (SIGINT), not a literal "c". A
        // multi-character chunk (paste, IME commit) still consumes the armed
        // Ctrl untransformed, so a latched Ctrl can never linger. State is keyed
        // by session (not `this`) because this callback is cached and reused
        // across State instances.
        if (_sessionCtrlArmed[sessionId] ?? false) {
          final ctrl = data.length == 1 ? controlByteForChar(data) : null;
          _sessionCtrlArmed[sessionId] = false;
          _sessionCtrlRebuild[sessionId]?.call();
          if (ctrl != null) {
            _sessionInputRouter.sendInput(sessionId, ctrl);
            return;
          }
        }
        _sessionInputRouter.sendInput(sessionId, data);
      });
      onDataSubscription = js_util.callMethod(_term, 'onData', [
        onDataCallback,
      ]);
      _sessionOnDataSubscriptions[_sanitizedId] = onDataSubscription;
    }

    var onResizeSubscription = _sessionOnResizeSubscriptions[_sanitizedId];
    if (onResizeSubscription == null) {
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
      onResizeSubscription = js_util.callMethod(_term, 'onResize', [
        onResizeCallback,
      ]);
      _sessionOnResizeSubscriptions[_sanitizedId] = onResizeSubscription;
    }

    var onScrollSubscription = _sessionOnScrollSubscriptions[_sanitizedId];
    if (onScrollSubscription == null) {
      final sessionId = _sanitizedId;
      final onScrollCallback = js_util.allowInterop((
        dynamic newY, [
        dynamic _,
      ]) {
        try {
          final term = _sessionTerms[sessionId];
          if (term == null) return;
          final buffer = js_util.getProperty(term, 'buffer');
          final active = js_util.getProperty(buffer, 'active');
          final baseY = (js_util.getProperty(active, 'baseY') as num).toInt();
          final viewportY = (js_util.getProperty(active, 'viewportY') as num)
              .toInt();
          if (viewportY >= baseY) {
            _sessionSavedViewportY.remove(sessionId);
          } else {
            _sessionSavedViewportY[sessionId] = viewportY;
          }
        } catch (_) {}
      });
      onScrollSubscription = js_util.callMethod(_term, 'onScroll', [
        onScrollCallback,
      ]);
      _sessionOnScrollSubscriptions[_sanitizedId] = onScrollSubscription;
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
    widget.controller.addRefitListener(_onRefit);
  }

  void _unbindController() => _unbindControllerFrom(widget.controller);

  // Removes every listener `_bindController` adds, from an explicit controller —
  // the controller swap in `didUpdateWidget` must detach from the *old* one, and
  // routing both through here keeps the add/remove sets from drifting (a missed
  // `removeRefitListener` on swap would leave an orphaned controller able to
  // force-send a resize-out for this pane).
  void _unbindControllerFrom(TerminalController controller) {
    controller.removeWriteListener(_onWrite);
    controller.removeClearListener(_onClear);
    controller.removeResizeListener(_onResize);
    controller.removeFitListener(_onFit);
    controller.removeRefitListener(_onRefit);
  }

  // The explicit refit — the header button and resume-from-occlusion — as
  // opposed to `_onFit`, which the ResizeObserver fires on an actual element
  // resize.
  //
  // Two things go wrong without it, both because `main.dart` can only see the
  // Dart-side shadow terminal, never this xterm.js grid:
  //
  //  - On resume, a fit that ran while the tab was transitioning can leave the
  //    grid too narrow. `FitAddon.fit()` recomputes it from the real pixels.
  //  - The host may sit at another size — its own stale value, or a second
  //    device's width on a shared PTY. A plain fit only tells the host when the
  //    grid *changed*, so it would not correct a wrong host under a right grid.
  //
  // So: fit, then force our fitted size onto the host by jiggling one row
  // shorter and back. The jiggle guarantees a SIGWINCH even when the size is
  // unchanged, and the program repaints over the live stream at our width.
  //
  // Retried on a delay ladder, because resume fires before the tab's layout has
  // settled: while the element is still 0-width, `_onFit`'s `width>0` guard
  // skips the fit and an immediate send would ship the stale size. The retries
  // land the correct size once layout settles, mirroring the init fit ladder.
  void _onRefit() {
    if (!_initialized) return;
    final generation = ++_refitGeneration;
    _refitAndSend(force: true);
    for (final ms in const [50, 200, 600, 1500]) {
      Future.delayed(Duration(milliseconds: ms), () {
        if (mounted && _initialized && generation == _refitGeneration) {
          _refitAndSend(force: false);
        }
      });
    }
  }

  // One fit-and-force-send pass. `force` sends even when the fitted size is
  // unchanged — needed on the first pass so a device-reclaim (right grid, wrong
  // host) still corrects; the delayed retries pass `false`, so a settled refit
  // does not jiggle the host on every tick, only when a tick actually changes
  // the fitted size.
  void _refitAndSend({required bool force}) {
    // Not during the first-fit handshake: that path owns the initial size and
    // its own host sync, and a force-send here would bypass its history-flush
    // gate. Refit/resume happen well after load, so this only guards the edge.
    if (!_initialContentWritten) return;
    _onFit();
    final cols = (js_util.getProperty(_term, 'cols') as num).toInt();
    final rows = (js_util.getProperty(_term, 'rows') as num).toInt();
    if (cols < 2 || rows < 2) return;
    if (!force && cols == _lastRefitCols && rows == _lastRefitRows) return;
    _lastRefitCols = cols;
    _lastRefitRows = rows;
    _sessionInputRouter.sendResizeOut(_sanitizedId, cols, rows - 1);
    _sessionInputRouter.sendResizeOut(_sanitizedId, cols, rows);
  }

  void _syncInitialBracketedPasteMode() {
    try {
      final isEnabled = widget.terminal?.bracketedPasteMode ?? false;
      if (_term != null) {
        final modes = js_util.getProperty(_term, 'modes');
        if (modes != null) {
          js_util.setProperty(modes, 'bracketedPasteMode', isEnabled);
        }
      }
    } catch (_) {}
  }

  bool _isBracketedPasteEnabled() {
    try {
      if (_term != null) {
        final modes = js_util.getProperty(_term, 'modes');
        if (modes != null) {
          final val = js_util.getProperty(modes, 'bracketedPasteMode');
          if (val == true) return true;
        }
      }
    } catch (_) {}
    try {
      final dynTerm = widget.terminal;
      if (dynTerm != null) {
        final val = js_util.getProperty(dynTerm, 'bracketedPasteMode');
        if (val == true) return true;
      }
    } catch (_) {}
    return false;
  }

  /// Attaches this pane's listeners to [_container], taking off whatever the
  /// previous owner of that container left behind.
  ///
  /// Called on both paths through `initState`, the one that builds a container
  /// and the one that adopts a cached one. Binding only on the building path was
  /// the older behaviour, and it left an adopted container with no paste, focus
  /// or Tab handling of its own while `dispose` still tried to take those
  /// listeners off, throwing before the rest of the teardown could run.
  void _bindContainerEvents() {
    _syncInitialBracketedPasteMode();
    _containerEventOwners[_sanitizedId]?._unbindContainerEvents();
    _containerEventOwners[_sanitizedId] = this;
    _containerMouseDownSubscription = _container.onMouseDown.listen((event) {
      if (_initialized) {
        try {
          _activateTerminal();
        } catch (_) {}
      }
    });

    _containerClickSubscription = _container.onClick.listen((event) {
      if (_initialized) {
        try {
          _activateTerminal();
        } catch (_) {}
      }
    });

    _containerKeyDownSubscription = _container.onKeyDown.listen((event) {
      if (event.key == 'Tab') {
        event.preventDefault();
      }
    });

    _containerWheelSubscription = _container.onWheel.listen((event) {
      if (_currentRoute?.isCurrent == false) {
        event.preventDefault();
        event.stopPropagation();
      }
    });

    void pasteListener(html.Event event) {
      if (event is html.ClipboardEvent) {
        event.preventDefault();
        event.stopPropagation();
        final clipboardData = event.clipboardData;
        final text = clipboardData?.getData('text/plain') ?? '';
        if (text.isNotEmpty) {
          final isBracketed = _isBracketedPasteEnabled();
          _sendInput(formatPasteInput(text, isBracketed));
        }
      }
    }

    _containerPasteListener = pasteListener;
    _container.addEventListener('paste', pasteListener, true);
  }

  /// Releases the listeners [_bindContainerEvents] attached, and is safe to call
  /// when there are none: an adopted container may already have been handed on
  /// to a newer pane, which unbinds this one as it takes over.
  void _unbindContainerEvents() {
    _containerMouseDownSubscription?.cancel();
    _containerMouseDownSubscription = null;
    _containerClickSubscription?.cancel();
    _containerClickSubscription = null;
    _containerKeyDownSubscription?.cancel();
    _containerKeyDownSubscription = null;
    _containerWheelSubscription?.cancel();
    _containerWheelSubscription = null;
    final pasteListener = _containerPasteListener;
    if (pasteListener != null) {
      _container.removeEventListener('paste', pasteListener, true);
      _containerPasteListener = null;
    }
  }

  String? _keyboardEventToInput(html.KeyboardEvent event) {
    if (event.metaKey || event.altKey) {
      return null;
    }

    if (event.ctrlKey) {
      final key = event.key?.toLowerCase();
      if (key != null && key.length == 1) {
        final code = key.codeUnitAt(0);
        if (code >= 97 && code <= 122) {
          // Ctrl+a through Ctrl+z -> 0x01 through 0x1A
          return String.fromCharCode(code - 96);
        }
        switch (key) {
          case '@':
          case ' ':
            return '\x00';
          case '[':
            return '\x1b';
          case '\\':
            return '\x1c';
          case ']':
            return '\x1d';
          case '^':
            return '\x1e';
          case '_':
            return '\x1f';
        }
      }
      return null;
    }

    final key = event.key;
    if (key == null) return null;

    switch (key) {
      case 'Enter':
        return '\r';
      case 'Backspace':
        return '\x7f';
      case 'Tab':
        return event.shiftKey ? '\x1b[Z' : '\t';
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
      default:
        if (key.length == 1) {
          return key;
        }
        return null;
    }
  }

  bool _eventTargetsTerminal(html.Event event) {
    final isCurrent = _currentRoute?.isCurrent ?? true;
    if (!mounted || widget.isExited || !isCurrent) {
      return false;
    }

    // If this pane's FocusNode has Flutter focus, it owns the input.
    if (_focusNode.hasFocus) {
      return true;
    }

    // Otherwise, check if the event target or composed path originates from this container.
    try {
      final path = js_util.callMethod(event, 'composedPath', []) as List?;
      if (path != null && path.contains(_container)) {
        return true;
      }
    } catch (_) {}

    final target = event.target;
    if (target is html.Node && _container.contains(target)) {
      return true;
    }

    // If focus is currently on an HTML input or textarea outside this terminal
    // (such as a modal search box or pairing input), do not intercept.
    final active = html.document.activeElement;
    if (active is html.InputElement ||
        (active is html.TextAreaElement && !_container.contains(active))) {
      return false;
    }

    return false;
  }

  bool _isActiveElementInTerminal() {
    final active = html.document.activeElement;
    if (active == null) return false;
    return _container.contains(active);
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
    _resetTerminalSafe();
  }

  void _onResize(int cols, int rows) {
    if (!_initialized) return;
    js_util.callMethod(_term, 'resize', [cols, rows]);
  }

  void _finishInitialContent(int fittedCols, int fittedRows) {
    _stabilityTimer?.cancel();
    _forceFinalizeTimer?.cancel();
    _forceFinalizeTimer = null;
    _initialContentWritten = true;
    _writeInitialContent(overrideCols: fittedCols, overrideRows: fittedRows);
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
            // Backstop: arm once now that we have a valid sized fit. The
            // stability debounce below restarts on every size change, so if the
            // layout keeps nudging the size it may never fire within the
            // one-shot retry ladder — leaving staged history unflushed until a
            // resize/tab-switch. This deadline force-finalizes regardless.
            _forceFinalizeTimer ??= Timer(
              const Duration(milliseconds: 800),
              () {
                if (mounted &&
                    !_initialContentWritten &&
                    (_lastFittedRows ?? 0) >= 5 &&
                    (_lastFittedCols ?? 0) >= 10) {
                  _finishInitialContent(_lastFittedCols!, _lastFittedRows!);
                }
              },
            );
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
      _restoreScrollPosition(requestFocus: true);
    }
  }

  void _focusCursorNowAndAfterReplay() {
    _focusCursorAfterReplay = true;
    _restoreScrollPosition(requestFocus: true);
  }

  void _restoreScrollPosition({required bool requestFocus}) {
    void jump() {
      if (!mounted || !_initialized) return;
      final savedY = _sessionSavedViewportY[_sanitizedId];
      try {
        if (savedY != null) {
          js_util.callMethod(_term, 'scrollToLine', [savedY]);
        } else {
          js_util.callMethod(_term, 'scrollToBottom', []);
        }
      } catch (_) {}
      if (requestFocus) {
        _activateTerminal();
      }
    }

    Future.delayed(Duration.zero, jump);
    _scrollToCursorTimer?.cancel();
    _scrollToCursorTimer = Timer(const Duration(milliseconds: 50), jump);
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
      _unbindControllerFrom(oldWidget.controller);
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
    _forceFinalizeTimer?.cancel();
    _scrollToCursorTimer?.cancel();
    html.window.removeEventListener('keydown', _windowKeyDownListener, true);
    _unbindContainerEvents();
    _sessionInputRouter.unbind(_sanitizedId, _inputRouteToken);
    if (_resizeObserver != null) {
      try {
        js_util.callMethod(_resizeObserver, 'disconnect', []);
      } catch (_) {}
    }
    _focusNode.dispose();
    _unbindController();
    // Everything above releases only what this pane holds. The cached session is
    // shared across panes and survives switching sessions so its DOM container,
    // xterm instance, and scroll position remain preserved. Ending the session
    // itself goes through `TerminalPane.destroySession` instead.
    if (identical(_containerEventOwners[_sanitizedId], this)) {
      _containerEventOwners.remove(_sanitizedId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _currentRoute = ModalRoute.of(context);
    _syncPointerEvents();

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onFocusChange: (hasFocus) {
        if (hasFocus && _initialized) {
          _activateTerminal();
        }
      },
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
          final terminal = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _activateTerminal(),
            child: Container(
              color: const Color(0xff0d1113),
              child: HtmlElementView(viewType: _viewType),
            ),
          );
          // Desktop browsers keep the full-height terminal; only a mobile-OS
          // browser gets the on-screen key row (the soft keyboard lacks Esc, Tab,
          // arrows, etc.). The xterm fit addon re-measures the shrunken container
          // on the size change, so the grid stays correct above the bar.
          if (!_isMobile) return terminal;
          return Column(
            children: [
              Expanded(child: terminal),
              Padding(
                // Float above the soft keyboard when the browser reports its
                // inset; a resizing Scaffold already zeroes this out, so it never
                // double-counts.
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                ),
                child: TerminalAccessoryBar(
                  onSend: _sendAccessory,
                  onToggleCtrl: _toggleCtrl,
                  ctrlArmed: _ctrlArmed,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
