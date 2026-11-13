import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerExitEvent,
        PointerHoverEvent,
        PointerPanZoomEndEvent,
        PointerPanZoomStartEvent,
        PointerPanZoomUpdateEvent,
        PointerScrollEvent,
        PointerSignalEvent,
        kMiddleMouseButton,
        kPrimaryButton,
        kSecondaryMouseButton,
        kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart'
    show
        AutofillScope,
        Clipboard,
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyRepeatEvent,
        KeyboardInsertedContent,
        KeyboardLockMode,
        LogicalKeyboardKey,
        RawFloatingCursorPoint,
        SmartDashesType,
        SmartQuotesType,
        TextEditingValue,
        TextInput,
        TextInputAction,
        TextInputClient,
        TextInputConfiguration,
        TextInputConnection,
        TextInputControl,
        TextInputType,
        TextSelection;
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/platform_env_io.dart'
    if (dart.library.js_util) 'package:triage_client/platform_env_web.dart';
import 'package:triage_client/services/external_navigation.dart';
import 'package:triage_client/terminal/control_bytes.dart';
import 'package:triage_client/terminal/copy_button_layout.dart';
import 'package:triage_client/terminal/debug_log.dart';
import 'package:triage_client/terminal/emulator_query_response.dart';
import 'package:triage_client/terminal/mobile_auto_space.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';
import 'package:triage_client/terminal/terminal_key_encoder.dart';
import 'package:triage_client/terminal/terminal_keyboard_mode.dart';
import 'package:triage_client/terminal/terminal_links.dart';
import 'package:triage_client/terminal/terminal_mouse_encoder.dart';
import 'package:triage_client/terminal/terminal_paste.dart';
import 'package:triage_client/terminal/terminal_scroll_anchor.dart';
import 'package:triage_client/terminal/terminal_selection.dart';
import 'package:triage_client/widgets/multiline_paste_dialog.dart';
import 'package:triage_client/widgets/terminal_accessory_bar.dart';
import 'package:triage_client/widgets/terminal_grid_render_box.dart';
import 'package:triage_client/widgets/terminal_scrollbar.dart';

/// Transient pill shown at the top of the terminal when scrollback paging
/// exhausts without yielding older lines.
class NoOlderScrollbackPill extends StatelessWidget {
  const NoOlderScrollbackPill({super.key});

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xcc161b1d),
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            'No older scrollback in reach',
            style: TextStyle(color: Color(0xffcdd7d6), fontSize: 12),
          ),
        ),
      ),
    );
  }
}

/// Whether a landed history page was barren: it added no buffer lines while the
/// user is still near the top.
bool shouldContinuePastBarrenPage({
  required int addedLines,
  required bool nearTop,
}) => addedLines <= 0 && nearTop;

/// Latch behind [NoOlderScrollbackPill]: shows the pill for 3 seconds,
/// re-arming on every exhaustion note.
mixin NoOlderScrollbackLatch<T extends StatefulWidget> on State<T> {
  bool showNoOlderScrollback = false;
  Timer? _noOlderScrollbackTimer;

  void noteHistoryExhausted() {
    _noOlderScrollbackTimer?.cancel();
    _noOlderScrollbackTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => showNoOlderScrollback = false);
      }
    });
    if (mounted && !showNoOlderScrollback) {
      setState(() => showNoOlderScrollback = true);
    }
  }

  void dismissNoOlderScrollback() {
    _noOlderScrollbackTimer?.cancel();
    _noOlderScrollbackTimer = null;
    if (showNoOlderScrollback && mounted) {
      setState(() => showNoOlderScrollback = false);
    } else {
      showNoOlderScrollback = false;
    }
  }

  void cancelNoOlderScrollbackTimer() {
    _noOlderScrollbackTimer?.cancel();
    _noOlderScrollbackTimer = null;
    showNoOlderScrollback = false;
  }
}

class TerminalController {
  final List<void Function(String)> _writeListeners = [];
  final List<void Function()> _clearListeners = [];
  final List<void Function(int, int)> _resizeListeners = [];
  final List<void Function()> _fitListeners = [];
  final List<void Function()> _refitListeners = [];
  final List<void Function(String)> _inputListeners = [];
  final List<void Function(int, int)> _resizeOutListeners = [];
  final List<void Function()> _interactionListeners = [];

  final List<String> _writeBuffer = [];

  void addWriteListener(void Function(String) listener) {
    _writeListeners.add(listener);
    tdbg(
      'ctrl.addWrite',
      'ctrl#${identityHashCode(this)} now '
          '${_writeListeners.length} listeners, '
          'buffered=${_writeBuffer.length}',
    );
    if (_writeBuffer.isNotEmpty) {
      for (final data in _writeBuffer) {
        listener(data);
      }
      _writeBuffer.clear();
    }
  }

  void removeWriteListener(void Function(String) listener) =>
      _writeListeners.remove(listener);

  void addClearListener(void Function() listener) =>
      _clearListeners.add(listener);
  void removeClearListener(void Function() listener) =>
      _clearListeners.remove(listener);

  void addResizeListener(void Function(int, int) listener) =>
      _resizeListeners.add(listener);
  void removeResizeListener(void Function(int, int) listener) =>
      _resizeListeners.remove(listener);

  void addFitListener(void Function() listener) => _fitListeners.add(listener);
  void removeFitListener(void Function() listener) =>
      _fitListeners.remove(listener);

  void addRefitListener(void Function() listener) =>
      _refitListeners.add(listener);
  void removeRefitListener(void Function() listener) =>
      _refitListeners.remove(listener);

  void addInputListener(void Function(String) listener) =>
      _inputListeners.add(listener);
  void removeInputListener(void Function(String) listener) =>
      _inputListeners.remove(listener);

  void addResizeOutListener(void Function(int, int) listener) =>
      _resizeOutListeners.add(listener);
  void removeResizeOutListener(void Function(int, int) listener) =>
      _resizeOutListeners.remove(listener);

  void addInteractionListener(void Function() listener) =>
      _interactionListeners.add(listener);
  void removeInteractionListener(void Function() listener) =>
      _interactionListeners.remove(listener);

  void notifyInteraction() {
    for (final listener in List.from(_interactionListeners)) {
      listener();
    }
  }

  final List<void Function()> _historyReplayedListeners = [];
  void addHistoryReplayedListener(void Function() listener) =>
      _historyReplayedListeners.add(listener);
  void removeHistoryReplayedListener(void Function() listener) =>
      _historyReplayedListeners.remove(listener);

  void notifyHistoryReplayed() {
    for (final listener in List.from(_historyReplayedListeners)) {
      listener();
    }
  }

  final List<void Function()> _historyPageStartedListeners = [];
  void addHistoryPageStartedListener(void Function() listener) =>
      _historyPageStartedListeners.add(listener);
  void removeHistoryPageStartedListener(void Function() listener) =>
      _historyPageStartedListeners.remove(listener);

  void notifyHistoryPageStarted() {
    for (final listener in List.from(_historyPageStartedListeners)) {
      listener();
    }
  }

  void write(String data) {
    if (_writeListeners.isEmpty) {
      _writeBuffer.add(data);
    } else {
      final listeners = List.of(_writeListeners);
      for (var i = 0; i < listeners.length; i++) {
        try {
          listeners[i](data);
        } catch (error, stack) {
          tdbg('ctrl.write', 'listener #$i THREW: $error\n$stack');
        }
      }
    }
  }

  void clear() {
    for (final listener in List.from(_clearListeners)) {
      listener();
    }
  }

  void resize(int cols, int rows) {
    for (final listener in List.from(_resizeListeners)) {
      listener(cols, rows);
    }
  }

  void fit() {
    for (final listener in List.from(_fitListeners)) {
      listener();
    }
  }

  void refit() {
    for (final listener in List.from(_refitListeners)) {
      listener();
    }
  }

  void sendInput(String data, {bool fromHardwareKey = false}) {
    if (isEmulatorQueryResponse(data, fromHardwareKey: fromHardwareKey)) {
      return;
    }
    for (final listener in List.from(_inputListeners)) {
      listener(data);
    }
  }

  void sendResizeOut(int cols, int rows) {
    for (final listener in List.from(_resizeOutListeners)) {
      listener(cols, rows);
    }
  }

  void dispose() {
    _writeListeners.clear();
    _clearListeners.clear();
    _resizeListeners.clear();
    _fitListeners.clear();
    _refitListeners.clear();
    _inputListeners.clear();
    _resizeOutListeners.clear();
    _interactionListeners.clear();
    _historyReplayedListeners.clear();
    _historyPageStartedListeners.clear();
    _writeBuffer.clear();
  }
}

class TerminalSessionInputRouter {
  final Map<String, _TerminalSessionRoute> _routes = {};

  bool hasRoute(String sessionId) => _routes.containsKey(sessionId);

  Object bind(String sessionId, TerminalController controller) {
    final token = Object();
    _routes[sessionId] = _TerminalSessionRoute(controller, token);
    return token;
  }

  void rebind(String sessionId, TerminalController controller) {
    final route = _routes[sessionId];
    if (route != null) {
      _routes[sessionId] = _TerminalSessionRoute(controller, route.token);
    } else {
      bind(sessionId, controller);
    }
  }

  void unbind(String sessionId, Object token) {
    final route = _routes[sessionId];
    if (route != null && identical(route.token, token)) {
      _routes.remove(sessionId);
    }
  }

  void remove(String sessionId) {
    _routes.remove(sessionId);
  }

  void sendInput(String sessionId, String data) {
    _routes[sessionId]?.controller.sendInput(data);
  }

  void sendResizeOut(String sessionId, int cols, int rows) {
    _routes[sessionId]?.controller.sendResizeOut(cols, rows);
  }

  void notifyInteraction(String sessionId) {
    _routes[sessionId]?.controller.notifyInteraction();
  }
}

class _TerminalSessionRoute {
  _TerminalSessionRoute(this.controller, this.token);

  final TerminalController controller;
  final Object token;
}

/// Unified cross-platform terminal view backed by [TerminalCellBuffer] and
/// [TerminalGridView]. Renders identically on Web, iOS, Android, macOS, Linux,
/// and Windows with zero client-side VT escape-sequence parsing.
class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.terminalId,
    required this.controller,
    required this.terminal,
    required this.fallbackRows,
    this.onTerminalResizeBind,
    this.focusCursorRevision = 0,
    this.onViewFit,
    this.onNearTop,
    this.onFetchScrollbackRows,
    this.onOpenUrl,
    this.bracketedPasteEnabled = false,
    this.isExited = false,
    this.isLoading = false,
    this.isObscured = false,
    this.interactionEnabled = true,
    this.softKeyboardEnabled = true,
  });

  final String terminalId;
  final TerminalController controller;
  final TerminalCellBuffer terminal;
  final bool Function()? onNearTop;
  final void Function(int firstVirtualRow, int lastVirtualRow)?
  onFetchScrollbackRows;
  final FutureOr<void> Function(Uri uri)? onOpenUrl;
  final bool bracketedPasteEnabled;

  /// Plain rows rendered only by the FLUTTER_TEST fallback view.
  final List<StyledRow> fallbackRows;

  final void Function(void Function(int w, int h, int pw, int ph)? callback)?
  onTerminalResizeBind;

  /// Reports the fitted grid size after layout.
  final void Function(int cols, int rows)? onViewFit;

  final int focusCursorRevision;
  final bool isExited;
  final bool isLoading;
  final bool isObscured;
  final bool interactionEnabled;
  final bool softKeyboardEnabled;

  static void destroySession(String terminalId) {
    final pane = _TerminalPaneState._mountedPanes.remove(terminalId);
    if (pane != null) {
      pane._sessionDestroyed = true;
      pane._resizeOutDebounceTimer?.cancel();
      pane._resizeOutDebounceTimer = null;
      pane._pendingResizeOutCols = null;
      pane._pendingResizeOutRows = null;
      pane._metricsSettleTimer?.cancel();
      pane._metricsSettleTimer = null;
      pane._scrollToCursorTimer?.cancel();
      pane._scrollToCursorTimer = null;
      pane._clearPointerReleaseTimers();
      pane._clearPageAnchor();
      pane._pageJumpGeneration++;
      pane._scrollToCursorGeneration++;
      pane._scrollAnchor.clear();
    }
    _TerminalPaneState._clearSavedSessionScroll(terminalId);
    _TerminalPaneState._sessionBracketedPasteModes.remove(terminalId);
    _TerminalPaneState._sessionLastResizeOutCols.remove(terminalId);
    _TerminalPaneState._sessionLastResizeOutRows.remove(terminalId);
    _TerminalPaneState._sessionLastGridSize.remove(terminalId);
  }

  static void setBracketedPasteMode(String terminalId, bool enabled) {
    _TerminalPaneState._sessionBracketedPasteModes[terminalId] = enabled;
    final pane = _TerminalPaneState._mountedPanes[terminalId];
    if (pane != null && pane.mounted) {
      pane._terminal.setBracketedPasteMode(enabled);
    }
  }

  static void rebindSessionController(
    String terminalId,
    TerminalController controller,
  ) {
    final pane = _TerminalPaneState._mountedPanes[terminalId];
    if (pane != null && pane.mounted) {
      pane._bindController(controller);
    }
  }

  /// Live grid size as (rows, cols); null when unknown.
  /// Rows-first: destructure rows as $1, cols as $2.
  static (int, int)? getCachedTerminalSize(String terminalId) {
    return _TerminalPaneState._sessionLastGridSize[terminalId];
  }

  /// Last fitted workspace grid size as (rows, cols).
  static (int, int)? getLastFittedWorkspaceSize() =>
      _TerminalPaneState._lastWorkspaceFittedSize;

  @visibleForTesting
  static void resetCachedLayoutSizesForTest() {
    _TerminalPaneState._lastWorkspaceFittedSize = null;
    _TerminalPaneState._sessionLastGridSize.clear();
  }

  static void invalidateCachedResizeOut(String terminalId) {
    _TerminalPaneState._sessionLastResizeOutCols.remove(terminalId);
    _TerminalPaneState._sessionLastResizeOutRows.remove(terminalId);
  }

  /// When true in widget tests, renders the real [TerminalGridView]
  /// ([RenderTerminalGrid]) instead of the [SingleChildScrollView] fallback.
  @visibleForTesting
  static bool debugForceNativeTerminalView = false;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane>
    with WidgetsBindingObserver, NoOlderScrollbackLatch
    implements TextInputClient {
  static final Map<String, _TerminalPaneState> _mountedPanes = {};
  static final Map<String, double> _sessionSavedScrollOffsets = {};
  static final Map<String, TerminalScrollAnchor> _sessionSavedScrollAnchors =
      {};
  static final Map<String, double> _sessionSavedDistanceFromBottom = {};
  static final Map<String, double> _sessionSavedScrollFractions = {};
  static final Map<String, int> _sessionSavedEraseScrollbackGen = {};
  static final Map<String, int> _sessionLastResizeOutCols = {};
  static final Map<String, int> _sessionLastResizeOutRows = {};
  static final Map<String, (int, int)> _sessionLastGridSize = {};
  static final Map<String, bool> _sessionBracketedPasteModes = {};
  static (int, int)? _lastWorkspaceFittedSize;

  static void _clearSavedSessionScroll(String id) {
    _sessionSavedScrollOffsets.remove(id);
    _sessionSavedScrollAnchors.remove(id);
    _sessionSavedDistanceFromBottom.remove(id);
    _sessionSavedScrollFractions.remove(id);
    _sessionSavedEraseScrollbackGen.remove(id);
  }

  bool _hasValidSavedScroll() {
    if (_sessionDestroyed) return false;
    final savedGen = _sessionSavedEraseScrollbackGen[widget.terminalId];
    if (savedGen != null &&
        !_terminal.isUsingAltBuffer &&
        savedGen != _terminal.eraseScrollbackGen) {
      _clearSavedSessionScroll(widget.terminalId);
      _scrollAnchor.clear();
      return false;
    }
    if (_scrollAnchor.hasAnchor) {
      return true;
    }
    if (!_terminal.isUsingAltBuffer &&
        _sessionSavedScrollAnchors.containsKey(widget.terminalId)) {
      final savedAnchor = _sessionSavedScrollAnchors[widget.terminalId]!;
      if (!savedAnchor.hasAnchor) {
        _sessionSavedScrollAnchors.remove(widget.terminalId);
        if (savedGen != null && savedGen != _terminal.eraseScrollbackGen) {
          _clearSavedSessionScroll(widget.terminalId);
          return false;
        }
      }
    }
    return _sessionSavedScrollOffsets.containsKey(widget.terminalId);
  }

  static const double _kBottomScrollSentinel = 1e9;
  static const double _kFontSize = 15.0;
  static const double _kLineHeightScale = 1.2;
  static const String _kImeSentinel = '  ';

  TerminalCellBuffer get _terminal => widget.terminal;
  final FocusNode _focusNode = FocusNode();
  late final ScrollController _scrollController;
  TerminalController? _boundController;
  final GlobalKey<TerminalGridViewState> _gridViewKey = GlobalKey();

  TextInputConnection? _textInputConnection;
  TextEditingValue _currentImeValue = const TextEditingValue(
    text: _kImeSentinel,
    selection: TextSelection.collapsed(offset: _kImeSentinel.length),
  );

  double? _pageAnchorPixels;
  int? _pageAnchorLines;
  DateTime? _pageAnchorAt;
  CellOffset? _pageSelectionBase;
  CellOffset? _pageSelectionExtent;
  int _pageJumpGeneration = 0;
  int _scrollToCursorGeneration = 0;

  void _clearPageAnchor() {
    _pageAnchorPixels = null;
    _pageAnchorLines = null;
    _pageAnchorAt = null;
    _pageSelectionBase = null;
    _pageSelectionExtent = null;
  }

  final TerminalScrollAnchor _scrollAnchor = TerminalScrollAnchor();
  bool _suppressAnchorCapture = false;
  bool _repinScheduled = false;
  double? _lastScrollPixels;

  final Set<int> _activePointers = <int>{};
  bool _panZoomActive = false;
  bool get _hasActivePointerOrPanZoom =>
      _activePointers.isNotEmpty || _panZoomActive;
  bool _pendingBottomSnapOnPointerUp = false;
  int? _mobileAltScrollPointer;
  Offset? _mobileAltScrollLastPosition;
  bool _metricsRestoreInFlight = false;
  bool _metricsResizeSettling = false;
  Timer? _metricsSettleTimer;

  Timer? _resizeOutDebounceTimer;
  Timer? _scrollToCursorTimer;
  int? _pendingResizeOutCols;
  int? _pendingResizeOutRows;

  bool _ctrlArmed = false;
  bool _isPasting = false;
  bool _isPasteDialogShowing = false;
  final MobileAutoSpaceTracker _mobileAutoSpace = MobileAutoSpaceTracker();

  TerminalSelectionRange? _selection;
  TerminalSelectionRange? _copyTarget;
  TerminalCellBuffer? _copyTargetBuffer;
  bool _copyTargetIsAlt = false;
  final GlobalKey _copyOverlayKey = GlobalKey();
  bool _copyRebuildScheduled = false;

  _AnchoredCell? _selectionAnchor;

  int? _shiftClickPointer;
  Offset? _shiftClickDownPosition;
  static const double _clickMoveSlop = 4.0;
  static const Duration _multiClickWindow = Duration(milliseconds: 450);
  DateTime? _lastDesktopClickAt;
  Offset? _lastDesktopClickPosition;
  int _desktopClickCount = 0;

  int? _dragPointer;
  Offset? _dragDownPosition;
  Offset? _dragLastPosition;
  _AnchoredCell? _dragAnchorCell;
  bool _dragSelecting = false;
  bool _dragExtendScheduled = false;
  int? _mouseReportPointer;
  TerminalMouseButton _mouseReportButton = TerminalMouseButton.left;
  CellOffset? _mouseReportLastCell;
  CellOffset? _mouseHoverLastCell;
  int? _mobileTapPointer;
  Offset? _mobileTapDownPosition;
  CellOffset? _mobileTapDownCell;
  _AnchoredCell? _mobileLongPressAnchor;
  TerminalLink? _hoveredLink;
  Offset? _lastHoverGlobalPosition;
  int? _linkTapPointer;
  Offset? _linkTapDownPosition;
  TerminalLink? _linkTapCandidate;
  bool _linkRefreshScheduled = false;
  Timer? _autoScrollTimer;
  double _autoScrollVelocity = 0;
  static const double _autoScrollEdge = 28.0;
  static const Duration _autoScrollTick = Duration(milliseconds: 16);
  static const double _autoScrollMaxStep = 28.0;

  bool _lastIsAltBuffer = false;
  bool? _lastReportedFocus;
  ModalRoute<dynamic>? _modalRoute;
  bool _routeIsCurrent = true;
  bool _isActive = true;
  bool _didBuildOnce = false;
  bool _sessionDestroyed = false;
  bool _inGridMetricsResize = false;
  bool _awaitingNearTopFetch = false;
  bool _nearTopCheckScheduled = false;
  double _altScrollDeltaAccum = 0.0;
  final List<Timer> _pointerReleaseTimers = [];
  VoidCallback? _disposeWebPasteListener;

  _AnchoredCell _anchorAt(CellOffset cell) => _AnchoredCell(
    cell: cell,
    buffer: _terminal,
    trimmedTopRows: _terminal.trimmedTopRows,
    eraseScrollbackGen: _terminal.eraseScrollbackGen,
    reflowGen: _terminal.reflowGen,
    isAltScreen: _terminal.isUsingAltBuffer,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleHardwareKeyForLinks);
    _disposeWebPasteListener = registerWebPasteListener(_onWebDomPaste);
    final savedGen = _sessionSavedEraseScrollbackGen[widget.terminalId];
    if (savedGen != null &&
        !_terminal.isUsingAltBuffer &&
        savedGen != _terminal.eraseScrollbackGen) {
      _clearSavedSessionScroll(widget.terminalId);
    }
    final savedOffset = _sessionSavedScrollOffsets[widget.terminalId];
    final initialOffset = savedOffset ?? _kBottomScrollSentinel;
    final savedAnchor = _sessionSavedScrollAnchors[widget.terminalId];
    if (savedAnchor != null) {
      _scrollAnchor.copyFrom(savedAnchor);
    }
    _scrollController = ScrollController(initialScrollOffset: initialOffset);
    _focusNode.addListener(_onFocusChanged);
    _suppressAnchorCapture = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isActive || _sessionDestroyed) return;
      _suppressAnchorCapture = false;
      if (!_metricsResizeSettling) {
        _syncTerminalSizeToRender(
          sendResizeOut: !widget.isLoading && !widget.isExited,
        );
      }
      if (_scrollController.hasClients &&
          _scrollController.position.hasContentDimensions) {
        _lastScrollPixels = _scrollController.position.pixels;
      }
      _syncFocusReporting();
      _syncImeConnection();
    });
    widget.onTerminalResizeBind?.call(_onTerminalResize);
    _scrollController.addListener(_onScrollChanged);
    _bindTerminal(_terminal, syncFocus: false);
    _mountedPanes[widget.terminalId] = this;
    _bindController(widget.controller);
    if (widget.focusCursorRevision > 0) {
      _scrollToCursor(requestFocus: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _modalRoute = ModalRoute.of(context);
    _routeIsCurrent = _modalRoute?.isCurrent ?? true;
    _syncFocusReporting();
    if (_didBuildOnce) {
      _syncImeConnection();
    }
  }

  @override
  void activate() {
    super.activate();
    _isActive = true;
    _syncFocusReporting();
  }

  @override
  void deactivate() {
    _isActive = false;
    _syncFocusReporting();
    _closeImeConnection();
    super.deactivate();
  }

  void _bindController(TerminalController controller) {
    if (identical(_boundController, controller)) return;
    _unbindController();
    _boundController = controller;
    controller.addFitListener(_onFit);
    controller.addRefitListener(_onRefit);
    controller.addClearListener(_onClear);
    controller.addHistoryReplayedListener(_onHistoryReplayed);
    controller.addHistoryPageStartedListener(_onHistoryPageStarted);
  }

  void _unbindController() {
    final c = _boundController;
    if (c == null) return;
    c.removeFitListener(_onFit);
    c.removeRefitListener(_onRefit);
    c.removeClearListener(_onClear);
    c.removeHistoryReplayedListener(_onHistoryReplayed);
    c.removeHistoryPageStartedListener(_onHistoryPageStarted);
    _boundController = null;
  }

  void _bindTerminal(TerminalCellBuffer terminal, {bool syncFocus = true}) {
    final seededBracketed = _sessionBracketedPasteModes[widget.terminalId];
    if (seededBracketed != null && terminal.lastFrameSeq == 0) {
      terminal.setBracketedPasteMode(seededBracketed);
    } else if (widget.bracketedPasteEnabled && terminal.lastFrameSeq == 0) {
      terminal.setBracketedPasteMode(true);
    }
    if (!_sessionDestroyed &&
        (!widget.isLoading || terminal.lastFrameSeq > 0)) {
      _sessionBracketedPasteModes[widget.terminalId] =
          terminal.bracketedPasteMode;
    }
    _lastIsAltBuffer = terminal.isUsingAltBuffer;
    _lastReportedFocus = null;
    _awaitingNearTopFetch = false;
    _altScrollDeltaAccum = 0.0;
    terminal.onOutput = _onTerminalOutput;
    terminal.addListener(_onTerminalContentChanged);
    if (syncFocus) {
      _syncFocusReporting();
    }
  }

  void _unbindTerminal(TerminalCellBuffer terminal) {
    if (identical(terminal.onOutput, _onTerminalOutput)) {
      terminal.onOutput = null;
    }
    terminal.removeListener(_onTerminalContentChanged);
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final idChanged = oldWidget.terminalId != widget.terminalId;
    final sessionSwapped =
        !identical(oldWidget.terminal, widget.terminal) || idChanged;
    final prevOldOwner = _mountedPanes[oldWidget.terminalId];
    final wasRegisteredOldOwner = identical(prevOldOwner, this);
    if (idChanged && wasRegisteredOldOwner) {
      _mountedPanes.remove(oldWidget.terminalId);
    }
    if (sessionSwapped) {
      _sessionDestroyed = false;
      _mountedPanes[widget.terminalId] = this;
    } else if (!_sessionDestroyed && _mountedPanes[widget.terminalId] == null) {
      _mountedPanes[widget.terminalId] = this;
    }
    if (!sessionSwapped &&
        _terminal.lastFrameSeq == 0 &&
        oldWidget.bracketedPasteEnabled != widget.bracketedPasteEnabled) {
      if (!_sessionDestroyed) {
        _sessionBracketedPasteModes[widget.terminalId] =
            widget.bracketedPasteEnabled;
      }
      _terminal.setBracketedPasteMode(widget.bracketedPasteEnabled);
    }
    if (oldWidget.onTerminalResizeBind != widget.onTerminalResizeBind ||
        idChanged) {
      final currentOldOwner = _mountedPanes[oldWidget.terminalId];
      if (currentOldOwner == null || identical(currentOldOwner, this)) {
        oldWidget.onTerminalResizeBind?.call(null);
      }
      if (!_sessionDestroyed) {
        widget.onTerminalResizeBind?.call(_onTerminalResize);
      }
    }
    if (sessionSwapped) {
      _clearPageAnchor();
      _pageJumpGeneration++;
      dismissNoOlderScrollback();
      if (idChanged && wasRegisteredOldOwner) {
        _saveScrollOffset(oldWidget.terminalId, null, null, oldWidget.terminal);
      }
      _unbindTerminal(oldWidget.terminal);
      _bindTerminal(widget.terminal);
      _resetImeSentinel();
      _selectionAnchor = null;
      _shiftClickPointer = null;
      _shiftClickDownPosition = null;
      _desktopClickCount = 0;
      _lastDesktopClickAt = null;
      _lastDesktopClickPosition = null;
      _copyTarget = null;
      _copyTargetBuffer = null;
      _selection = null;
      final savedAnchor = _sessionSavedScrollAnchors[widget.terminalId];
      if (savedAnchor != null) {
        _scrollAnchor.copyFrom(savedAnchor);
      } else {
        _scrollAnchor.clear();
      }
      _activePointers.clear();
      _panZoomActive = false;
      _mobileAltScrollPointer = null;
      _mobileAltScrollLastPosition = null;
      _mobileTapPointer = null;
      _mobileTapDownPosition = null;
      _mobileTapDownCell = null;
      _mobileLongPressAnchor = null;
      _clearLinkTap();
      _hoveredLink = null;
      _lastHoverGlobalPosition = null;
      _mouseReportPointer = null;
      _mouseReportButton = TerminalMouseButton.left;
      _mouseReportLastCell = null;
      _mouseHoverLastCell = null;
      _lastScrollPixels = null;
      _ctrlArmed = false;
      _mobileAutoSpace.reset();
      _endDrag();
      final hasSavedScroll = _hasValidSavedScroll();
      if (_scrollController.hasClients &&
          _scrollController.position.hasContentDimensions) {
        if (!hasSavedScroll) {
          _snapToBottom(_scrollController.position);
        } else {
          _restoreSavedScrollPosition(_lineHeight() ?? 18.0);
        }
      }
      _scrollToCursor(requestFocus: true, forceBottom: !hasSavedScroll);
    }
    if (oldWidget.controller != widget.controller) {
      final alreadyRebound = identical(_boundController, widget.controller);
      if (!alreadyRebound) {
        _clearPageAnchor();
        _pageJumpGeneration++;
        dismissNoOlderScrollback();
        _bindController(widget.controller);
      }
    }
    if (oldWidget.isLoading != widget.isLoading && !widget.isLoading) {
      final hasSavedScroll = _hasValidSavedScroll();
      if (_pendingBottomSnapOnPointerUp || !hasSavedScroll) {
        _pendingBottomSnapOnPointerUp = false;
        _scrollToCursor(requestFocus: false, forceBottom: !hasSavedScroll);
      }
    }
    if (!oldWidget.isExited && widget.isExited) {
      _disarmCtrl();
      _mobileAutoSpace.reset();
      _cancelActiveMouseReport();
      _activePointers.clear();
      _panZoomActive = false;
      _mobileAltScrollPointer = null;
      _mobileAltScrollLastPosition = null;
      _mobileTapPointer = null;
      _mobileTapDownPosition = null;
      _mobileTapDownCell = null;
      _mouseHoverLastCell = null;
      _resizeOutDebounceTimer?.cancel();
      _pendingResizeOutCols = null;
      _pendingResizeOutRows = null;
    }
    if ((oldWidget.isObscured != widget.isObscured && widget.isObscured) ||
        (oldWidget.interactionEnabled && !widget.interactionEnabled)) {
      _cancelActiveMouseReport();
      _activePointers.clear();
      _panZoomActive = false;
      _mobileAltScrollPointer = null;
      _mobileAltScrollLastPosition = null;
      _mobileTapPointer = null;
      _mobileTapDownPosition = null;
      _mobileTapDownCell = null;
      _mobileLongPressAnchor = null;
      _clearLinkTap();
      _hoveredLink = null;
      _lastHoverGlobalPosition = null;
      _mouseHoverLastCell = null;
      _desktopClickCount = 0;
      _lastDesktopClickAt = null;
      _lastDesktopClickPosition = null;
      _endDrag();
      _shiftClickPointer = null;
      _shiftClickDownPosition = null;
    }
    if (sessionSwapped ||
        (oldWidget.isLoading && !widget.isLoading) ||
        (oldWidget.isExited && !widget.isExited)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_sessionDestroyed && !_metricsResizeSettling) {
          _syncTerminalSizeToRender(
            sendResizeOut: !widget.isLoading && !widget.isExited,
          );
        }
      });
      _scheduleHoveredLinkRefresh();
    }
    if (!sessionSwapped &&
        oldWidget.focusCursorRevision != widget.focusCursorRevision) {
      final hasSavedScroll = _hasValidSavedScroll();
      final pos = _scrollController.hasClients
          ? _scrollController.position
          : null;
      final isAtBottom =
          !hasSavedScroll &&
          (pos == null ||
              !pos.hasContentDimensions ||
              pos.maxScrollExtent <= 0 ||
              pos.pixels >= pos.maxScrollExtent - 0.5);
      _scrollToCursor(requestFocus: true, forceBottom: isAtBottom);
    }
    var requestSoftKeyboardShow = false;
    if (oldWidget.softKeyboardEnabled != widget.softKeyboardEnabled &&
        _isMobile) {
      if (widget.softKeyboardEnabled) {
        _focusNode.requestFocus();
        requestSoftKeyboardShow = true;
      } else {
        _focusNode.unfocus();
      }
    }
    _syncFocusReporting();
    _syncImeConnection(showKeyboard: requestSoftKeyboardShow);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyForLinks);
    WidgetsBinding.instance.removeObserver(this);
    _disposeWebPasteListener?.call();
    _disposeWebPasteListener = null;
    _closeImeConnection();
    _focusNode.removeListener(_onFocusChanged);
    final currentOwner = _mountedPanes[widget.terminalId];
    final wasRegisteredOwner = identical(currentOwner, this);
    if (wasRegisteredOwner) {
      _mountedPanes.remove(widget.terminalId);
    }
    if (currentOwner == null || wasRegisteredOwner) {
      widget.onTerminalResizeBind?.call(null);
    }
    if (wasRegisteredOwner && !_sessionDestroyed) {
      _saveScrollOffset();
    }
    _unbindTerminal(_terminal);
    _unbindController();
    cancelNoOlderScrollbackTimer();
    _scrollController.removeListener(_onScrollChanged);
    _scrollController.dispose();
    _focusNode.dispose();
    _metricsSettleTimer?.cancel();
    _resizeOutDebounceTimer?.cancel();
    _scrollToCursorTimer?.cancel();
    _autoScrollTimer?.cancel();
    _clearPointerReleaseTimers();
    if (runningUnderFlutterTest()) {
      _lastWorkspaceFittedSize = null;
    }
    super.dispose();
  }

  // --- Soft-keyboard IME (mobile only) ---

  bool get _shouldAttachSoftKeyboardIme =>
      !terminalHardwareKeyboardOnly(
        isMobile: _isMobile,
        softKeyboardEnabled: widget.softKeyboardEnabled,
      ) &&
      !widget.isExited &&
      _isRouteCurrentAndUnobscured &&
      _focusNode.hasFocus;

  void _onFocusChanged() {
    _syncFocusReporting();
    _syncImeConnection();
  }

  void _syncFocusReporting() {
    final effectiveFocus =
        mounted &&
        !widget.isExited &&
        _isRouteCurrentAndUnobscured &&
        _focusNode.hasFocus;
    if (!_terminal.reportFocus) {
      _lastReportedFocus = effectiveFocus;
      return;
    }
    if (_lastReportedFocus == null) {
      _lastReportedFocus = effectiveFocus;
      return;
    }
    if (_lastReportedFocus == effectiveFocus) return;
    _lastReportedFocus = effectiveFocus;
    if (!widget.isExited) {
      widget.controller.sendInput(effectiveFocus ? '\x1b[I' : '\x1b[O');
    }
  }

  void _syncImeConnection({bool showKeyboard = false}) {
    if (!mounted) return;
    if (_shouldAttachSoftKeyboardIme) {
      var newlyAttached = false;
      if (_textInputConnection == null || !_textInputConnection!.attached) {
        _currentImeValue = const TextEditingValue(
          text: _kImeSentinel,
          selection: TextSelection.collapsed(offset: _kImeSentinel.length),
        );
        _textInputConnection = TextInput.attach(
          this,
          const TextInputConfiguration(
            inputType: TextInputType.text,
            inputAction: TextInputAction.newline,
            autocorrect: false,
            enableSuggestions: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
          ),
        );
        _textInputConnection!.setEditingState(_currentImeValue);
        newlyAttached = true;
      }
      if (newlyAttached || showKeyboard) {
        _textInputConnection!.show();
      }
    } else {
      _closeImeConnection();
    }
  }

  void _closeImeConnection() {
    _currentImeValue = const TextEditingValue(
      text: _kImeSentinel,
      selection: TextSelection.collapsed(offset: _kImeSentinel.length),
    );
    if (_textInputConnection != null) {
      if (_textInputConnection!.attached) {
        _textInputConnection!.close();
      }
      _textInputConnection = null;
    }
  }

  void _resetImeSentinel() {
    _currentImeValue = const TextEditingValue(
      text: _kImeSentinel,
      selection: TextSelection.collapsed(offset: _kImeSentinel.length),
    );
    if (_textInputConnection != null && _textInputConnection!.attached) {
      _textInputConnection!.setEditingState(_currentImeValue);
    }
  }

  void _flushImeComposing() {
    final value = _currentImeValue;
    final text = value.text;
    if (text == _kImeSentinel) {
      if (!value.selection.isCollapsed ||
          value.selection.extentOffset != _kImeSentinel.length) {
        _resetImeSentinel();
      }
      return;
    }
    _resetImeSentinel();
    var common = 0;
    while (common < _kImeSentinel.length &&
        common < text.length &&
        _kImeSentinel.codeUnitAt(common) == text.codeUnitAt(common)) {
      common++;
    }
    final deleted = _kImeSentinel.length - common;
    for (var i = 0; i < deleted; i++) {
      _onTerminalOutput('\x7f');
    }
    final inserted = text.substring(common);
    if (inserted.isNotEmpty) {
      _onTerminalOutput(inserted == '\n' ? '\r' : inserted);
    }
  }

  @override
  TextEditingValue? get currentTextEditingValue => _currentImeValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _currentImeValue = value;
    if (_ctrlArmed && value.text.startsWith(_kImeSentinel)) {
      final pending = value.text.substring(_kImeSentinel.length);
      if (pending.length == 1 && controlByteForChar(pending) != null) {
        _resetImeSentinel();
        _onTerminalOutput(pending);
        return;
      }
    }
    if (value.composing.isValid && !value.composing.isCollapsed) {
      return;
    }
    final text = value.text;
    if (text == _kImeSentinel) {
      if (!value.selection.isCollapsed ||
          value.selection.extentOffset != _kImeSentinel.length) {
        _resetImeSentinel();
      }
      return;
    }
    _resetImeSentinel();
    if (_kImeSentinel.startsWith(text)) {
      final deleted = _kImeSentinel.length - text.length;
      for (var i = 0; i < deleted; i++) {
        _onTerminalOutput('\x7f');
      }
      return;
    }
    if (text.startsWith(_kImeSentinel)) {
      final inserted = text.substring(_kImeSentinel.length);
      if (inserted.isEmpty) return;
      if (inserted == '\n') {
        _onTerminalOutput('\r');
      } else {
        _onTerminalOutput(inserted);
      }
      return;
    }
    // Partial prefix replacement (e.g. autocorrect/backspace+insert in one edit).
    var common = 0;
    while (common < _kImeSentinel.length &&
        common < text.length &&
        _kImeSentinel.codeUnitAt(common) == text.codeUnitAt(common)) {
      common++;
    }
    final deleted = _kImeSentinel.length - common;
    for (var i = 0; i < deleted; i++) {
      _onTerminalOutput('\x7f');
    }
    final inserted = text.substring(common);
    if (inserted.isNotEmpty) {
      _onTerminalOutput(inserted == '\n' ? '\r' : inserted);
    }
  }

  @override
  void performAction(TextInputAction action) {
    switch (action) {
      case TextInputAction.newline:
      case TextInputAction.done:
      case TextInputAction.go:
      case TextInputAction.send:
      case TextInputAction.search:
      case TextInputAction.next:
        _flushImeComposing();
        _onTerminalOutput('\r');
      default:
        break;
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _textInputConnection = null;
    _currentImeValue = const TextEditingValue(
      text: _kImeSentinel,
      selection: TextSelection.collapsed(offset: _kImeSentinel.length),
    );
  }

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void performSelector(String selectorName) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  bool onFocusReceived() => false;

  // --- Controller callbacks ---

  void _onFit() {
    if (!mounted) return;
    final hasSavedScroll = _hasValidSavedScroll();
    final pos = _scrollController.hasClients
        ? _scrollController.position
        : null;
    final isAtBottom =
        !hasSavedScroll &&
        (pos == null ||
            !pos.hasContentDimensions ||
            pos.maxScrollExtent <= 0 ||
            pos.pixels >= pos.maxScrollExtent - 0.5);

    if (isAtBottom) {
      _scrollAnchor.clear();
      _clearSavedSessionScroll(widget.terminalId);
    }
    _syncTerminalSizeToRender(
      sendResizeOut: !widget.isLoading && !widget.isExited,
    );
    setState(() {});
    _scrollToCursor(requestFocus: false, forceBottom: isAtBottom);
  }

  void _onRefit() {
    if (!mounted) return;
    TerminalPane.invalidateCachedResizeOut(widget.terminalId);
    final hasSavedScroll = _hasValidSavedScroll();
    final pos = _scrollController.hasClients
        ? _scrollController.position
        : null;
    final isAtBottom =
        !hasSavedScroll &&
        (pos == null ||
            !pos.hasContentDimensions ||
            pos.maxScrollExtent <= 0 ||
            pos.pixels >= pos.maxScrollExtent - 0.5);

    if (isAtBottom) {
      _scrollAnchor.clear();
      _clearSavedSessionScroll(widget.terminalId);
    }
    _syncTerminalSizeToRender(sendResizeOut: false);
    _resizeOutDebounceTimer?.cancel();
    _pendingResizeOutCols = null;
    _pendingResizeOutRows = null;
    setState(() {});
    _scrollToCursor(requestFocus: false, forceBottom: isAtBottom);
  }

  void _onClear() {
    if (!mounted) return;
    _pageJumpGeneration++;
    _awaitingNearTopFetch = false;
    dismissNoOlderScrollback();
    if (_pageAnchorAt == null) {
      _scrollAnchor.clear();
      _clearSavedSessionScroll(widget.terminalId);
      _pendingBottomSnapOnPointerUp = true;
    }
  }

  void _onHistoryReplayed() {
    if (!mounted) return;
    if (!_metricsResizeSettling) {
      _syncTerminalSizeToRender(sendResizeOut: false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_metricsResizeSettling) {
        _syncTerminalSizeToRender(sendResizeOut: false);
      }
    });
    if (_pageAnchorAt != null &&
        DateTime.now().difference(_pageAnchorAt!) <
            const Duration(seconds: 15) &&
        _pageAnchorPixels != null &&
        _pageAnchorLines != null &&
        _scrollController.hasClients) {
      final anchorPixels = _pageAnchorPixels!;
      final anchorLines = _pageAnchorLines!;
      final savedSelectionBase = _pageSelectionBase;
      final savedSelectionExtent = _pageSelectionExtent;
      _clearPageAnchor();
      _pendingBottomSnapOnPointerUp = false;
      _lastScrollPixels = null;
      final lineCount = _terminal.totalLines;
      final addedLines = lineCount - anchorLines;
      if (addedLines >= 0 && lineCount > 0) {
        if (_selectionAnchor != null &&
            _selectionAnchor!.resolveIn(_terminal) != null) {
          _selectionAnchor = _selectionAnchor!.shiftedForHistoryPage(
            addedLines: addedLines,
            lineCount: lineCount,
          );
        }
        if (_dragAnchorCell != null &&
            _dragAnchorCell!.resolveIn(_terminal) != null) {
          _dragAnchorCell = _dragAnchorCell!.shiftedForHistoryPage(
            addedLines: addedLines,
            lineCount: lineCount,
          );
        }
        if (savedSelectionBase != null && savedSelectionExtent != null) {
          final shiftedBase = shiftCellOffsetForHistoryPage(
            offset: savedSelectionBase,
            addedLines: addedLines,
            lineCount: lineCount,
          );
          final shiftedExtent = shiftCellOffsetForHistoryPage(
            offset: savedSelectionExtent,
            addedLines: addedLines,
            lineCount: lineCount,
          );
          if (shiftedBase != null && shiftedExtent != null) {
            _setSelection(
              TerminalSelectionRange(
                shiftedBase,
                shiftedExtent,
                trimmedTopRows: _terminal.trimmedTopRows,
                eraseScrollbackGen: _terminal.eraseScrollbackGen,
                reflowGen: _terminal.reflowGen,
                isAltScreen: _terminal.isUsingAltBuffer,
              ),
              preserveAnchor: true,
            );
          }
        }
      }
      final initialLh = _lineHeight() ?? 18.0;
      final wasNearTop = _scrollController.position.pixels <= initialLh * 5;
      final jumpGeneration = ++_pageJumpGeneration;
      void applyPagedJump() {
        if (!mounted ||
            _sessionDestroyed ||
            jumpGeneration != _pageJumpGeneration ||
            !_scrollController.hasClients) {
          return;
        }
        final position = _scrollController.position;
        if (!position.hasContentDimensions) return;
        final lh = _lineHeight() ?? 18.0;
        final maxExtent = _effectiveMaxScrollExtent(position);
        final target = (anchorPixels + addedLines * lh).clamp(0.0, maxExtent);
        final atBottom = target >= maxExtent - 0.5;
        _jumpPositionTo(position, target, stickToBottom: atBottom);
        _scrollAnchor.capture(
          buffer: _terminal,
          pixels: position.pixels,
          maxScrollExtent: maxExtent,
          lineHeight: lh,
        );
        _saveScrollOffset(widget.terminalId, lh, maxExtent);
        if (_dragSelecting) {
          _scheduleDragExtend();
        }
      }

      applyPagedJump();
      WidgetsBinding.instance.addPostFrameCallback((_) => applyPagedJump());
      if (shouldContinuePastBarrenPage(
        addedLines: addedLines,
        nearTop: wasNearTop,
      )) {
        _continuePastBarrenPage();
      } else if (addedLines > 0) {
        dismissNoOlderScrollback();
      }
      return;
    }
    _clearPageAnchor();
    _pageJumpGeneration++;
    dismissNoOlderScrollback();
    final hasSavedScroll = _hasValidSavedScroll();
    final isGestureActive =
        _hasActivePointerOrPanZoom ||
        (_scrollController.hasClients &&
            _scrollController.position.isScrollingNotifier.value &&
            _scrollController.position.userScrollDirection !=
                ScrollDirection.idle);
    if (isGestureActive) {
      _pendingBottomSnapOnPointerUp = !hasSavedScroll;
    } else {
      _pendingBottomSnapOnPointerUp = false;
      if (!hasSavedScroll &&
          _scrollController.hasClients &&
          _scrollController.position.hasContentDimensions) {
        _snapToBottom(_scrollController.position);
      }
      _scrollToCursor(requestFocus: false, forceBottom: !hasSavedScroll);
    }
  }

  void _onHistoryPageStarted() {
    if (!mounted || !_scrollController.hasClients) return;
    _pageAnchorPixels = _scrollController.position.pixels;
    _pageAnchorLines = _terminal.totalLines;
    _pageAnchorAt = DateTime.now();
    final selection = _selection;
    if (selection != null && terminalSelectionIsLive(_terminal, selection)) {
      final (begin, end) = selection.normalizedIn(_terminal);
      _pageSelectionBase = begin;
      _pageSelectionExtent = end;
    } else {
      _pageSelectionBase = null;
      _pageSelectionExtent = null;
    }
  }

  void _continuePastBarrenPage() {
    final terminalId = widget.terminalId;
    final terminal = widget.terminal;
    final controller = widget.controller;
    final jumpGeneration = _pageJumpGeneration;
    scheduleMicrotask(() {
      if (!mounted ||
          widget.terminalId != terminalId ||
          !identical(widget.terminal, terminal) ||
          !identical(widget.controller, controller) ||
          jumpGeneration != _pageJumpGeneration) {
        return;
      }
      if (widget.onNearTop?.call() == false) {
        noteHistoryExhausted();
      }
    });
  }

  // --- Selection ---

  void _setSelection(
    TerminalSelectionRange? next, {
    bool preserveAnchor = false,
  }) {
    if (next == _selection) return;
    _selection = next;
    if (!preserveAnchor && next != null && !_dragSelecting) {
      final (begin, _) = next.normalizedIn(_terminal);
      _selectionAnchor = _anchorAt(begin);
    }
    _syncCopyTarget();
    _gridViewKey.currentState?.renderGrid?.selection = _selection;
    if (mounted &&
        SchedulerBinding.instance.schedulerPhase !=
            SchedulerPhase.persistentCallbacks) {
      setState(() {});
    } else if (mounted) {
      _rebuildForCopyButton();
    }
  }

  void _clearSelection() {
    if (_selection == null) return;
    _setSelection(null, preserveAnchor: true);
  }

  void _extendSelectionTo(CellOffset target) {
    final anchor = _selectionAnchor?.resolveIn(_terminal);
    if (anchor == null) return;
    _applySelection(anchor, target);
  }

  TerminalSelectionRange? _selectLineRangeAt(CellOffset cell) {
    final total = _terminal.totalLines;
    final cols = _terminal.viewWidth;
    if (total <= 0 || cols <= 0) return null;
    final row = cell.y.clamp(0, total - 1);
    final rowCols = max(cols, _terminal.lineAtVirtualRow(row)?.length ?? 0);
    return TerminalSelectionRange(
      CellOffset(0, row),
      CellOffset(rowCols, row),
      trimmedTopRows: _terminal.trimmedTopRows,
      eraseScrollbackGen: _terminal.eraseScrollbackGen,
      reflowGen: _terminal.reflowGen,
      isAltScreen: _terminal.isUsingAltBuffer,
    );
  }

  void _applySelection(CellOffset anchorCell, CellOffset targetCell) {
    final total = _terminal.totalLines;
    final maxRow = max(0, total - 1);
    final anchorCols = total > 0
        ? (_terminal.lineAtVirtualRow(anchorCell.y.clamp(0, maxRow))?.length ??
              0)
        : 0;
    final targetCols = total > 0
        ? (_terminal.lineAtVirtualRow(targetCell.y.clamp(0, maxRow))?.length ??
              0)
        : 0;
    final effectiveWidth = max(
      _terminal.viewWidth,
      max(anchorCols, targetCols),
    );
    final endpoints = resolveSelectionEndpoints(
      anchorCell: anchorCell,
      targetCell: targetCell,
      viewWidth: effectiveWidth,
      lineCount: total,
      buffer: _terminal,
    );
    if (endpoints == null) return;
    final (base, extent) = endpoints;
    _setSelection(
      TerminalSelectionRange(
        base,
        extent,
        trimmedTopRows: _terminal.trimmedTopRows,
        eraseScrollbackGen: _terminal.eraseScrollbackGen,
        reflowGen: _terminal.reflowGen,
        isAltScreen: _terminal.isUsingAltBuffer,
      ),
      preserveAnchor: true,
    );
  }

  int _lastWrittenVirtualRow() {
    for (var row = _terminal.totalLines - 1; row >= 0; row--) {
      final line = _terminal.lineAtVirtualRow(row);
      if (line == null || line.storedCols > 0) {
        return row;
      }
    }
    return -1;
  }

  RenderTerminalGrid? get _renderGrid => _gridViewKey.currentState?.renderGrid;

  CellOffset? _cellAtGlobal(Offset globalPosition) {
    final render = _renderGrid;
    if (render == null || !render.attached || !render.hasSize) return null;
    try {
      return render.getCellOffset(render.globalToLocal(globalPosition));
    } catch (_) {
      return null;
    }
  }

  TerminalLink? _linkAtGlobal(Offset globalPosition) {
    final render = _renderGrid;
    if (render == null || !render.attached || !render.hasSize) return null;
    try {
      return render.linkAtOffset(render.globalToLocal(globalPosition));
    } catch (_) {
      return null;
    }
  }

  bool get _isLinkModifierPressed {
    final kb = HardwareKeyboard.instance;
    return kb.isControlPressed || kb.isMetaPressed;
  }

  bool get _linksInteractiveNow =>
      !widget.isObscured &&
      !widget.isLoading &&
      widget.interactionEnabled &&
      (_terminal.mouseMode == 0 || _isLinkModifierPressed);

  MouseCursor get _terminalMouseCursor {
    if (_hoveredLink != null) return SystemMouseCursors.click;
    if (_terminal.mouseMode > 0 && !_isLinkModifierPressed) {
      return SystemMouseCursors.basic;
    }
    return SystemMouseCursors.text;
  }

  void _setHoveredLink(TerminalLink? next) {
    if (_hoveredLink == next || !mounted) return;
    setState(() {
      _hoveredLink = next;
    });
    _renderGrid?.hoveredLink = next;
  }

  void _updateHoveredLinkAt(Offset? globalPosition) {
    if (_isMobile || globalPosition == null || !_linksInteractiveNow) {
      _setHoveredLink(null);
      return;
    }
    if (ModalRoute.of(context)?.isCurrent == false) {
      _setHoveredLink(null);
      return;
    }
    _setHoveredLink(_linkAtGlobal(globalPosition));
  }

  void _scheduleHoveredLinkRefresh() {
    if (_isMobile ||
        _lastHoverGlobalPosition == null ||
        _linkRefreshScheduled) {
      return;
    }
    _linkRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _linkRefreshScheduled = false;
      if (!mounted) return;
      _updateHoveredLinkAt(_lastHoverGlobalPosition);
    });
  }

  bool _handleHardwareKeyForLinks(KeyEvent event) {
    if (!mounted || _isMobile || _lastHoverGlobalPosition == null) {
      return false;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight) {
      _updateHoveredLinkAt(_lastHoverGlobalPosition);
    }
    return false;
  }

  void _handleMouseHover(PointerHoverEvent event) {
    _lastHoverGlobalPosition = event.position;
    _updateHoveredLinkAt(event.position);
  }

  void _handleMouseExit(PointerExitEvent _) {
    _lastHoverGlobalPosition = null;
    _setHoveredLink(null);
  }

  void _clearLinkTap() {
    _linkTapPointer = null;
    _linkTapDownPosition = null;
    _linkTapCandidate = null;
  }

  void _launchTerminalLink(TerminalLink link) {
    final handler = widget.onOpenUrl ?? openExternalUri;
    unawaited(
      Future<void>.sync(() => handler(link.uri)).catchError((
        Object error,
        StackTrace stack,
      ) {
        tdbg('link', 'openExternalUri failed for ${link.uri}: $error');
      }),
    );
  }

  CellOffset? _viewportCellAtGlobal(Offset globalPosition) {
    final render = _renderGrid;
    if (render != null && render.attached && render.hasSize) {
      try {
        return render.getViewportCellOffset(
          render.globalToLocal(globalPosition),
        );
      } catch (_) {}
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(globalPosition);
    const cellW = 9.0;
    const cellH = 18.0;
    final maxCol = max(0, _terminal.viewWidth - 1);
    final maxRow = max(0, _terminal.viewHeight - 1);
    final col = (local.dx / cellW).floor().clamp(0, maxCol);
    final row = (local.dy / cellH).floor().clamp(0, maxRow);
    return CellOffset(col, row);
  }

  // --- Pointer, mouse reporting, and touch gestures ---

  void _emitMouseEvent({
    required TerminalMouseButton button,
    required CellOffset cell,
    required bool pressed,
    bool motion = false,
  }) {
    final kb = HardwareKeyboard.instance;
    final seq = encodeTerminalMouseEvent(
      mouseMode: _terminal.mouseMode,
      mouseReportMode: _terminal.mouseReportMode,
      button: button,
      col: cell.x,
      row: cell.y,
      pressed: pressed,
      motion: motion,
      shift: kb.isShiftPressed,
      alt: kb.isAltPressed,
      ctrl: kb.isControlPressed,
    );
    if (seq != null) {
      _onTerminalOutput(seq);
    }
  }

  TerminalMouseButton? _mouseButtonFromFlags(int buttons) {
    if ((buttons & kPrimaryButton) != 0) return TerminalMouseButton.left;
    if ((buttons & kMiddleMouseButton) != 0) return TerminalMouseButton.middle;
    if ((buttons & kSecondaryMouseButton) != 0) {
      return TerminalMouseButton.right;
    }
    return null;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (widget.isObscured || !widget.interactionEnabled) return;
    _mobileAutoSpace.reset();
    _activePointers.add(event.pointer);
    final hadNonCollapsedSelection =
        _selection != null && !_selection!.isCollapsed;
    if (!_isMobile) {
      _focusTerminal();
    } else if (_isRouteCurrentAndUnobscured) {
      if (_activePointers.length == 1 && _shouldForwardWheelToTerminal) {
        _mobileAltScrollPointer = event.pointer;
        _mobileAltScrollLastPosition = event.position;
        _altScrollDeltaAccum = 0.0;
      } else {
        _mobileAltScrollPointer = null;
        _mobileAltScrollLastPosition = null;
      }
      if (_activePointers.length == 1 &&
          (event.buttons & kPrimaryButton) != 0 &&
          !widget.isExited &&
          _terminal.mouseMode > 0) {
        _mobileTapPointer = event.pointer;
        _mobileTapDownPosition = event.position;
        _mobileTapDownCell = _viewportCellAtGlobal(event.position);
      } else {
        _mobileTapPointer = null;
        _mobileTapDownPosition = null;
        _mobileTapDownCell = null;
      }
      if (_activePointers.length == 1 &&
          (event.buttons & kPrimaryButton) != 0 &&
          _terminal.mouseMode == 0 &&
          !hadNonCollapsedSelection) {
        final link = _linkAtGlobal(event.position);
        if (link != null) {
          _linkTapPointer = event.pointer;
          _linkTapDownPosition = event.position;
          _linkTapCandidate = link;
        } else {
          _clearLinkTap();
        }
      } else {
        _clearLinkTap();
      }
    }
    if (_isMobile || !_isRouteCurrentAndUnobscured) {
      return;
    }
    final mouseButton = _mouseButtonFromFlags(event.buttons);
    final kb = HardwareKeyboard.instance;
    final bypassMouseModeLink =
        !widget.isExited &&
            _terminal.mouseMode > 0 &&
            _isLinkModifierPressed &&
            !kb.isShiftPressed &&
            !kb.isAltPressed &&
            !hadNonCollapsedSelection &&
            (event.buttons & kPrimaryButton) != 0
        ? _linkAtGlobal(event.position)
        : null;
    if (!kb.isShiftPressed &&
        !widget.isExited &&
        _terminal.mouseMode > 0 &&
        mouseButton != null &&
        bypassMouseModeLink == null) {
      _clearLinkTap();
      final cell = _viewportCellAtGlobal(event.position);
      if (cell == null) return;
      _mouseReportPointer = event.pointer;
      _mouseReportButton = mouseButton;
      _mouseReportLastCell = cell;
      widget.controller.notifyInteraction();
      _emitMouseEvent(button: mouseButton, cell: cell, pressed: true);
      return;
    }
    if ((event.buttons & kPrimaryButton) == 0) return;
    if (kb.isShiftPressed) {
      _clearLinkTap();
      _shiftClickPointer = event.pointer;
      _shiftClickDownPosition = event.position;
    } else {
      final link =
          bypassMouseModeLink ??
          ((!hadNonCollapsedSelection &&
                  !kb.isAltPressed &&
                  _terminal.mouseMode == 0)
              ? _linkAtGlobal(event.position)
              : null);
      if (link != null) {
        _linkTapPointer = event.pointer;
        _linkTapDownPosition = event.position;
        _linkTapCandidate = link;
      } else {
        _clearLinkTap();
      }
      if (_terminal.mouseMode == 0 || widget.isExited) {
        final anchor = _cellAtGlobal(event.position);
        if (anchor == null) return;
        _dragPointer = event.pointer;
        _dragDownPosition = event.position;
        _dragLastPosition = event.position;
        _dragAnchorCell = _anchorAt(anchor);
        _dragSelecting = false;
      }
    }
  }

  void _cancelActiveMouseReport([Offset? position]) {
    if (_mouseReportPointer == null) return;
    final lastCell = _mouseReportLastCell;
    final button = _mouseReportButton;
    _mouseReportPointer = null;
    _mouseReportButton = TerminalMouseButton.left;
    _mouseReportLastCell = null;
    if (!widget.isExited &&
        _terminal.mouseMode > 0 &&
        _terminal.mouseMode != kMouseModeX10) {
      final cell =
          (position != null ? _viewportCellAtGlobal(position) : null) ??
          lastCell ??
          const CellOffset(0, 0);
      _emitMouseEvent(button: button, cell: cell, pressed: false);
    }
  }

  void _handlePointerHover(PointerHoverEvent event) {
    if (_isMobile ||
        widget.isExited ||
        !_isRouteCurrentAndUnobscured ||
        _terminal.mouseMode < kMouseModeAnyEvent) {
      return;
    }
    final cell = _viewportCellAtGlobal(event.position);
    if (cell == null || cell == _mouseHoverLastCell) return;
    _mouseHoverLastCell = cell;
    _emitMouseEvent(
      button: TerminalMouseButton.left,
      cell: cell,
      pressed: false,
      motion: true,
    );
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer == _linkTapPointer) {
      final downPos = _linkTapDownPosition;
      final slop = _isMobile ? kTouchSlop : _clickMoveSlop;
      if (_activePointers.length != 1 ||
          downPos == null ||
          (event.position - downPos).distance > slop) {
        _clearLinkTap();
      }
    }
    if (event.pointer == _mobileTapPointer) {
      final downPos = _mobileTapDownPosition;
      if (_activePointers.length != 1 ||
          downPos == null ||
          (event.position - downPos).distance > kTouchSlop) {
        _mobileTapPointer = null;
        _mobileTapDownPosition = null;
        _mobileTapDownCell = null;
      }
    }
    if (event.pointer == _mobileAltScrollPointer) {
      if (_activePointers.length != 1 || !_shouldForwardWheelToTerminal) {
        _mobileAltScrollPointer = null;
        _mobileAltScrollLastPosition = null;
        return;
      }
      final lastPos = _mobileAltScrollLastPosition;
      _mobileAltScrollLastPosition = event.position;
      if (lastPos != null) {
        _emitAltScrollDelta(lastPos.dy - event.position.dy, event.position);
      }
      return;
    }
    if (event.pointer == _mouseReportPointer) {
      if (widget.isExited || _terminal.mouseMode <= 0) {
        _mouseReportPointer = null;
        _mouseReportButton = TerminalMouseButton.left;
        _mouseReportLastCell = null;
        return;
      }
      if (_terminal.mouseMode < 3) {
        return;
      }
      final cell = _viewportCellAtGlobal(event.position);
      if (cell == null || cell == _mouseReportLastCell) return;
      _mouseReportLastCell = cell;
      _emitMouseEvent(
        button: _mouseReportButton,
        cell: cell,
        pressed: true,
        motion: true,
      );
      return;
    }
    if (event.pointer != _dragPointer) return;
    _dragLastPosition = event.position;
    if (!_dragSelecting) {
      final down = _dragDownPosition;
      if (down == null) return;
      if ((event.position - down).distance <= _clickMoveSlop) return;
      _dragSelecting = true;
    }
    _updateAutoScroll(event.position);
    _scheduleDragExtend();
  }

  void _clearPointerReleaseTimers() {
    for (final timer in _pointerReleaseTimers) {
      timer.cancel();
    }
    _pointerReleaseTimers.clear();
  }

  void _checkDeferredBottomSnapOnPointerRelease() {
    if (!_hasActivePointerOrPanZoom && _pendingBottomSnapOnPointerUp) {
      _pendingBottomSnapOnPointerUp = false;
      _scrollToCursor(requestFocus: false, forceBottom: true);
      _clearPointerReleaseTimers();
      for (final ms in const [80, 250]) {
        _pointerReleaseTimers.add(
          Timer(Duration(milliseconds: ms), () {
            if (mounted &&
                !_sessionDestroyed &&
                !_hasActivePointerOrPanZoom &&
                !_hasValidSavedScroll()) {
              _scrollToCursor(requestFocus: false, forceBottom: true);
            }
          }),
        );
      }
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer == _mobileAltScrollPointer) {
      _mobileAltScrollPointer = null;
      _mobileAltScrollLastPosition = null;
      _altScrollDeltaAccum = 0.0;
    }
    if (event.pointer == _mobileTapPointer) {
      final downPos = _mobileTapDownPosition;
      final downCell = _mobileTapDownCell;
      _mobileTapPointer = null;
      _mobileTapDownPosition = null;
      _mobileTapDownCell = null;
      if (downPos != null &&
          (event.position - downPos).distance <= kTouchSlop &&
          !widget.isExited &&
          _terminal.mouseMode > 0) {
        final cell =
            downCell ??
            _viewportCellAtGlobal(event.position) ??
            _viewportCellAtGlobal(downPos);
        if (cell != null) {
          widget.controller.notifyInteraction();
          _emitMouseEvent(
            button: TerminalMouseButton.left,
            cell: cell,
            pressed: true,
          );
          _emitMouseEvent(
            button: TerminalMouseButton.left,
            cell: cell,
            pressed: false,
          );
        }
      }
    }
    if (event.pointer == _mouseReportPointer) {
      _cancelActiveMouseReport(event.position);
    }
    var dragMovedBeyondSlop = false;
    if (event.pointer == _dragPointer) {
      final wasDragSelecting = _dragSelecting;
      dragMovedBeyondSlop = wasDragSelecting;
      final downPos = _dragDownPosition;
      final anchor = _dragAnchorCell;
      final endPosition = event.position;
      _endDrag();
      if (wasDragSelecting && anchor != null) {
        _desktopClickCount = 0;
        _lastDesktopClickAt = null;
        _lastDesktopClickPosition = null;
        _applyDragSelectionAt(anchor, endPosition);
      } else if (!wasDragSelecting &&
          downPos != null &&
          (endPosition - downPos).distance <= _clickMoveSlop &&
          !HardwareKeyboard.instance.isShiftPressed) {
        final now = DateTime.now();
        final prevAt = _lastDesktopClickAt;
        final prevPos = _lastDesktopClickPosition;
        if (prevAt != null &&
            prevPos != null &&
            now.difference(prevAt) <= _multiClickWindow &&
            (endPosition - prevPos).distance <= _clickMoveSlop * 2) {
          _desktopClickCount = (_desktopClickCount % 3) + 1;
        } else {
          _desktopClickCount = 1;
        }
        _lastDesktopClickAt = now;
        _lastDesktopClickPosition = endPosition;
        final clickCell =
            _cellAtGlobal(endPosition) ?? anchor?.resolveIn(_terminal);
        if (_desktopClickCount == 2 && clickCell != null) {
          final wordRange = selectWordRangeAt(_terminal, clickCell);
          if (wordRange != null) {
            _setSelection(wordRange);
          } else {
            _clearSelection();
          }
        } else if (_desktopClickCount == 3 && clickCell != null) {
          final lineRange = _selectLineRangeAt(clickCell);
          if (lineRange != null) {
            _setSelection(lineRange);
          } else {
            _clearSelection();
          }
        } else {
          _clearSelection();
        }
      }
    }
    if (event.pointer == _linkTapPointer) {
      final downPos = _linkTapDownPosition;
      final candidate = _linkTapCandidate;
      _clearLinkTap();
      final slop = _isMobile ? kTouchSlop : _clickMoveSlop;
      if (!dragMovedBeyondSlop &&
          downPos != null &&
          candidate != null &&
          (event.position - downPos).distance <= slop) {
        final currentLink = _linkAtGlobal(event.position);
        if (currentLink == null || currentLink.url == candidate.url) {
          _launchTerminalLink(candidate);
        }
      }
    }
    _checkDeferredBottomSnapOnPointerRelease();
    if (!_hasActivePointerOrPanZoom && _scrollAnchor.hasAnchor) {
      _repinScrollAnchor();
    }
    if (event.pointer != _shiftClickPointer) return;
    final downPosition = _shiftClickDownPosition;
    _shiftClickPointer = null;
    _shiftClickDownPosition = null;
    if (downPosition == null) return;
    if ((event.position - downPosition).distance > _clickMoveSlop) return;
    final target = _cellAtGlobal(event.position);
    if (target == null) return;
    _extendSelectionTo(target);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer == _mobileAltScrollPointer) {
      _mobileAltScrollPointer = null;
      _mobileAltScrollLastPosition = null;
      _altScrollDeltaAccum = 0.0;
    }
    if (event.pointer == _mobileTapPointer) {
      _mobileTapPointer = null;
      _mobileTapDownPosition = null;
      _mobileTapDownCell = null;
    }
    if (event.pointer == _linkTapPointer) {
      _clearLinkTap();
    }
    if (event.pointer == _mouseReportPointer) {
      _cancelActiveMouseReport(event.position);
    }
    if (event.pointer == _dragPointer) {
      _endDrag();
    }
    _checkDeferredBottomSnapOnPointerRelease();
    if (!_hasActivePointerOrPanZoom && _scrollAnchor.hasAnchor) {
      _repinScrollAnchor();
    }
    if (event.pointer == _shiftClickPointer) {
      _shiftClickPointer = null;
      _shiftClickDownPosition = null;
    }
  }

  bool get _shouldForwardWheelToTerminal {
    if (widget.isExited) return false;
    if (_terminal.isUsingAltBuffer) return true;
    if (_terminal.mouseMode < kMouseModeNormal) return false;
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return !pos.hasContentDimensions || pos.maxScrollExtent <= 0;
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (widget.isLoading || widget.isObscured || !widget.interactionEnabled) {
      return;
    }
    if (event is PointerScrollEvent && _shouldForwardWheelToTerminal) {
      GestureBinding.instance.pointerSignalResolver.register(event, (
        PointerSignalEvent resolved,
      ) {
        if (!mounted || resolved is! PointerScrollEvent) return;
        _emitAltScrollDelta(resolved.scrollDelta.dy, resolved.position);
      });
    }
  }

  void _handlePointerPanZoomStart(PointerPanZoomStartEvent event) {
    if (widget.isLoading || widget.isObscured || !widget.interactionEnabled) {
      return;
    }
    _panZoomActive = true;
    _altScrollDeltaAccum = 0.0;
  }

  void _handlePointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (widget.isLoading || widget.isObscured || !widget.interactionEnabled) {
      return;
    }
    if (_shouldForwardWheelToTerminal) {
      _emitAltScrollDelta(-event.panDelta.dy, event.position);
    }
  }

  void _handlePointerPanZoomEnd(PointerPanZoomEndEvent event) {
    _panZoomActive = false;
    _altScrollDeltaAccum = 0.0;
    _checkDeferredBottomSnapOnPointerRelease();
    if (!_hasActivePointerOrPanZoom && _scrollAnchor.hasAnchor) {
      _repinScrollAnchor();
    }
  }

  void _emitAltScrollDelta(double scrollDeltaDy, Offset globalPosition) {
    if (!mounted ||
        widget.isLoading ||
        widget.isExited ||
        !_isRouteCurrentAndUnobscured) {
      return;
    }
    if (scrollDeltaDy == 0.0) return;
    if ((_altScrollDeltaAccum < 0 && scrollDeltaDy > 0) ||
        (_altScrollDeltaAccum > 0 && scrollDeltaDy < 0)) {
      _altScrollDeltaAccum = 0.0;
    }
    _altScrollDeltaAccum += scrollDeltaDy;
    final lh = (_lineHeight() ?? 18.0).clamp(4.0, 200.0);
    final steps = (_altScrollDeltaAccum / lh).truncate();
    if (steps == 0) return;
    _altScrollDeltaAccum -= steps * lh;
    _mobileTapPointer = null;
    _mobileTapDownPosition = null;
    _mobileTapDownCell = null;

    final cell =
        _viewportCellAtGlobal(globalPosition) ?? const CellOffset(0, 0);
    final up = steps < 0;
    final count = steps.abs().clamp(1, 10);
    widget.controller.notifyInteraction();
    for (var i = 0; i < count; i++) {
      _sendWheelStep(up, cell);
    }
  }

  void _sendWheelStep(bool up, CellOffset cell) {
    if (!mounted || widget.isExited || !_isRouteCurrentAndUnobscured) return;
    if (_terminal.mouseMode >= kMouseModeNormal) {
      final kb = HardwareKeyboard.instance;
      final seq = encodeTerminalMouseEvent(
        mouseMode: _terminal.mouseMode,
        mouseReportMode: _terminal.mouseReportMode,
        button: up
            ? TerminalMouseButton.wheelUp
            : TerminalMouseButton.wheelDown,
        col: cell.x,
        row: cell.y,
        pressed: true,
        shift: kb.isShiftPressed,
        alt: kb.isAltPressed,
        ctrl: kb.isControlPressed,
      );
      if (seq != null) {
        widget.controller.sendInput(seq);
      }
      return;
    }
    if (!_terminal.isUsingAltBuffer) return;
    final fallback = encodeAltScreenFallbackWheel(
      up: up,
      appCursorKeys: _terminal.appCursorKeys,
      isUsingAltBuffer: _terminal.isUsingAltBuffer,
      steps: 1,
    );
    if (fallback.isNotEmpty) {
      widget.controller.sendInput(fallback);
    }
  }

  void _handleMobileLongPressStart(LongPressStartDetails details) {
    _clearLinkTap();
    if (!_isMobile ||
        widget.isObscured ||
        !widget.interactionEnabled ||
        _terminal.mouseMode > 0) {
      return;
    }
    final cell = _cellAtGlobal(details.globalPosition);
    if (cell == null) return;
    final wordRange = selectWordRangeAt(_terminal, cell);
    if (wordRange == null) return;
    _mobileLongPressAnchor = _anchorAt(wordRange.normalizedIn(_terminal).$1);
    _setSelection(wordRange);
  }

  void _handleMobileLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final anchor = _mobileLongPressAnchor?.resolveIn(_terminal);
    if (anchor == null || !_isMobile) return;
    final target = _cellAtGlobal(details.globalPosition);
    if (target == null) return;
    _applySelection(anchor, target);
  }

  void _handleMobileLongPressEnd(LongPressEndDetails _) {
    _mobileLongPressAnchor = null;
  }

  void _endDrag() {
    _stopAutoScroll();
    _lastScrollPixels =
        _scrollController.hasClients &&
            _scrollController.position.hasContentDimensions
        ? _scrollController.position.pixels
        : null;
    _dragPointer = null;
    _dragDownPosition = null;
    _dragLastPosition = null;
    _dragAnchorCell = null;
    _dragSelecting = false;
  }

  void _scheduleDragExtend() {
    if (_dragExtendScheduled) return;
    _dragExtendScheduled = true;
    scheduleMicrotask(() {
      _dragExtendScheduled = false;
      _applyDragExtend();
    });
  }

  void _applyDragExtend() {
    if (!mounted || !_dragSelecting) return;
    final anchor = _dragAnchorCell;
    final position = _dragLastPosition;
    if (anchor == null || position == null) return;
    _applyDragSelectionAt(anchor, position);
  }

  void _applyDragSelectionAt(_AnchoredCell anchor, Offset globalPosition) {
    final resolvedAnchor = anchor.resolveIn(_terminal);
    if (resolvedAnchor == null) {
      _endDrag();
      _clearSelection();
      return;
    }
    final target = _cellAtGlobal(globalPosition);
    if (target == null) return;
    _applySelection(resolvedAnchor, target);
    _selectionAnchor = anchor;
  }

  void _updateAutoScroll(Offset globalPosition) {
    final render = _renderGrid;
    double velocity = 0;
    if (render != null && render.attached && render.hasSize) {
      try {
        final localY = render.globalToLocal(globalPosition).dy;
        final height = render.size.height;
        if (localY < _autoScrollEdge) {
          final depth = ((_autoScrollEdge - localY) / _autoScrollEdge).clamp(
            0.0,
            1.0,
          );
          velocity = -depth * _autoScrollMaxStep;
        } else if (localY > height - _autoScrollEdge) {
          final depth =
              ((localY - (height - _autoScrollEdge)) / _autoScrollEdge).clamp(
                0.0,
                1.0,
              );
          velocity = depth * _autoScrollMaxStep;
        }
      } catch (_) {
        velocity = 0;
      }
    }
    _autoScrollVelocity = velocity;
    if (velocity == 0) {
      _stopAutoScroll();
    } else {
      _autoScrollTimer ??= Timer.periodic(_autoScrollTick, _onAutoScrollTick);
    }
  }

  void _onAutoScrollTick(Timer _) {
    if (!mounted || !_dragSelecting || _autoScrollVelocity == 0) {
      _stopAutoScroll();
      return;
    }
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = (position.pixels + _autoScrollVelocity).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if (target != position.pixels) {
      position.jumpTo(target);
    }
    _applyDragExtend();
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollVelocity = 0;
  }

  // --- Terminal output & accessory bar ---

  void _onTerminalOutput(String data, {bool fromHardwareKey = false}) {
    if (isEmulatorQueryResponse(data, fromHardwareKey: fromHardwareKey)) {
      return;
    }
    if (!mounted || widget.isExited || !_isRouteCurrentAndUnobscured) {
      return;
    }

    if (isTerminalMouseReport(data)) {
      widget.controller.sendInput(data);
      return;
    }

    _clearSavedSessionScroll(widget.terminalId);
    _scrollAnchor.clear();
    if (_scrollController.hasClients) {
      _snapToBottom(_scrollController.position);
    }
    if (_ctrlArmed) {
      _mobileAutoSpace.reset();
      final ctrl = data.length == 1 ? controlByteForChar(data) : null;
      _disarmCtrl();
      if (ctrl != null) {
        widget.controller.sendInput(ctrl, fromHardwareKey: fromHardwareKey);
        return;
      }
    }
    final firstUnit = data.isNotEmpty ? data.codeUnitAt(0) : 0;
    final isControlOrEscape = firstUnit < 0x20 || firstUnit == 0x7f;
    if (!fromHardwareKey &&
        !isControlOrEscape &&
        data.length > 1 &&
        isMultiLine(data) &&
        data != '\r\n') {
      _mobileAutoSpace.reset();
      unawaited(_handlePaste(data));
      return;
    }
    if (fromHardwareKey || isControlOrEscape) {
      _mobileAutoSpace.reset();
      widget.controller.sendInput(data, fromHardwareKey: fromHardwareKey);
      return;
    }
    final effectiveData = _isMobile
        ? _mobileAutoSpace.processInput(data)
        : data;
    widget.controller.sendInput(
      effectiveData,
      fromHardwareKey: fromHardwareKey,
    );
  }

  void _armCtrl() {
    if (_ctrlArmed) return;
    setState(() => _ctrlArmed = true);
  }

  void _disarmCtrl() {
    if (!_ctrlArmed) return;
    if (mounted) {
      setState(() => _ctrlArmed = false);
    } else {
      _ctrlArmed = false;
    }
  }

  void _sendAccessory(String bytes) {
    if (!mounted || widget.isExited || !_isRouteCurrentAndUnobscured) return;
    _flushImeComposing();
    _clearSavedSessionScroll(widget.terminalId);
    _scrollAnchor.clear();
    if (_scrollController.hasClients) {
      _snapToBottom(_scrollController.position);
    }
    widget.controller.sendInput(bytes);
    _disarmCtrl();
    _mobileAutoSpace.reset();
  }

  void _toggleCtrl() {
    if (!mounted || widget.isExited || !_isRouteCurrentAndUnobscured) return;
    _flushImeComposing();
    if (_ctrlArmed) {
      _disarmCtrl();
    } else {
      _armCtrl();
    }
  }

  void _focusTerminal() {
    if (widget.isLoading || !_isRouteCurrentAndUnobscured) {
      return;
    }
    if (_isMobile && _selection != null) {
      _clearSelection();
    }
    if (widget.isExited) {
      _requestTerminalFocus();
      return;
    }
    widget.controller.notifyInteraction();
    _requestTerminalFocus();
    _syncImeConnection(showKeyboard: true);
  }

  bool get _isRouteCurrentAndUnobscured {
    if (!mounted ||
        !_isActive ||
        widget.isObscured ||
        !widget.interactionEnabled) {
      return false;
    }
    return _modalRoute?.isCurrent ?? _routeIsCurrent;
  }

  bool get _mayTakeFocus =>
      (!_isMobile || widget.softKeyboardEnabled) &&
      _isRouteCurrentAndUnobscured;

  void _requestTerminalFocus() {
    if (_mayTakeFocus) _focusNode.requestFocus();
  }

  // --- Grid sizing & resize debounce ---

  void _handleGridMetricsChanged(
    int cols,
    int rows,
    double cellWidth,
    double cellHeight,
  ) {
    final nextCols = cols.clamp(1, kMaxEncodedCols);
    final nextRows = rows.clamp(1, kMaxViewportRows);
    final pw = (nextCols * cellWidth).round();
    final ph = (nextRows * cellHeight).round();
    _onTerminalResize(nextCols, nextRows, pw, ph);
    if (widget.isExited) {
      return;
    }
    _inGridMetricsResize = true;
    try {
      _terminal.resize(nextCols, nextRows, pw, ph);
    } finally {
      _inGridMetricsResize = false;
    }
  }

  void _onTerminalResize(
    int width,
    int height,
    int pixelWidth,
    int pixelHeight,
  ) {
    if (_inGridMetricsResize || _sessionDestroyed) return;
    if (width > 0 && height > 0) {
      _lastWorkspaceFittedSize = (height, width);
      if (widget.isExited) {
        return;
      }
      _sessionLastGridSize[widget.terminalId] = (height, width);
      if (width != _terminal.viewWidth) {
        _selectionAnchor = null;
      }
      final lh = _lineHeight() ?? 18.0;
      final pos = _scrollController.hasClients
          ? _scrollController.position
          : null;
      final hasSavedScroll = _hasValidSavedScroll();
      final isAtBottom =
          (pos == null || !pos.hasContentDimensions || pos.maxScrollExtent <= 0)
          ? !hasSavedScroll
          : pos.pixels >= pos.maxScrollExtent - 0.5;
      if (isAtBottom && !_metricsRestoreInFlight) {
        _scrollAnchor.clear();
        _clearSavedSessionScroll(widget.terminalId);
        if (_scrollController.hasClients) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_sessionDestroyed && _scrollController.hasClients) {
              final p = _scrollController.position;
              if (p.hasContentDimensions &&
                  p.pixels < p.maxScrollExtent - 0.5) {
                _snapToBottom(p);
              }
            }
          });
        }
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_sessionDestroyed && _scrollController.hasClients) {
            _restoreSavedScrollPosition(lh);
          }
        });
      }
      scheduleMicrotask(() {
        if (mounted && !_sessionDestroyed && !widget.isExited) {
          widget.onViewFit?.call(width, height);
        }
      });
      _scheduleResizeOut(width, height);
    }
  }

  void _scheduleResizeOut(int cols, int rows) {
    if (_sessionDestroyed || widget.isLoading || widget.isExited) {
      return;
    }
    if (_sessionLastResizeOutCols[widget.terminalId] == cols &&
        _sessionLastResizeOutRows[widget.terminalId] == rows) {
      _resizeOutDebounceTimer?.cancel();
      _pendingResizeOutCols = null;
      _pendingResizeOutRows = null;
      return;
    }
    _pendingResizeOutCols = cols;
    _pendingResizeOutRows = rows;
    _resizeOutDebounceTimer?.cancel();
    _resizeOutDebounceTimer = Timer(const Duration(milliseconds: 100), () {
      final pendingCols = _pendingResizeOutCols;
      final pendingRows = _pendingResizeOutRows;
      _pendingResizeOutCols = null;
      _pendingResizeOutRows = null;
      if (mounted &&
          !_sessionDestroyed &&
          !widget.isExited &&
          pendingCols != null &&
          pendingRows != null) {
        _sendResizeOutNow(pendingCols, pendingRows);
      }
    });
  }

  void _sendResizeOutNow(int cols, int rows) {
    _resizeOutDebounceTimer?.cancel();
    _pendingResizeOutCols = null;
    _pendingResizeOutRows = null;
    if (_sessionDestroyed) {
      return;
    }
    _lastWorkspaceFittedSize = (rows, cols);
    if (widget.isExited) {
      return;
    }
    _sessionLastGridSize[widget.terminalId] = (rows, cols);
    if (widget.isLoading) {
      return;
    }
    if (_sessionLastResizeOutCols[widget.terminalId] == cols &&
        _sessionLastResizeOutRows[widget.terminalId] == rows) {
      return;
    }
    _sessionLastResizeOutCols[widget.terminalId] = cols;
    _sessionLastResizeOutRows[widget.terminalId] = rows;
    widget.controller.sendResizeOut(cols, rows);
  }

  // --- Scroll anchoring & demand paging ---

  double? _lineHeight() {
    final render = _renderGrid;
    if (render != null && render.attached) {
      final lh = render.lineHeight;
      if (lh > 0) return lh;
    }
    return _kFontSize * _kLineHeightScale;
  }

  double _effectiveMaxScrollExtent(ScrollPosition position) {
    final render = _renderGrid;
    if (render != null && render.attached && render.hasSize) {
      final lh = render.lineHeight;
      if (lh > 0) {
        return max(_terminal.totalLines * lh - render.size.height, 0.0);
      }
    }
    return position.maxScrollExtent;
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted || _sessionDestroyed) return;
    if (!_metricsResizeSettling) {
      setState(() => _metricsResizeSettling = true);
    }
    _metricsSettleTimer?.cancel();
    _metricsSettleTimer = Timer(
      const Duration(milliseconds: 80),
      _finishMetricsResizeSettle,
    );
    final hasSavedScroll = _hasValidSavedScroll();
    if (!hasSavedScroll) return;
    _metricsRestoreInFlight = true;
    scheduleMicrotask(() {
      if (!mounted || _sessionDestroyed) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _metricsRestoreInFlight = false;
        if (!mounted || _sessionDestroyed || !_scrollController.hasClients) {
          return;
        }
        _restoreSavedScrollPosition(_lineHeight() ?? 18.0);
      });
    });
  }

  void _finishMetricsResizeSettle() {
    _metricsSettleTimer = null;
    if (!mounted || _sessionDestroyed) return;
    if (_metricsResizeSettling) {
      setState(() => _metricsResizeSettling = false);
    }
    _syncTerminalSizeToRender(
      sendResizeOut: !widget.isLoading && !widget.isExited,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_sessionDestroyed && !_metricsResizeSettling) {
        _syncTerminalSizeToRender(
          sendResizeOut: !widget.isLoading && !widget.isExited,
        );
      }
    });
  }

  void _syncTerminalSizeToRender({bool sendResizeOut = true}) {
    if (_sessionDestroyed) return;
    final render = _renderGrid;
    if (render == null || !render.attached || !render.hasSize) return;
    final cell = render.cellSize;
    if (cell.width <= 0 ||
        cell.height <= 0 ||
        render.size.width <= cell.width ||
        render.size.height <= cell.height) {
      return;
    }
    final cols = max(2, render.size.width ~/ cell.width);
    final rows = max(1, render.size.height ~/ cell.height);
    if (cols <= 0 || rows <= 0) return;

    _lastWorkspaceFittedSize = (rows, cols);
    if (widget.isExited) {
      _resizeOutDebounceTimer?.cancel();
      _pendingResizeOutCols = null;
      _pendingResizeOutRows = null;
      return;
    }
    final prevGrid = _sessionLastGridSize[widget.terminalId];
    _sessionLastGridSize[widget.terminalId] = (rows, cols);
    if (cols != _terminal.viewWidth || rows != _terminal.viewHeight) {
      _handleGridMetricsChanged(cols, rows, cell.width, cell.height);
    } else if (prevGrid != (rows, cols)) {
      scheduleMicrotask(() {
        if (mounted && !_sessionDestroyed && !widget.isExited) {
          widget.onViewFit?.call(cols, rows);
        }
      });
    }
    if (sendResizeOut && !widget.isExited) {
      _sendResizeOutNow(cols, rows);
    } else {
      _resizeOutDebounceTimer?.cancel();
      _pendingResizeOutCols = null;
      _pendingResizeOutRows = null;
    }
    render.markNeedsLayout();
    render.markNeedsPaint();
  }

  void _restoreSavedScrollPosition(double lh) {
    if (!_scrollController.hasClients) return;
    final p = _scrollController.position;
    final maxExtent = _effectiveMaxScrollExtent(p);
    if (!p.hasContentDimensions || maxExtent <= 0) return;
    if (p.isScrollingNotifier.value ||
        _hasActivePointerOrPanZoom ||
        _dragSelecting) {
      return;
    }
    double? target;
    if (_scrollAnchor.hasAnchor) {
      target = _scrollAnchor.desiredOffset(
        maxScrollExtent: maxExtent,
        lineHeight: lh,
      );
    }
    final dist = _sessionSavedDistanceFromBottom[widget.terminalId];
    final frac = _sessionSavedScrollFractions[widget.terminalId];
    final saved = _sessionSavedScrollOffsets[widget.terminalId];
    target ??= (dist != null && dist > 0.0)
        ? (maxExtent - dist).clamp(0.0, maxExtent)
        : (frac != null && frac >= 0.0)
        ? (maxExtent * frac).clamp(0.0, maxExtent)
        : (saved != null && saved >= 0.0)
        ? saved.clamp(0.0, maxExtent)
        : null;
    if (target != null && target >= 0.0) {
      final atBottom = target >= maxExtent - 0.5;
      final desired = atBottom ? maxExtent : target;
      if ((p.pixels - desired).abs() > 0.5) {
        _jumpPositionTo(p, desired, stickToBottom: atBottom);
      }
    }
  }

  void _onScrollChanged() {
    _scheduleHoveredLinkRefresh();
    if (_copyTarget != null) {
      _rebuildForCopyButton();
    }
    if (_suppressAnchorCapture ||
        _metricsRestoreInFlight ||
        _dragSelecting ||
        widget.isLoading) {
      return;
    }
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions || position.maxScrollExtent <= 0) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      return;
    }
    final isUserDriven =
        _hasActivePointerOrPanZoom ||
        position.userScrollDirection != ScrollDirection.idle;
    if (phase == SchedulerPhase.transientCallbacks && !isUserDriven) {
      return;
    }
    final previousPixels = _lastScrollPixels;
    if (!isUserDriven && previousPixels == null && position.pixels <= 0.5) {
      return;
    }
    if (position.pixels < position.maxScrollExtent - 0.5) {
      _scrollToCursorGeneration++;
      _scrollToCursorTimer?.cancel();
      _clearPointerReleaseTimers();
    }
    _captureScrollAnchor();
    final lh = _lineHeight() ?? 18.0;
    final movedUp =
        (previousPixels != null && position.pixels < previousPixels - 0.5) ||
        _hasActivePointerOrPanZoom ||
        position.userScrollDirection == ScrollDirection.forward;
    if (movedUp &&
        position.pixels <= lh * 5 &&
        position.pixels < position.maxScrollExtent - 0.5) {
      final fetching = widget.onNearTop?.call();
      if (fetching == false) {
        _awaitingNearTopFetch = false;
        noteHistoryExhausted();
      } else if (fetching == true) {
        _awaitingNearTopFetch = true;
      }
    } else if (position.pixels > lh * 5) {
      _awaitingNearTopFetch = false;
    }
  }

  void _saveScrollOffset([
    String? terminalId,
    double? lineHeight,
    double? maxScrollExtentOverride,
    TerminalCellBuffer? bufferOverride,
  ]) {
    final id = terminalId ?? widget.terminalId;
    if (_sessionDestroyed && id == widget.terminalId) return;
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final maxExtent = maxScrollExtentOverride ?? position.maxScrollExtent;
    if (!position.hasContentDimensions || maxExtent <= 0) return;
    final isAtBottom = position.pixels >= maxExtent - 0.5;
    if (!isAtBottom) {
      final clampedPixels = position.pixels.clamp(0.0, maxExtent);
      final buf = bufferOverride ?? _terminal;
      _sessionSavedScrollOffsets[id] = clampedPixels;
      if (!buf.isUsingAltBuffer) {
        _sessionSavedEraseScrollbackGen[id] = buf.eraseScrollbackGen;
      }
      if (_scrollAnchor.hasAnchor) {
        _sessionSavedScrollAnchors[id] = _scrollAnchor.clone();
      } else {
        _sessionSavedScrollAnchors.remove(id);
      }
      _sessionSavedDistanceFromBottom[id] = maxExtent - clampedPixels;
      _sessionSavedScrollFractions[id] = maxExtent > 0
          ? (clampedPixels / maxExtent).clamp(0.0, 1.0)
          : 0.0;
    } else {
      _clearSavedSessionScroll(id);
      if (id == widget.terminalId) {
        _scrollAnchor.clear();
      }
    }
  }

  void _captureScrollAnchor() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions || position.maxScrollExtent <= 0) return;
    final lineHeight = _lineHeight();
    if (lineHeight != null) {
      if (shouldReleaseScrollPin(
        lastPixels: _lastScrollPixels,
        pixels: position.pixels,
        maxScrollExtent: position.maxScrollExtent,
        lineHeight: lineHeight,
      )) {
        if (_scrollAnchor.hasAnchor) {
          _scrollAnchor.clear();
        }
        _clearSavedSessionScroll(widget.terminalId);
        _lastScrollPixels = position.pixels;
        if (shouldFinishBottomSnap(
          isScrolling: position.isScrollingNotifier.value,
          pointerDown: _hasActivePointerOrPanZoom,
          pixels: position.pixels,
          maxScrollExtent: position.maxScrollExtent,
          hasAnchor: false,
        )) {
          _pendingBottomSnapOnPointerUp = false;
          _snapToBottom(position);
        } else {
          _pendingBottomSnapOnPointerUp = true;
        }
        return;
      } else if (_pendingBottomSnapOnPointerUp &&
          _lastScrollPixels != null &&
          position.pixels >= _lastScrollPixels! &&
          position.pixels >=
              position.maxScrollExtent -
                  kScrollPinReleaseGraceLines * lineHeight) {
        _lastScrollPixels = position.pixels;
        return;
      } else {
        _pendingBottomSnapOnPointerUp = false;
        _scrollAnchor.capture(
          buffer: _terminal,
          pixels: position.pixels,
          maxScrollExtent: position.maxScrollExtent,
          lineHeight: lineHeight,
        );
      }
    }
    _lastScrollPixels = position.pixels;
    _saveScrollOffset(widget.terminalId, lineHeight);
  }

  void _jumpPositionTo(
    ScrollPosition position,
    double target, {
    required bool stickToBottom,
  }) {
    if (!position.hasContentDimensions) return;
    final render = _renderGrid;
    if (render != null) {
      render.stickToBottom = stickToBottom;
    }
    final layoutMaxExtent = position.maxScrollExtent;
    final effectiveMaxExtent = _effectiveMaxScrollExtent(position);
    final wasSuppressed = _suppressAnchorCapture;
    _suppressAnchorCapture = true;
    try {
      final clampedTarget = target.clamp(0.0, layoutMaxExtent);
      if ((position.pixels - clampedTarget).abs() > 1e-6) {
        position.jumpTo(clampedTarget);
      }
      if ((effectiveMaxExtent - layoutMaxExtent).abs() > 0.5) {
        render?.markNeedsLayout();
      }
    } finally {
      _suppressAnchorCapture = wasSuppressed;
      _lastScrollPixels = position.pixels;
    }
  }

  void _snapToBottom(ScrollPosition position) {
    if (!position.hasContentDimensions) return;
    final target = _effectiveMaxScrollExtent(position);
    _jumpPositionTo(position, target, stickToBottom: true);
    _clearSavedSessionScroll(widget.terminalId);
    _scrollAnchor.clear();
  }

  void _onTerminalContentChanged() {
    _scheduleHoveredLinkRefresh();
    if (!_sessionDestroyed &&
        identical(_mountedPanes[widget.terminalId], this) &&
        (!widget.isLoading || _terminal.lastFrameSeq > 0)) {
      _sessionBracketedPasteModes[widget.terminalId] =
          _terminal.bracketedPasteMode;
    }
    _syncFocusReporting();
    if (_awaitingNearTopFetch && !_nearTopCheckScheduled) {
      _nearTopCheckScheduled = true;
      final terminalId = widget.terminalId;
      final terminal = widget.terminal;
      scheduleMicrotask(() {
        _nearTopCheckScheduled = false;
        if (!mounted ||
            !_isActive ||
            !_awaitingNearTopFetch ||
            widget.terminalId != terminalId ||
            !identical(widget.terminal, terminal) ||
            !_scrollController.hasClients) {
          return;
        }
        final pos = _scrollController.position;
        if (!pos.hasContentDimensions) return;
        final lh = _lineHeight() ?? 18.0;
        if (pos.pixels > lh * 5 || pos.pixels >= pos.maxScrollExtent - 0.5) {
          _awaitingNearTopFetch = false;
          return;
        }
        if (widget.onNearTop?.call() == false) {
          _awaitingNearTopFetch = false;
          noteHistoryExhausted();
        }
      });
    }
    if (_terminal.isUsingAltBuffer != _lastIsAltBuffer) {
      _lastIsAltBuffer = _terminal.isUsingAltBuffer;
      _altScrollDeltaAccum = 0.0;
      _rebuildForCopyButton();
    }
    if (_selection != null &&
        !terminalSelectionIsLive(_terminal, _selection!)) {
      _clearSelection();
    } else if (_copyTarget != null) {
      final selection = _selection;
      if (selection == null || selection.isCollapsed) {
        _copyTarget = null;
        _copyTargetBuffer = null;
        _rebuildForCopyButton();
      } else if (identical(_terminal, _copyTargetBuffer) &&
          _terminal.isUsingAltBuffer == _copyTargetIsAlt) {
        _rebuildForCopyButton();
      }
    }
    final hasSavedScroll = _hasValidSavedScroll();
    if (!hasSavedScroll) {
      _renderGrid?.stickToBottom = true;
      if (_scrollController.hasClients &&
          !_hasActivePointerOrPanZoom &&
          !_dragSelecting) {
        final pos = _scrollController.position;
        if (pos.hasContentDimensions &&
            !pos.isScrollingNotifier.value &&
            pos.maxScrollExtent <= 0 &&
            _effectiveMaxScrollExtent(pos) > 0) {
          _snapToBottom(pos);
        }
      }
      if (!_repinScheduled) {
        _repinScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _repinScheduled = false;
          if (!mounted ||
              _sessionDestroyed ||
              !_scrollController.hasClients ||
              _hasValidSavedScroll() ||
              _hasActivePointerOrPanZoom ||
              _dragSelecting) {
            return;
          }
          final pos = _scrollController.position;
          if (pos.hasContentDimensions &&
              pos.maxScrollExtent > 0 &&
              !pos.isScrollingNotifier.value &&
              pos.pixels < pos.maxScrollExtent - 0.5) {
            _snapToBottom(pos);
          }
        });
      }
      return;
    }
    if (_repinScheduled) return;
    _repinScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _repinScheduled = false;
      _repinScrollAnchor();
    });
  }

  void _repinScrollAnchor() {
    if (!mounted || _sessionDestroyed || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions || position.maxScrollExtent <= 0) return;
    if (position.isScrollingNotifier.value ||
        _hasActivePointerOrPanZoom ||
        _dragSelecting) {
      return;
    }
    final lineHeight = _lineHeight();
    if (lineHeight == null) return;
    final desired = _scrollAnchor.desiredOffset(
      maxScrollExtent: position.maxScrollExtent,
      lineHeight: lineHeight,
    );
    if (desired == null || desired < 0.0) {
      if (!_hasValidSavedScroll()) {
        _snapToBottom(position);
      }
      return;
    }
    if (!_scrollAnchor.hasLineShifted) return;
    if ((desired - position.pixels).abs() < 0.5) {
      _scrollAnchor.markPinned();
      return;
    }
    _scrollAnchor.markPinned();
    final wasSuppressed = _suppressAnchorCapture;
    _suppressAnchorCapture = true;
    try {
      position.jumpTo(desired);
    } finally {
      _suppressAnchorCapture = wasSuppressed;
      _lastScrollPixels = position.pixels;
    }
    _saveScrollOffset(widget.terminalId, lineHeight);
  }

  void _scrollToCursor({required bool requestFocus, bool forceBottom = false}) {
    final scrollGen = ++_scrollToCursorGeneration;
    var retriesLeft = 8;
    void jump() {
      if (!mounted ||
          _sessionDestroyed ||
          scrollGen != _scrollToCursorGeneration) {
        return;
      }
      if (_scrollController.hasClients) {
        final position = _scrollController.position;
        final maxExtent = _effectiveMaxScrollExtent(position);
        if (!position.hasContentDimensions || maxExtent <= 0) {
          if (_terminal.totalLines > _terminal.viewHeight && retriesLeft > 0) {
            retriesLeft--;
            _renderGrid?.markNeedsLayout();
            WidgetsBinding.instance.addPostFrameCallback((_) => jump());
            return;
          }
          if (position.hasContentDimensions) {
            _lastScrollPixels = position.pixels;
          }
          if (requestFocus) {
            _requestTerminalFocus();
          }
          return;
        }
        final hasValidSaved = _hasValidSavedScroll();
        final saved = _sessionSavedScrollOffsets[widget.terminalId];
        final savedDistance =
            _sessionSavedDistanceFromBottom[widget.terminalId];
        final savedFraction = _sessionSavedScrollFractions[widget.terminalId];
        final lineHeight = _lineHeight();
        final wasScrolledUp =
            !forceBottom &&
            hasValidSaved &&
            (saved != null ||
                savedDistance != null ||
                savedFraction != null ||
                _scrollAnchor.hasAnchor);

        if (!wasScrolledUp) {
          _snapToBottom(position);
        } else {
          double? desired;
          if (_scrollAnchor.hasAnchor && lineHeight != null) {
            desired = _scrollAnchor.desiredOffset(
              maxScrollExtent: maxExtent,
              lineHeight: lineHeight,
            );
          }
          double target;
          if (desired != null && desired >= 0.0) {
            target = desired;
          } else if (savedDistance != null && savedDistance > 0.0) {
            target = (maxExtent - savedDistance).clamp(0.0, maxExtent);
          } else if (savedFraction != null && savedFraction >= 0.0) {
            target = (maxExtent * savedFraction).clamp(0.0, maxExtent);
          } else if (saved != null && saved >= 0.0) {
            target = saved.clamp(0.0, maxExtent);
          } else {
            final isNearBottom = position.pixels >= maxExtent - 0.5;
            target = isNearBottom
                ? maxExtent
                : position.pixels.clamp(0.0, maxExtent);
          }

          if (target >= maxExtent - 0.5) {
            _snapToBottom(position);
          } else {
            _jumpPositionTo(position, target, stickToBottom: false);
          }
        }

        if (!wasScrolledUp && retriesLeft > 0) {
          retriesLeft--;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                scrollGen != _scrollToCursorGeneration ||
                !_scrollController.hasClients) {
              return;
            }
            final pos = _scrollController.position;
            final extent = _effectiveMaxScrollExtent(pos);
            if (!pos.hasContentDimensions || extent <= 0) return;
            if ((pos.pixels - extent).abs() > 0.5) {
              _snapToBottom(pos);
            }
          });
        }
      }
      if (requestFocus) {
        _requestTerminalFocus();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    _scrollToCursorTimer?.cancel();
    _scrollToCursorTimer = Timer(const Duration(milliseconds: 50), jump);
  }

  // --- Hardware keyboard handling ---

  /// Outer key handler shared by both the `FLUTTER_TEST` fallback view and
  /// [TerminalGridView]. Handles Tab, Shift+Tab, Shift+Enter, Copy, SelectAll,
  /// and Paste shortcuts.
  KeyEventResult _handleOuterKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isRouteCurrentAndUnobscured) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (widget.isExited) {
        return KeyEventResult.ignored;
      }
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isControlPressed ||
          keyboard.isAltPressed ||
          keyboard.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        final encoded = encodeTerminalKeyEvent(
          event,
          shift: keyboard.isShiftPressed,
          ctrl: keyboard.isControlPressed,
          alt: keyboard.isAltPressed,
          meta: keyboard.isMetaPressed,
          capsLock: keyboard.lockModesEnabled.contains(
            KeyboardLockMode.capsLock,
          ),
          platform: defaultTargetPlatform,
          appCursorKeys: _terminal.appCursorKeys,
          kittyKeyboardFlags: _terminal.kittyKeyboardFlags,
        );
        if (encoded == null) {
          return KeyEventResult.ignored;
        }
        _flushImeComposing();
        widget.controller.notifyInteraction();
        _disarmCtrl();
        _mobileAutoSpace.reset();
        _clearSavedSessionScroll(widget.terminalId);
        _scrollAnchor.clear();
        if (_scrollController.hasClients &&
            _scrollController.position.hasContentDimensions) {
          try {
            _snapToBottom(_scrollController.position);
          } catch (_) {}
        }
        widget.controller.sendInput(encoded, fromHardwareKey: true);
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if ((event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !widget.isExited) {
      final keys = HardwareKeyboard.instance;
      final bytes = bytesForEnterKey(
        shift: keys.isShiftPressed,
        ctrl: keys.isControlPressed,
        alt: keys.isAltPressed,
        meta: keys.isMetaPressed,
      );
      if (bytes != null) {
        final encoded =
            encodeTerminalKeyEvent(
              event,
              shift: keys.isShiftPressed,
              ctrl: keys.isControlPressed,
              alt: keys.isAltPressed,
              meta: keys.isMetaPressed,
              capsLock: keys.lockModesEnabled.contains(
                KeyboardLockMode.capsLock,
              ),
              platform: defaultTargetPlatform,
              appCursorKeys: _terminal.appCursorKeys,
              kittyKeyboardFlags: _terminal.kittyKeyboardFlags,
            ) ??
            bytes;
        _flushImeComposing();
        widget.controller.notifyInteraction();
        _disarmCtrl();
        _mobileAutoSpace.reset();
        _clearSavedSessionScroll(widget.terminalId);
        _scrollAnchor.clear();
        if (_scrollController.hasClients &&
            _scrollController.position.hasContentDimensions) {
          try {
            _snapToBottom(_scrollController.position);
          } catch (_) {}
        }
        widget.controller.sendInput(encoded, fromHardwareKey: true);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC && _isCopyChord()) {
      if (_copySelectionToClipboard()) return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyA && _isSelectAllChord()) {
      final lastRow = _lastWrittenVirtualRow();
      if (lastRow >= 0 && _terminal.viewWidth > 0) {
        final endCols = max(
          _terminal.viewWidth,
          _terminal.lineAtVirtualRow(lastRow)?.length ?? 0,
        );
        _applySelection(
          const CellOffset(0, 0),
          CellOffset(endCols - 1, lastRow),
        );
        _selectionAnchor = _anchorAt(const CellOffset(0, 0));
      }
      return KeyEventResult.handled;
    }
    if (widget.isExited) {
      return KeyEventResult.ignored;
    }
    if (kIsWeb &&
        _disposeWebPasteListener != null &&
        (_isBrowserNativePasteKey(event) ||
            (!canReadWebClipboardAsync() && _isPasteChord(event)))) {
      return KeyEventResult.ignored;
    }
    if (_isPasteChord(event)) {
      unawaited(_pasteFromClipboard());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Full hardware key handler mounted on [TerminalGridView]. Runs
  /// [_handleOuterKeyEvent] first, then encodes standard VT/xterm/Kitty key
  /// events via [encodeTerminalKeyEvent].
  KeyEventResult _handleGridKeyEvent(FocusNode node, KeyEvent event) {
    final outer = _handleOuterKeyEvent(node, event);
    if (outer != KeyEventResult.ignored) {
      return outer;
    }
    if (widget.isExited || !_isRouteCurrentAndUnobscured) {
      return KeyEventResult.ignored;
    }
    if (kIsWeb &&
        _disposeWebPasteListener != null &&
        (_isBrowserNativePasteKey(event) ||
            (!canReadWebClipboardAsync() && _isPasteChord(event)))) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final effectiveCtrl = keys.isControlPressed || _ctrlArmed;
    final encoded = encodeTerminalKeyEvent(
      event,
      shift: keys.isShiftPressed,
      ctrl: effectiveCtrl,
      alt: keys.isAltPressed,
      meta: keys.isMetaPressed,
      capsLock: keys.lockModesEnabled.contains(KeyboardLockMode.capsLock),
      platform: defaultTargetPlatform,
      appCursorKeys: _terminal.appCursorKeys,
      kittyKeyboardFlags: _terminal.kittyKeyboardFlags,
    );
    if (encoded != null) {
      _flushImeComposing();
      if (_ctrlArmed) {
        _disarmCtrl();
      }
      widget.controller.notifyInteraction();
      _onTerminalOutput(encoded, fromHardwareKey: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- Copy & Paste ---

  void _syncCopyTarget() {
    if (!_isMobile) return;
    final selection = _selection;
    final next = (selection == null || selection.isCollapsed)
        ? null
        : selection;
    final nextBuffer = next == null ? null : _terminal;
    final nextIsAlt = _terminal.isUsingAltBuffer;
    if (next == _copyTarget &&
        identical(nextBuffer, _copyTargetBuffer) &&
        nextIsAlt == _copyTargetIsAlt) {
      return;
    }
    _copyTarget = next;
    _copyTargetBuffer = nextBuffer;
    _copyTargetIsAlt = nextIsAlt;
    _rebuildForCopyButton();
  }

  TerminalSelectionRange? get _liveCopySelection {
    if (_copyTarget == null) return null;
    if (!identical(_terminal, _copyTargetBuffer)) return null;
    if (_terminal.isUsingAltBuffer != _copyTargetIsAlt) return null;
    final selection = _selection;
    if (selection == null || selection.isCollapsed) return null;
    if (!terminalSelectionIsLive(_terminal, selection)) return null;
    return selection;
  }

  void _rebuildForCopyButton() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_copyRebuildScheduled) return;
      _copyRebuildScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _copyRebuildScheduled = false;
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  bool _copySelectionToClipboard() {
    final selection = _selection;
    if (selection == null || !terminalSelectionIsLive(_terminal, selection)) {
      return false;
    }
    final text = terminalSelectionText(_terminal, selection);
    if (text.isEmpty) return false;
    unawaited(copyTextWithWebFallback(text));
    _clearSelection();
    return true;
  }

  Widget? _buildCopyButton() {
    final selection = _liveCopySelection;
    if (selection == null) return null;
    final render = _renderGrid;
    final overlayBox =
        _copyOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (render == null ||
        !render.attached ||
        !render.hasSize ||
        overlayBox == null ||
        !overlayBox.hasSize) {
      return null;
    }

    final Offset anchor;
    final double selectionBottom;
    final double lineHeight;
    try {
      final (begin, end) = selection.normalizedIn(_terminal);
      lineHeight = render.lineHeight;
      anchor = overlayBox.globalToLocal(
        render.localToGlobal(render.getOffset(begin)),
      );
      final endPt = overlayBox.globalToLocal(
        render.localToGlobal(render.getOffset(end)),
      );
      selectionBottom = endPt.dy + lineHeight;
    } catch (_) {
      return null;
    }

    const buttonSize = Size(104, 36);
    final placement = placeCopyButton(
      anchor: anchor,
      selectionBottom: selectionBottom,
      lineHeight: lineHeight,
      viewport: overlayBox.size,
      button: buttonSize,
    );
    if (placement == null) return null;

    return Positioned(
      left: placement.left,
      top: placement.top,
      child: _CopyButton(
        width: buttonSize.width,
        height: buttonSize.height,
        onCopy: () {
          if (_liveCopySelection == null) return;
          _copySelectionToClipboard();
        },
      ),
    );
  }

  bool _hasPrimaryTerminalShortcutModifiers() {
    final keys = HardwareKeyboard.instance;
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
        return keys.isMetaPressed &&
            !keys.isControlPressed &&
            !keys.isAltPressed &&
            !keys.isShiftPressed;
      default:
        return keys.isControlPressed &&
            keys.isShiftPressed &&
            !keys.isMetaPressed &&
            !keys.isAltPressed;
    }
  }

  bool _isCopyChord() => _hasPrimaryTerminalShortcutModifiers();
  bool _isSelectAllChord() => _hasPrimaryTerminalShortcutModifiers();

  bool _isPasteChord(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.insert &&
        keys.isShiftPressed &&
        !keys.isControlPressed &&
        !keys.isMetaPressed &&
        !keys.isAltPressed) {
      return true;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyV) {
      return false;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
        return keys.isMetaPressed &&
            !keys.isControlPressed &&
            !keys.isAltPressed &&
            !keys.isShiftPressed;
      case TargetPlatform.android:
        return (keys.isControlPressed || keys.isMetaPressed) &&
            !keys.isAltPressed;
      case TargetPlatform.windows:
        return keys.isControlPressed &&
            !keys.isMetaPressed &&
            !keys.isAltPressed;
      default:
        return keys.isControlPressed &&
            keys.isShiftPressed &&
            !keys.isMetaPressed &&
            !keys.isAltPressed;
    }
  }

  bool _isBrowserNativePasteKey(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.insert) {
      if (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        return false;
      }
      return keys.isShiftPressed &&
          !keys.isControlPressed &&
          !keys.isMetaPressed &&
          !keys.isAltPressed;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyV) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
        return keys.isMetaPressed &&
            !keys.isControlPressed &&
            !keys.isAltPressed &&
            !keys.isShiftPressed;
      case TargetPlatform.android:
        return (keys.isControlPressed || keys.isMetaPressed) &&
            !keys.isAltPressed;
      case TargetPlatform.windows:
        return keys.isControlPressed &&
            !keys.isMetaPressed &&
            !keys.isAltPressed;
      default:
        return keys.isControlPressed &&
            keys.isShiftPressed &&
            !keys.isMetaPressed &&
            !keys.isAltPressed;
    }
  }

  bool _onWebDomPaste(String text) {
    if (!mounted ||
        text.isEmpty ||
        widget.isExited ||
        !_isRouteCurrentAndUnobscured ||
        !_focusNode.hasFocus ||
        _isPasteDialogShowing) {
      return false;
    }
    if (!_isPasting) {
      unawaited(_handlePaste(text));
    }
    return true;
  }

  bool _isBracketedPasteEnabled() => _terminal.bracketedPasteMode;

  Future<void> _handlePaste(String text) async {
    if (!mounted ||
        text.isEmpty ||
        widget.isExited ||
        !_isRouteCurrentAndUnobscured) {
      return;
    }
    _flushImeComposing();
    _disarmCtrl();
    _mobileAutoSpace.reset();
    void snapOnSend() {
      _clearSavedSessionScroll(widget.terminalId);
      _scrollAnchor.clear();
      if (_scrollController.hasClients &&
          _scrollController.position.hasContentDimensions) {
        _snapToBottom(_scrollController.position);
      }
    }

    final isBracketed = _isBracketedPasteEnabled();
    if (isBracketed || !isMultiLine(text)) {
      snapOnSend();
      final formatted = formatPasteInput(text, isBracketed);
      widget.controller.sendInput(formatted);
      _clearSelection();
      return;
    }

    if (_isPasteDialogShowing) return;
    _isPasteDialogShowing = true;
    try {
      final chosenText = await showMultiLinePasteDialog(context, text);
      if (chosenText != null &&
          mounted &&
          !widget.isExited &&
          _isRouteCurrentAndUnobscured) {
        _disarmCtrl();
        _mobileAutoSpace.reset();
        snapOnSend();
        final formatted = formatPasteInput(
          chosenText,
          _isBracketedPasteEnabled(),
        );
        widget.controller.sendInput(formatted);
        _clearSelection();
      }
    } catch (e) {
      debugPrint('TerminalPane: failed to handle paste: $e');
    } finally {
      _isPasteDialogShowing = false;
      if (mounted && !widget.isExited) {
        _requestTerminalFocus();
      }
    }
  }

  Future<void> _pasteFromClipboard() async {
    if (!mounted || widget.isExited || !_isRouteCurrentAndUnobscured) return;
    if (_isPasting) return;
    _isPasting = true;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = data?.text;
      if (text != null && text.isNotEmpty) {
        await _handlePaste(text);
        _clearSelection();
      }
    } catch (e) {
      debugPrint('TerminalPane: failed to read clipboard on paste: $e');
    } finally {
      _isPasting = false;
    }
  }

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android ||
      isWebMobileBrowser();

  Widget _buildAccessoryBar() {
    return TerminalAccessoryBar(
      onSend: _sendAccessory,
      onToggleCtrl: _toggleCtrl,
      onPaste: () => unawaited(_pasteFromClipboard()),
      ctrlArmed: _ctrlArmed,
    );
  }

  @override
  Widget build(BuildContext context) {
    _didBuildOnce = true;
    final isTest = runningUnderFlutterTest();
    final useTestFallback =
        isTest && !TerminalPane.debugForceNativeTerminalView;
    if (useTestFallback) {
      return Focus(
        focusNode: _focusNode,
        autofocus: _mayTakeFocus,
        onKeyEvent: _handleOuterKeyEvent,
        child: Container(
          color: const Color(0xff0d1113),
          child: Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                ignoring:
                    widget.isLoading ||
                    widget.isObscured ||
                    !widget.interactionEnabled,
                child: AnimatedOpacity(
                  opacity: widget.isLoading ? 0.7 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _handlePointerDown,
                    onPointerMove: _handlePointerMove,
                    onPointerHover: _handlePointerHover,
                    onPointerUp: _handlePointerUp,
                    onPointerCancel: _handlePointerCancel,
                    onPointerSignal: _handlePointerSignal,
                    onPointerPanZoomStart: _handlePointerPanZoomStart,
                    onPointerPanZoomUpdate: _handlePointerPanZoomUpdate,
                    onPointerPanZoomEnd: _handlePointerPanZoomEnd,
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      primary: false,
                      padding: const EdgeInsets.all(22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final row in widget.fallbackRows)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 7),
                              child: SelectableText.rich(
                                TextSpan(
                                  children: [
                                    for (final span in row.spans)
                                      TextSpan(
                                        text: span.text.isEmpty
                                            ? ' '
                                            : span.text,
                                        style: TextStyle(
                                          fontFamily: 'JetBrains Mono',
                                          fontSize: 15,
                                          height: 1.35,
                                          color:
                                              span.style.foreground
                                                  ?.toColor() ??
                                              const Color(0xffd9e5e3),
                                          backgroundColor: span.style.background
                                              ?.toColor(),
                                          fontWeight: span.style.bold
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          fontStyle: span.style.italic
                                              ? FontStyle.italic
                                              : FontStyle.normal,
                                          decoration: span.style.underline
                                              ? TextDecoration.underline
                                              : TextDecoration.none,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.isLoading)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 2,
                  child: LinearProgressIndicator(
                    value: isTest ? 0.5 : null,
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                    color: const Color(0xffffc857),
                  ),
                ),
              if (showNoOlderScrollback)
                const Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(child: NoOlderScrollbackPill()),
                ),
            ],
          ),
        ),
      );
    }

    final padding = _isMobile
        ? const EdgeInsets.all(8)
        : const EdgeInsets.only(left: 22, top: 22, bottom: 22, right: 18);

    final copyButton = _buildCopyButton();
    final hasSavedScroll = _hasValidSavedScroll();

    return Container(
      color: const Color(0xff0d1113),
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _focusTerminal,
              onLongPressStart: _isMobile ? _handleMobileLongPressStart : null,
              onLongPressMoveUpdate: _isMobile
                  ? _handleMobileLongPressMoveUpdate
                  : null,
              onLongPressEnd: _isMobile ? _handleMobileLongPressEnd : null,
              child: TerminalScrollbar(
                controller: _scrollController,
                enabled: !_isMobile && widget.interactionEnabled,
                child: Stack(
                  key: _copyOverlayKey,
                  fit: StackFit.expand,
                  children: [
                    IgnorePointer(
                      ignoring:
                          widget.isLoading ||
                          widget.isObscured ||
                          !widget.interactionEnabled,
                      child: AnimatedOpacity(
                        opacity: widget.isLoading ? 0.7 : 1.0,
                        duration: const Duration(milliseconds: 150),
                        child: Padding(
                          padding: padding,
                          child: MouseRegion(
                            cursor: _terminalMouseCursor,
                            onHover: _isMobile ? null : _handleMouseHover,
                            onExit: _isMobile ? null : _handleMouseExit,
                            child: Listener(
                              behavior: HitTestBehavior.translucent,
                              onPointerDown: _handlePointerDown,
                              onPointerMove: _handlePointerMove,
                              onPointerHover: _handlePointerHover,
                              onPointerUp: _handlePointerUp,
                              onPointerCancel: _handlePointerCancel,
                              onPointerSignal: _handlePointerSignal,
                              onPointerPanZoomStart: _handlePointerPanZoomStart,
                              onPointerPanZoomUpdate:
                                  _handlePointerPanZoomUpdate,
                              onPointerPanZoomEnd: _handlePointerPanZoomEnd,
                              child: NotificationListener<ScrollEndNotification>(
                                onNotification: (notification) {
                                  scheduleMicrotask(() {
                                    if (!mounted ||
                                        !_scrollController.hasClients) {
                                      return;
                                    }
                                    if (_scrollAnchor.hasAnchor) {
                                      _repinScrollAnchor();
                                    } else if (_pendingBottomSnapOnPointerUp) {
                                      final pos = _scrollController.position;
                                      if (pos.hasContentDimensions &&
                                          !pos.isScrollingNotifier.value &&
                                          !_hasActivePointerOrPanZoom) {
                                        _pendingBottomSnapOnPointerUp = false;
                                        _snapToBottom(pos);
                                      }
                                    }
                                  });
                                  return false;
                                },
                                child: ScrollConfiguration(
                                  behavior: ScrollConfiguration.of(context)
                                      .copyWith(
                                        scrollbars: false,
                                        physics:
                                            (!widget.isExited &&
                                                _terminal.isUsingAltBuffer)
                                            ? const NeverScrollableScrollPhysics()
                                            : const _TerminalScrollPhysics(),
                                      ),
                                  child: MediaQuery(
                                    data: const MediaQueryData(),
                                    child: TerminalGridView(
                                      key: _gridViewKey,
                                      buffer: _terminal,
                                      scrollController: _scrollController,
                                      selection: _selection,
                                      hoveredLink: _hoveredLink,
                                      focusNode: _focusNode,
                                      autofocus: _mayTakeFocus,
                                      onKeyEvent: _handleGridKeyEvent,
                                      autoResize: !_metricsResizeSettling,
                                      stickToBottom: !hasSavedScroll,
                                      showCursor: !widget.isExited,
                                      fontSize: _kFontSize,
                                      lineHeightScale: _kLineHeightScale,
                                      textScaler: MediaQuery.textScalerOf(
                                        context,
                                      ),
                                      physics:
                                          (!widget.isExited &&
                                              _terminal.isUsingAltBuffer)
                                          ? const NeverScrollableScrollPhysics()
                                          : const _TerminalScrollPhysics(),
                                      onGridMetricsChanged:
                                          _handleGridMetricsChanged,
                                      onMissingRowsVisible:
                                          widget.onFetchScrollbackRows,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.isLoading)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 2,
                        child: LinearProgressIndicator(
                          value: isTest ? 0.5 : null,
                          minHeight: 2,
                          backgroundColor: Colors.transparent,
                          color: const Color(0xffffc857),
                        ),
                      ),
                    if (copyButton != null) copyButton,
                    if (showNoOlderScrollback)
                      const Positioned(
                        top: 8,
                        left: 0,
                        right: 0,
                        child: Center(child: NoOlderScrollbackPill()),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_isMobile) _buildAccessoryBar(),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({
    required this.width,
    required this.height,
    required this.onCopy,
  });

  final double width;
  final double height;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onCopy,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xff232c2f),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xff3a474b)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.copy, size: 15, color: Color(0xffd9e5e3)),
              SizedBox(width: 7),
              Text(
                'Copy',
                style: TextStyle(
                  color: Color(0xffd9e5e3),
                  fontSize: 13,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TerminalScrollPhysics extends ClampingScrollPhysics {
  const _TerminalScrollPhysics({super.parent});

  @override
  _TerminalScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TerminalScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    if (!isScrolling && velocity == 0.0) {
      return newPosition.pixels.clamp(
        newPosition.minScrollExtent,
        newPosition.maxScrollExtent,
      );
    }
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (velocity.abs() < toleranceFor(position).velocity) {
      return null;
    }
    return super.createBallisticSimulation(position, velocity);
  }
}

class _AnchoredCell {
  const _AnchoredCell({
    required this.cell,
    required this.buffer,
    required this.trimmedTopRows,
    required this.eraseScrollbackGen,
    required this.reflowGen,
    required this.isAltScreen,
  });

  final CellOffset cell;
  final TerminalCellBuffer buffer;
  final int trimmedTopRows;
  final int eraseScrollbackGen;
  final int reflowGen;
  final bool isAltScreen;

  CellOffset? resolveIn(TerminalCellBuffer current) {
    if (!identical(buffer, current)) return null;
    if (isAltScreen != current.isUsingAltBuffer) return null;
    if (eraseScrollbackGen != current.eraseScrollbackGen) return null;
    if (reflowGen != current.reflowGen) return null;
    final delta = isAltScreen ? 0 : (trimmedTopRows - current.trimmedTopRows);
    final y = cell.y + delta;
    if (y < 0 || y >= current.totalLines) return null;
    return CellOffset(cell.x, y);
  }

  _AnchoredCell shiftedForHistoryPage({
    required int addedLines,
    required int lineCount,
  }) {
    final shifted = shiftCellOffsetForHistoryPage(
      offset: cell,
      addedLines: addedLines,
      lineCount: lineCount,
    );
    if (shifted == null) return this;
    return _AnchoredCell(
      cell: shifted,
      buffer: buffer,
      trimmedTopRows: trimmedTopRows,
      eraseScrollbackGen: eraseScrollbackGen,
      reflowGen: reflowGen,
      isAltScreen: isAltScreen,
    );
  }
}
