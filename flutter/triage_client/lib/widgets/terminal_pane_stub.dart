import 'dart:async';
import 'dart:math' show max, min;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerPanZoomEndEvent,
        PointerPanZoomStartEvent,
        PointerPanZoomUpdateEvent,
        PointerScrollEvent,
        PointerSignalEvent,
        kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyRepeatEvent,
        LogicalKeyboardKey;
import 'package:xterm/xterm.dart' as xt;
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/terminal/control_bytes.dart';
import 'package:triage_client/terminal/copy_button_layout.dart';
import 'package:triage_client/terminal/emulator_query_response.dart';
import 'package:triage_client/terminal/mobile_auto_space.dart';
import 'package:triage_client/terminal/terminal_keyboard_mode.dart';
import 'package:triage_client/terminal/terminal_paste.dart';
import 'package:triage_client/terminal/terminal_scroll_anchor.dart';
import 'package:triage_client/platform_env_io.dart';
import 'package:triage_client/terminal/terminal_selection.dart';
import 'package:triage_client/widgets/multiline_paste_dialog.dart';
import 'package:triage_client/widgets/terminal_accessory_bar.dart';
import 'package:triage_client/widgets/terminal_scrollbar.dart';

import 'terminal_pane.dart';

/// Native terminal view. A thin presentation layer over the persistent
/// `xterm.dart` [xt.Terminal] owned by the session: all content is written
/// through the session's `TerminalStore` -> controller -> this terminal, so the
/// pane only renders, forwards input/resize-out, and manages focus/scroll.
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
    this.onNearTop,
    this.bracketedPasteEnabled = false,
    this.isExited = false,
    this.isLoading = false,
    this.isObscured = false,
    this.interactionEnabled = true,
    this.softKeyboardEnabled = true,
  });

  final String terminalId;
  final TerminalController controller;
  final xt.Terminal terminal;
  // Paging request, reporting back whether a page launched (see
  // SessionWorkspace.onNearTop). The trigger ignores the answer; the
  // history-replayed handler uses it to auto-continue or report.
  final bool Function()? onNearTop;
  final bool bracketedPasteEnabled;

  /// Plain rows rendered only by the FLUTTER_TEST fallback view.
  final List<StyledRow> fallbackRows;

  final void Function(void Function(int w, int h, int pw, int ph)? callback)?
  onTerminalResizeBind;

  /// Reports the fitted grid size after layout, so the session can replay its
  /// staged history at the real terminal size (deferred until first fit).
  final void Function(int cols, int rows)? onViewFit;

  final int focusCursorRevision;
  final bool isExited;
  final bool isLoading;

  /// True when an in-route overlay (such as the mobile session rail) covers
  /// the workspace, so pointer/touch gestures on the overlay cannot leak into
  /// or scroll the terminal underneath.
  final bool isObscured;

  /// False while the session rail overlay covers the workspace or a rail drag
  /// is in flight, so gestures on the rail never scroll or focus the terminal.
  final bool interactionEnabled;

  /// Mobile soft-keyboard kill switch. While false the pane neither takes
  /// focus nor opens the IME path, so the keyboard stays down and its
  /// viewport insets stop churning the terminal layout. Desktop ignores it.
  final bool softKeyboardEnabled;

  static void destroySession(String terminalId) {
    final sanitizedId = terminalId.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '_');
    _TerminalPaneState._mountedPanes.remove(terminalId);
    _TerminalPaneState._clearSavedSessionScroll(terminalId);
    _TerminalPaneState._sessionBracketedPasteModes.remove(terminalId);
    _TerminalPaneState._sessionLastResizeOutCols.remove(terminalId);
    _TerminalPaneState._sessionLastResizeOutRows.remove(terminalId);
    _TerminalPaneState._sessionLastGridSize.remove(sanitizedId);
    _TerminalPaneState._sessionLastGridSize.remove(terminalId);
  }

  static void setBracketedPasteMode(String terminalId, bool enabled) {
    _TerminalPaneState._sessionBracketedPasteModes[terminalId] = enabled;
  }

  /// Rebinds the mounted pane for [terminalId] to [controller] immediately so
  /// history-replay notifications emitted before the next widget rebuild are
  /// not lost on the outgoing placeholder controller.
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
    final sanitizedId = terminalId.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '_');
    return _TerminalPaneState._sessionLastGridSize[sanitizedId] ??
        _TerminalPaneState._sessionLastGridSize[terminalId];
  }

  /// Last fitted workspace grid size as (rows, cols).
  static (int, int)? getLastFittedWorkspaceSize() =>
      _TerminalPaneState._lastWorkspaceFittedSize;

  /// When true in widget tests, renders the real `xt.TerminalView`
  /// (`RenderTerminal`) instead of the `SingleChildScrollView` test fallback.
  @visibleForTesting
  static bool debugForceNativeTerminalView = false;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane>
    with WidgetsBindingObserver, NoOlderScrollbackLatch {
  static final Map<String, _TerminalPaneState> _mountedPanes = {};
  static final Map<String, double> _sessionSavedScrollOffsets = {};
  static final Map<String, TerminalScrollAnchor> _sessionSavedScrollAnchors =
      {};
  static final Map<String, double> _sessionSavedDistanceFromBottom = {};
  static final Map<String, double> _sessionSavedScrollFractions = {};
  static final Map<String, int> _sessionLastResizeOutCols = {};
  static final Map<String, int> _sessionLastResizeOutRows = {};
  static final Map<String, (int, int)> _sessionLastGridSize = {};
  static (int, int)? _lastWorkspaceFittedSize;

  static void _clearSavedSessionScroll(String id) {
    _sessionSavedScrollOffsets.remove(id);
    _sessionSavedScrollAnchors.remove(id);
    _sessionSavedDistanceFromBottom.remove(id);
    _sessionSavedScrollFractions.remove(id);
  }

  /// A finite initial scroll offset sentinel (1 billion pixels) that complies
  /// with Flutter's ScrollController bounds checking (`assert(initialScrollOffset.isFinite)`),
  /// while safely clamping to `maxScrollExtent` during the very first layout pass to
  /// prevent frame-0 rendering jumps.
  static const double _kBottomScrollSentinel = 1e9;
  xt.Terminal get _terminal => widget.terminal;
  final FocusNode _focusNode = FocusNode();
  late final ScrollController _scrollController;
  TerminalController? _boundController;
  double? _pageAnchorPixels;
  int? _pageAnchorLines;
  DateTime? _pageAnchorAt;
  xt.CellOffset? _pageSelectionBase;
  xt.CellOffset? _pageSelectionExtent;
  int _pageJumpGeneration = 0;
  int _scrollToCursorGeneration = 0;

  void _clearPageAnchor() {
    _pageAnchorPixels = null;
    _pageAnchorLines = null;
    _pageAnchorAt = null;
    _pageSelectionBase = null;
    _pageSelectionExtent = null;
  }

  // Keeps the viewport pinned to a scrollback line while the user is scrolled
  // up, so scrollback trims don't drift their content (see TerminalScrollAnchor).
  final TerminalScrollAnchor _scrollAnchor = TerminalScrollAnchor();
  // True while we drive `_scrollController` ourselves, so the resulting scroll
  // notification doesn't re-capture the anchor from our own correction.
  bool _suppressAnchorCapture = false;

  bool _repinScheduled = false;
  // Viewport pixels at the previous scroll event, to tell a downward chase
  // (release the pin near the bottom) from upward reading (keep it).
  //
  // Scroll events maintain it, and our own corrections (the anchor re-pin and
  // the bottom snap) record the offset they landed on. Anything that leaves no
  // meaningful previous *user* position nulls it instead: a terminal swap, a
  // cursor jump, and the end of a drag-select. Output-driven jumps to the
  // bottom deliberately leave it alone, since they clear the anchor on the way
  // and land at the bottom, so there is no pin left for a stale reading to
  // release.
  double? _lastScrollPixels;
  // Pointers currently down on the terminal. A hold activity reports *not*
  // scrolling, so the scroll state alone would treat a finger resting on a
  // stopped fling as settled.
  final Set<int> _activePointers = <int>{};
  bool _panZoomActive = false;
  bool get _hasActivePointerOrPanZoom =>
      _activePointers.isNotEmpty || _panZoomActive;
  bool _pendingBottomSnapOnPointerUp = false;
  int? _mobileAltScrollPointer;
  Offset? _mobileAltScrollLastPosition;
  bool _metricsRestoreInFlight = false;

  Timer? _resizeOutDebounceTimer;
  Timer? _scrollToCursorTimer;
  int? _pendingResizeOutCols;
  int? _pendingResizeOutRows;

  // Selection state. The view owns selection through this xterm controller; we
  // observe it to keep the live anchor (the cell a selection started from) so a
  // later shift-click can extend the range to a new cell — even after scrolling,
  // since anchors track buffer lines, not viewport rows.
  final xt.TerminalController _xtermController = xt.TerminalController(
    pointerInputs: const xt.PointerInputs.none(),
  );
  // Lets us hit-test a pointer position to a buffer cell (getCellOffset) for
  // shift-click extension. xterm 4.0.0's TerminalView.onTapUp never fires (the
  // TapGestureRecognizer only routes to the unforwarded onSingleTapUp), so we
  // drive shift-click from the Listener below instead of that dead callback.
  final GlobalKey<xt.TerminalViewState> _terminalViewKey = GlobalKey();

  // Sticky Ctrl for the on-screen accessory bar (mobile only): when armed, the
  // next single character typed from the soft keyboard is converted to its
  // control code in _onTerminalOutput, then disarmed. Mirrors how a physical
  // Ctrl key would combine with the following keystroke.
  static final Map<String, bool> _sessionBracketedPasteModes = {};
  bool _ctrlArmed = false;
  bool _isPasting = false;
  bool _isPasteDialogShowing = false;
  final MobileAutoSpaceTracker _mobileAutoSpace = MobileAutoSpaceTracker();

  // The selection the floating Copy button is offering (mobile only), or null
  // when there is none. Not a visibility flag: it stays set while the button is
  // undrawn because its text has scrolled out of view or the alternate screen
  // is up. What it gates is whether this pane rebuilds to reposition a button.
  //
  // Touch has no way to reach the copy chord `_handleTerminalKeyEvent` listens
  // for, and xterm 4.0.0 leaves `TextInputClient.showToolbar` (the callback
  // Android raises its own selection toolbar from) an empty stub, so without
  // this a phone can select text and then do nothing with it.
  //
  // Held as the range rather than a bool so the button both tracks a selection
  // that grows under the finger and disappears the moment one is cleared. It is
  // only ever a trigger for rebuilding: position and text both come from the
  // live controller, because `TerminalController.selection` recomputes its rows
  // from buffer line indices that shift as scrollback trims, without notifying.
  // A stored copy would silently de-anchor from its own highlight.
  xt.BufferRange? _copyTarget;
  // The screen buffer the offered range was taken against, mirroring the guard
  // `_extendSelectionTo` uses: `useAltBuffer` swaps the buffer without telling
  // the controller, so without this a selection made on the main screen would
  // copy whatever alt-screen cells now sit at those rows.
  Object? _copyTargetBuffer;
  // The Stack the button is positioned inside, used to convert the selection's
  // position out of the terminal's coordinate space and into the Stack's.
  final GlobalKey _copyOverlayKey = GlobalKey();
  bool _copyRebuildScheduled = false;

  xt.CellOffset? _selectionAnchor;
  // The screen buffer (main vs alternate) the anchor was recorded against.
  // Extending across a buffer switch would land on the wrong screen, so we bail.
  Object? _selectionAnchorBuffer;
  // True while we are programmatically extending, so our own selection change
  // does not overwrite the anchor (it must stay fixed across repeated extends).
  bool _extendingSelection = false;
  // In-progress shift+primary press, keyed by pointer id so concurrent pointers
  // (multi-touch) and cancelled gestures can't corrupt the click context.
  int? _shiftClickPointer;
  Offset? _shiftClickDownPosition;
  static const double _clickMoveSlop = 4.0;

  // Drag-select with edge auto-scroll. We own the drag from raw pointer events so
  // the selection start stays pinned to a buffer cell while the view scrolls
  // (xterm's built-in drag pins the start to a viewport pixel, which drifts as the
  // content scrolls). _dragAnchorCell is an absolute buffer cell (getCellOffset
  // already folds in the scroll offset). Selection is (re)applied in a microtask
  // so it deterministically overrides xterm's own per-frame selection.
  int? _dragPointer;
  Offset? _dragDownPosition;
  Offset? _dragLastPosition;
  xt.CellOffset? _dragAnchorCell;
  bool _dragSelecting = false;
  bool _dragExtendScheduled = false;
  Timer? _autoScrollTimer;
  double _autoScrollVelocity = 0;
  // Distance from the top/bottom viewport edge that triggers auto-scroll, the
  // tick cadence, and the max scroll step per tick (scaled by edge depth).
  static const double _autoScrollEdge = 28.0;
  static const Duration _autoScrollTick = Duration(milliseconds: 16);
  static const double _autoScrollMaxStep = 28.0;

  // Premium design system theme matching the web terminal
  static const _theme = xt.TerminalTheme(
    cursor: Color(0xff7fd1c7),
    selection: Color(0x3366cccc),
    foreground: Color(0xffd9e5e3),
    background: Color(0xff0d1113),
    black: Color(0xff1f2b30),
    red: Color(0xfff2777a),
    green: Color(0xff99cc99),
    yellow: Color(0xffffcc66),
    blue: Color(0xff6699cc),
    magenta: Color(0xffcc99cc),
    cyan: Color(0xff66cccc),
    white: Color(0xffd9e5e3),
    brightBlack: Color(0xff74838a),
    brightRed: Color(0xfff2777a),
    brightGreen: Color(0xff99cc99),
    brightYellow: Color(0xffffcc66),
    brightBlue: Color(0xff6699cc),
    brightMagenta: Color(0xffcc99cc),
    brightCyan: Color(0xff66cccc),
    brightWhite: Color(0xffffffff),
    searchHitBackground: Color(0x7f7fd1c7),
    searchHitBackgroundCurrent: Color(0xff7fd1c7),
    searchHitForeground: Color(0xff1f2b30),
  );
  static const _textStyle = xt.TerminalStyle(
    fontSize: 15,
    fontFamily: 'JetBrains Mono',
    fontFamilyFallback: [
      'Menlo',
      'Monaco',
      'Liberation Mono',
      'Courier New',
      'Noto Sans Mono CJK SC',
      'Noto Sans Mono CJK TC',
      'Noto Sans Mono CJK KR',
      'Noto Sans Mono CJK JP',
      'Noto Sans Mono CJK HK',
      'Noto Color Emoji',
      'Noto Sans Symbols',
      'monospace',
    ],
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final useTestFallback =
        runningUnderFlutterTest() && !TerminalPane.debugForceNativeTerminalView;
    final initialOffset =
        _sessionSavedScrollOffsets[widget.terminalId] ??
        (useTestFallback ? _kBottomScrollSentinel : 0.0);
    final savedAnchor = _sessionSavedScrollAnchors[widget.terminalId];
    if (savedAnchor != null) {
      _scrollAnchor.copyFrom(savedAnchor);
    }
    _scrollController = ScrollController(initialScrollOffset: initialOffset);
    _suppressAnchorCapture = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _suppressAnchorCapture = false;
      if (_scrollController.hasClients &&
          _scrollController.position.hasContentDimensions) {
        _lastScrollPixels = _scrollController.position.pixels;
      }
    });
    widget.onTerminalResizeBind?.call(_onTerminalResize);
    _scrollController.addListener(_onScrollChanged);
    _bindTerminal(_terminal);
    _mountedPanes[widget.terminalId] = this;
    _bindController(widget.controller);
    _xtermController.addListener(_recordSelectionAnchor);
    _xtermController.addListener(_syncCopyTarget);
    if (widget.focusCursorRevision > 0) {
      _scrollToCursor(requestFocus: true);
    }
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

  // The persistent terminal lives on SessionVm, so it can be swapped underneath
  // this State (a session swap reuses the State under the same `triage / <sid>`
  // key). Bind keyboard output through a paired seam so initState and
  // didUpdateWidget can't leave the new terminal's onOutput null.
  void _bindTerminal(xt.Terminal terminal) {
    _lastIsAltBuffer = terminal.isUsingAltBuffer;
    _altScrollDeltaAccum = 0.0;
    terminal.onOutput = _onTerminalOutput;
    terminal.addListener(_onTerminalContentChanged);
  }

  void _unbindTerminal(xt.Terminal terminal) {
    terminal.onOutput = null;
    terminal.removeListener(_onTerminalContentChanged);
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminalId != widget.terminalId) {
      if (identical(_mountedPanes[oldWidget.terminalId], this)) {
        _mountedPanes.remove(oldWidget.terminalId);
      }
    }
    _mountedPanes[widget.terminalId] = this;
    if (oldWidget.bracketedPasteEnabled != widget.bracketedPasteEnabled) {
      _sessionBracketedPasteModes[widget.terminalId] =
          widget.bracketedPasteEnabled;
      try {
        _terminal.setBracketedPasteMode(widget.bracketedPasteEnabled);
      } catch (_) {}
    }
    if (oldWidget.onTerminalResizeBind != widget.onTerminalResizeBind) {
      oldWidget.onTerminalResizeBind?.call(null);
      widget.onTerminalResizeBind?.call(_onTerminalResize);
    }
    if (!identical(oldWidget.terminal, widget.terminal) ||
        oldWidget.terminalId != widget.terminalId) {
      _clearPageAnchor();
      _pageJumpGeneration++;
      dismissNoOlderScrollback();
      if (oldWidget.terminalId != widget.terminalId) {
        _saveScrollOffset(oldWidget.terminalId);
      }
      _unbindTerminal(oldWidget.terminal);
      _bindTerminal(widget.terminal);
      // The anchor and any in-flight shift-click/drag referenced the previous
      // terminal's buffer; drop all of it so we never extend across the swap.
      _selectionAnchor = null;
      _selectionAnchorBuffer = null;
      _shiftClickPointer = null;
      _shiftClickDownPosition = null;
      // Same reason: the offered range indexed the outgoing terminal's buffer,
      // so copying it after the swap would read the wrong session's text. The
      // controller is cleared too, since its anchors still point into that
      // buffer and its next notification would otherwise re-offer the range
      // against the incoming session.
      _copyTarget = null;
      _copyTargetBuffer = null;
      _xtermController.clearSelection();
      // Restore the incoming session's scroll anchor if one was saved.
      final savedAnchor = _sessionSavedScrollAnchors[widget.terminalId];
      if (savedAnchor != null) {
        _scrollAnchor.copyFrom(savedAnchor);
      } else {
        _scrollAnchor.clear();
      }
      // A snap queued for the outgoing session must not land on this one.
      _activePointers.clear();
      _panZoomActive = false;
      _mobileAltScrollPointer = null;
      _mobileAltScrollLastPosition = null;
      // The last scroll position belongs to the outgoing terminal; a direction
      // measured against it could release the incoming session's pin on its
      // first scroll event.
      _lastScrollPixels = null;
      // Drop any latched sticky Ctrl so it can't fold into the new session's
      // first keystroke (a Ctrl armed for session A must not reach session B).
      _ctrlArmed = false;
      _mobileAutoSpace.reset();
      _endDrag();
      try {
        _terminalViewKey.currentState?.renderTerminal.terminal =
            widget.terminal;
      } catch (_) {}
      final hasSavedScroll =
          _scrollAnchor.hasAnchor ||
          _sessionSavedScrollOffsets.containsKey(widget.terminalId);
      if (_scrollController.hasClients &&
          _scrollController.position.hasContentDimensions) {
        if (!hasSavedScroll) {
          _snapToBottom(_scrollController.position);
        } else {
          _restoreSavedScrollPosition(_lineHeight() ?? 2.0);
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
      final hasSavedScroll =
          _scrollAnchor.hasAnchor ||
          _sessionSavedScrollOffsets.containsKey(widget.terminalId);
      if (_pendingBottomSnapOnPointerUp || !hasSavedScroll) {
        _pendingBottomSnapOnPointerUp = false;
        _scrollToCursor(requestFocus: false, forceBottom: !hasSavedScroll);
      }
    }
    if ((oldWidget.isObscured != widget.isObscured && widget.isObscured) ||
        (oldWidget.interactionEnabled && !widget.interactionEnabled)) {
      _activePointers.clear();
      _panZoomActive = false;
      _mobileAltScrollPointer = null;
      _mobileAltScrollLastPosition = null;
      _endDrag();
      _shiftClickPointer = null;
      _shiftClickDownPosition = null;
    }
    final sessionSwapped =
        !identical(oldWidget.terminal, widget.terminal) ||
        oldWidget.terminalId != widget.terminalId;
    if (!sessionSwapped &&
        oldWidget.focusCursorRevision != widget.focusCursorRevision) {
      final hasSavedScroll =
          _scrollAnchor.hasAnchor ||
          _sessionSavedScrollOffsets.containsKey(widget.terminalId);
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
    if (oldWidget.softKeyboardEnabled != widget.softKeyboardEnabled &&
        _isMobile) {
      // The user flipped the kill switch: drop the keyboard at once when
      // suppressing (it may be up right now), and offer it back when
      // re-enabling (the tap says they want to type).
      if (widget.softKeyboardEnabled) {
        _focusNode.requestFocus();
      } else {
        _focusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(_mountedPanes[widget.terminalId], this)) {
      _mountedPanes.remove(widget.terminalId);
    }
    widget.onTerminalResizeBind?.call(null);
    _saveScrollOffset();
    _unbindTerminal(_terminal);
    _unbindController();
    _xtermController.removeListener(_recordSelectionAnchor);
    _xtermController.removeListener(_syncCopyTarget);
    _xtermController.dispose();
    cancelNoOlderScrollbackTimer();
    _scrollController.removeListener(_onScrollChanged);
    _scrollController.dispose();
    _focusNode.dispose();
    _resizeOutDebounceTimer?.cancel();
    _scrollToCursorTimer?.cancel();
    _autoScrollTimer?.cancel();
    _clearPointerReleaseTimers();
    if (runningUnderFlutterTest()) {
      _lastWorkspaceFittedSize = null;
    }
    super.dispose();
  }

  void _onFit() {
    if (!mounted) return;
    final hasSavedScroll =
        _scrollAnchor.hasAnchor ||
        _sessionSavedScrollOffsets.containsKey(widget.terminalId);
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
    setState(() {});
    _scrollToCursor(requestFocus: false, forceBottom: isAtBottom);
  }

  void _onRefit() {
    if (!mounted) return;
    _sessionLastResizeOutCols.remove(widget.terminalId);
    _sessionLastResizeOutRows.remove(widget.terminalId);
    final hasSavedScroll =
        _scrollAnchor.hasAnchor ||
        _sessionSavedScrollOffsets.containsKey(widget.terminalId);
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
    setState(() {});
    _scrollToCursor(requestFocus: false, forceBottom: isAtBottom);
  }

  void _onClear() {
    if (!mounted) return;
    _pageJumpGeneration++;
    dismissNoOlderScrollback();
    if (_pageAnchorAt == null) {
      _scrollAnchor.clear();
      _clearSavedSessionScroll(widget.terminalId);
      _pendingBottomSnapOnPointerUp = true;
    }
  }

  void _onHistoryReplayed() {
    if (!mounted) return;
    try {
      _terminalViewKey.currentState?.renderTerminal.terminal = _terminal;
    } catch (_) {}
    // A scroll-up page replayed a wider window: re-seat the viewport on
    // the same content (old pixels plus the added rows) instead of the
    // normal bottom snap. Re-applied on the post-frame callback once
    // RenderTerminal.performLayout updates maxScrollExtent for the new rows.
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
      final lineCount = _terminal.buffer.lines.length;
      final addedLines = lineCount - anchorLines;
      if (addedLines >= 0 && lineCount > 0) {
        if (_selectionAnchor != null &&
            identical(_selectionAnchorBuffer, _terminal.buffer)) {
          _selectionAnchor = shiftCellOffsetForHistoryPage(
            offset: _selectionAnchor!,
            addedLines: addedLines,
            lineCount: lineCount,
          );
        }
        if (_dragAnchorCell != null) {
          _dragAnchorCell = shiftCellOffsetForHistoryPage(
            offset: _dragAnchorCell!,
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
            _extendingSelection = true;
            try {
              _xtermController.setSelection(
                _terminal.buffer.createAnchorFromOffset(shiftedBase),
                _terminal.buffer.createAnchorFromOffset(shiftedExtent),
              );
            } finally {
              _extendingSelection = false;
            }
          }
        }
      }
      final initialLh = _lineHeight() ?? 2.0;
      // Read before the re-seat jump below: a fruitful page moves the
      // viewport, and the barren check cares where the user was when the
      // page landed, not where the restore put them.
      final wasNearTop = _scrollController.position.pixels <= initialLh * 5;
      final jumpGeneration = ++_pageJumpGeneration;
      void applyPagedJump() {
        if (!mounted ||
            jumpGeneration != _pageJumpGeneration ||
            !_scrollController.hasClients) {
          return;
        }
        final position = _scrollController.position;
        if (!position.hasContentDimensions) return;
        final lh = _lineHeight() ?? 2.0;
        final maxExtent = _effectiveMaxScrollExtent(position);
        final target = (anchorPixels + addedLines * lh).clamp(0.0, maxExtent);
        final atBottom = target >= maxExtent - 0.5;
        _jumpPositionTo(position, target, stickToBottom: atBottom);
        _scrollAnchor.capture(
          buffer: _terminal.buffer,
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
    final hasSavedScroll =
        _scrollAnchor.hasAnchor ||
        _sessionSavedScrollOffsets.containsKey(widget.terminalId);
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

  /// Stash the scroll anchor ahead of a scroll-up page re-attach: the
  /// replay clears the buffer, so the anchor (scroll pixels + line count)
  /// is what re-seats the viewport on the same content.
  void _onHistoryPageStarted() {
    if (!mounted || !_scrollController.hasClients) return;
    _pageAnchorPixels = _scrollController.position.pixels;
    _pageAnchorLines = _terminal.buffer.lines.length;
    _pageAnchorAt = DateTime.now();
    final selection = _xtermController.selection;
    if (selection != null &&
        terminalSelectionIsLive(_terminal.buffer, selection)) {
      _pageSelectionBase = selection.begin;
      _pageSelectionExtent = selection.end;
    } else {
      _pageSelectionBase = null;
      _pageSelectionExtent = null;
    }
  }

  /// A page landed with no new buffer lines while the user is still near
  /// the top: the window was barren (a TUI redrawing in place), so ask for
  /// a deeper one instead of sitting on identical content. When no deeper
  /// window is available the scrollback is genuinely exhausted and the
  /// pill says so, rather than leaving the top silently inert.
  void _continuePastBarrenPage() {
    final terminalId = widget.terminalId;
    final terminal = widget.terminal;
    final controller = widget.controller;
    final jumpGeneration = _pageJumpGeneration;
    // Deferred: this handler runs inside the landed page's own
    // single-flight window (the replay lands before `_pageHistoryUp`
    // releases it), so a synchronous re-request would read as already in
    // flight and wrongly report exhaustion.
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

  // Remember where the current selection is anchored so a shift-click can extend
  // from it. Skipped while we are doing the extending or drag-selecting ourselves
  // so the anchor stays pinned to the original start cell instead of drifting with
  // xterm's viewport-relative drag updates.
  void _recordSelectionAnchor() {
    if (_extendingSelection || _dragSelecting) return;
    final selection = _xtermController.selection;
    if (selection != null) {
      _selectionAnchor = selection.begin;
      _selectionAnchorBuffer = _terminal.buffer;
    }
  }

  // Shift-click: extend the selection from the saved anchor to [target]. xterm
  // clears the live selection on tap-down, so we rebuild it from the anchor we
  // recorded before the click. Anchors are buffer-line based, so this is correct
  // even if the view was scrolled between the original selection and the click.
  void _extendSelectionTo(xt.CellOffset target) {
    final anchor = _selectionAnchor;
    if (anchor == null) return;
    // The anchor was recorded against a specific screen buffer; if the program
    // switched between the main and alternate screen since, extending would
    // select an unrelated region of the now-active buffer.
    if (!identical(_terminal.buffer, _selectionAnchorBuffer)) return;
    _applySelection(anchor, target);
  }

  // Set the live selection from [anchorCell] to [targetCell] (both absolute
  // buffer cells). Clamps a possibly-stale anchor into the current grid and adds
  // the +1 trailing column on the exclusive end of the half-open range so both
  // forward and backward selections include both endpoint cells.
  void _applySelection(xt.CellOffset anchorCell, xt.CellOffset targetCell) {
    final buffer = _terminal.buffer;
    final endpoints = resolveSelectionEndpoints(
      anchorCell: anchorCell,
      targetCell: targetCell,
      viewWidth: _terminal.viewWidth,
      lineCount: buffer.lines.length,
    );
    if (endpoints == null) return;
    final (base, extent) = endpoints;
    _extendingSelection = true;
    try {
      _xtermController.setSelection(
        buffer.createAnchorFromOffset(base),
        buffer.createAnchorFromOffset(extent),
      );
    } finally {
      _extendingSelection = false;
    }
  }

  // Hit-test a global pointer position to an absolute buffer cell. Returns null
  // if the view isn't mounted/laid out (renderTerminal asserts the viewport is
  // present), so callers can bail safely during a teardown/rebuild.
  xt.CellOffset? _cellAtGlobal(Offset globalPosition) {
    final state = _terminalViewKey.currentState;
    if (state == null) return null;
    try {
      final render = state.renderTerminal;
      return render.getCellOffset(render.globalToLocal(globalPosition));
    } catch (_) {
      return null;
    }
  }

  // Track a shift+primary press (keyed by pointer id) so pointer-up can tell a
  // shift-click from a drag. xterm's own tap-down clears any live selection
  // here; our anchor is preserved because _recordSelectionAnchor ignores the
  // resulting null.
  void _handlePointerDown(PointerDownEvent event) {
    if (widget.isObscured || !widget.interactionEnabled) return;
    _mobileAutoSpace.reset();
    _activePointers.add(event.pointer);
    // Desktop only: focus on pointer-down so a mouse click focuses the terminal
    // before a drag-select. On mobile this same pointer-down begins a scroll
    // swipe, and requesting focus here raises the soft keyboard mid-scroll — the
    // Scaffold then insets for the keyboard and the viewport jumps under the
    // finger. Mobile tap-to-focus is handled by the GestureDetector.onTap
    // (a real tap, not a swipe), so skip focusing on the raw pointer-down.
    if (!_isMobile) {
      _focusTerminal();
    } else if (ModalRoute.of(context)?.isCurrent != false) {
      if (_activePointers.length == 1 && _shouldForwardWheelToTerminal) {
        _mobileAltScrollPointer = event.pointer;
        _mobileAltScrollLastPosition = event.position;
        _altScrollDeltaAccum = 0.0;
      } else {
        _mobileAltScrollPointer = null;
        _mobileAltScrollLastPosition = null;
      }
    }
    if ((event.buttons & kPrimaryButton) == 0) return;
    // Touch: let the terminal's own gestures handle scrolling (a swipe) and
    // selection (long-press). The pointer-driven drag-select below is for a
    // mouse — on touch it would hijack a swipe-to-scroll into a text selection.
    if (_isMobile ||
        widget.isObscured ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      // Shift+primary: a click extends the existing selection on pointer-up.
      _shiftClickPointer = event.pointer;
      _shiftClickDownPosition = event.position;
    } else {
      // Plain primary: a potential drag-select. The anchor is the cell under the
      // press; we don't start selecting until the pointer moves past the slop.
      // If we can't resolve the anchor cell (view not laid out / mid-rebuild),
      // don't own the drag — let xterm handle it rather than auto-scrolling with
      // no pinned start (which would let the built-in selection drift).
      final anchor = _cellAtGlobal(event.position);
      if (anchor == null) return;
      _dragPointer = event.pointer;
      _dragDownPosition = event.position;
      _dragLastPosition = event.position;
      _dragAnchorCell = anchor;
      _dragSelecting = false;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
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

  // Shift-click (a click, not a drag) extends the selection to the clicked cell.
  // Done from raw pointer events because TerminalView.onTapUp is dead in xterm
  // 4.0.0; raw pointer handling also sidesteps the gesture arena, so normal
  // drag-select keeps working.
  final List<Timer> _pointerReleaseTimers = [];

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
                !_hasActivePointerOrPanZoom &&
                !_scrollAnchor.hasAnchor &&
                !_sessionSavedScrollOffsets.containsKey(widget.terminalId)) {
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
    if (event.pointer == _dragPointer) {
      final wasDragSelecting = _dragSelecting;
      final anchor = _dragAnchorCell;
      final endPosition = event.position;
      final buffer = _terminal.buffer;
      _endDrag();
      if (wasDragSelecting && anchor != null) {
        _applyDragSelectionAt(anchor, endPosition);
        // Also re-apply in a microtask so any gesture-arena callbacks fired by
        // xterm's PanGestureRecognizer during pointer-up cannot overwrite the
        // pinned selection with a viewport-relative range.
        scheduleMicrotask(() {
          if (!mounted || !identical(_terminal.buffer, buffer)) return;
          _applyDragSelectionAt(anchor, endPosition);
        });
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

  bool _lastIsAltBuffer = false;
  double _altScrollDeltaAccum = 0.0;

  bool get _shouldForwardWheelToTerminal {
    if (_terminal.isUsingAltBuffer) return true;
    if (_terminal.mouseMode == xt.MouseMode.none) return false;
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return !pos.hasContentDimensions || pos.maxScrollExtent <= 0;
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!widget.interactionEnabled) return;
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
    if (!widget.interactionEnabled) return;
    _panZoomActive = true;
    _altScrollDeltaAccum = 0.0;
  }

  void _handlePointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (!widget.interactionEnabled) return;
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

    final rawCell = _cellAtGlobal(globalPosition) ?? const xt.CellOffset(0, 0);
    final maxCol = (_terminal.viewWidth - 1).clamp(0, 10000);
    final maxRow = (_terminal.viewHeight - 1).clamp(0, 10000);
    final cell = xt.CellOffset(
      rawCell.x.clamp(0, maxCol),
      rawCell.y.clamp(0, maxRow),
    );
    final up = steps < 0;
    final count = steps.abs().clamp(1, 10);
    widget.controller.notifyInteraction();
    for (var i = 0; i < count; i++) {
      _sendWheelStep(up, cell);
    }
  }

  void _sendWheelStep(bool up, xt.CellOffset cell) {
    if (_terminal.mouseMode.reportScroll) {
      // xterm.dart's TerminalMouseButton.wheelUp/wheelDown encode 68/69
      // (64 + 4/5, which sets the Shift modifier bit in XTerm mouse reporting)
      // instead of 64/65. Emit the standard unshifted wheel IDs directly so
      // TUIs (Claude Code, tmux, nvim, less) recognize wheel scroll events.
      final buttonId = up ? 64 : 65;
      final x = cell.x + 1;
      final y = cell.y + 1;
      final String report;
      switch (_terminal.mouseReportMode) {
        case xt.MouseReportMode.sgr:
          report = '\x1b[<$buttonId;$x;${y}M';
        case xt.MouseReportMode.urxvt:
          report = '\x1b[${32 + buttonId};$x;${y}M';
        case xt.MouseReportMode.normal:
        case xt.MouseReportMode.utf:
          final maxCoord =
              _terminal.mouseReportMode == xt.MouseReportMode.normal
              ? 223
              : 2015;
          final col = x <= maxCoord ? String.fromCharCode(32 + x) : '\x00';
          final row = y <= maxCoord ? String.fromCharCode(32 + y) : '\x00';
          report = '\x1b[M${String.fromCharCode(32 + buttonId)}$col$row';
      }
      widget.controller.sendInput(report);
      return;
    }
    _terminal.keyInput(up ? xt.TerminalKey.arrowUp : xt.TerminalKey.arrowDown);
  }

  void _endDrag() {
    _stopAutoScroll();
    // Auto-scroll moved the viewport while _onScrollChanged was short-circuited
    // on _dragSelecting, so the offset from before the drag is no longer a
    // previous *user* position. Record the resting offset after the drag so a
    // subsequent scroll event measures its delta from where the drag ended.
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

  // Apply the drag selection (anchor -> current pointer cell) in a microtask, so
  // it runs after xterm's own onDragUpdate within the same frame and wins. Deduped
  // so multiple moves/ticks in one frame collapse to a single apply.
  void _scheduleDragExtend() {
    if (_dragExtendScheduled) return;
    _dragExtendScheduled = true;
    scheduleMicrotask(() {
      _dragExtendScheduled = false;
      _applyDragExtend();
    });
  }

  void _applyDragExtend() {
    // The microtask or auto-scroll tick can fire after this State is disposed;
    // touching _xtermController then (post-dispose) would throw.
    if (!mounted) return;
    if (!_dragSelecting) return;
    final anchor = _dragAnchorCell;
    final position = _dragLastPosition;
    if (anchor == null || position == null) return;
    _applyDragSelectionAt(anchor, position);
  }

  void _applyDragSelectionAt(xt.CellOffset anchor, Offset globalPosition) {
    final target = _cellAtGlobal(globalPosition);
    if (target == null) return;
    _applySelection(anchor, target);
    // Keep the shift-click anchor in sync so a later shift-click extends from the
    // drag's start, against the current buffer.
    _selectionAnchor = anchor;
    _selectionAnchorBuffer = _terminal.buffer;
  }

  // Set the auto-scroll velocity from how deep [globalPosition] is into the top or
  // bottom edge zone, starting/stopping the ticker as needed.
  void _updateAutoScroll(Offset globalPosition) {
    final state = _terminalViewKey.currentState;
    double velocity = 0;
    if (state != null) {
      try {
        final render = state.renderTerminal;
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
    // Re-extend at the (unchanged) pointer position against the new scroll
    // offset so the selection grows as content scrolls under the held pointer.
    _applyDragExtend();
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollVelocity = 0;
  }

  void _onTerminalOutput(String data) {
    // Automated emulator responses (such as Cursor Position Report \x1b[...R,
    // Device Attributes \x1b[?...c, Operating Status \x1b[0n, window size \x1b[8;...t)
    // are replies to host queries, not user typing. The daemon's own terminal
    // emulator already answers PTY queries on the host side, so drop client-side
    // auto-responses instead of echoing them into the session as fake input.
    if (isEmulatorQueryResponse(data)) {
      return;
    }
    if (!mounted || widget.isExited || !_isRouteCurrentAndUnobscured) {
      return;
    }

    // Mouse report sequences (clicks, drags, wheel scroll in mouse-tracking
    // TUIs) are pointer interactions, not keyboard typing: forward them without
    // clearing saved scroll or snapping the scroll view to the bottom.
    if (isTerminalMouseReport(data)) {
      final normalized = data
          .replaceAll('\x1b[<68;', '\x1b[<64;')
          .replaceAll('\x1b[<69;', '\x1b[<65;')
          .replaceAll('\x1b[<70;', '\x1b[<66;')
          .replaceAll('\x1b[<71;', '\x1b[<67;');
      widget.controller.sendInput(normalized);
      return;
    }

    _clearSavedSessionScroll(widget.terminalId);
    _scrollAnchor.clear();
    if (_scrollController.hasClients) {
      _snapToBottom(_scrollController.position);
    }
    // Sticky Ctrl (accessory bar): fold the armed Ctrl into the next single
    // character before it reaches the session, so e.g. arming Ctrl then typing
    // "c" on the soft keyboard sends 0x03 (SIGINT) instead of a literal "c".
    if (_ctrlArmed) {
      _mobileAutoSpace.reset();
      // Disarm on the very next chunk regardless of its length; only fold Ctrl
      // into a lone character. A multi-character IME chunk (paste, suggestion
      // commit) still consumes the armed Ctrl (untransformed) so a latched
      // Ctrl can never linger into a later keystroke.
      final ctrl = data.length == 1 ? controlByteForChar(data) : null;
      _disarmCtrl();
      if (ctrl != null) {
        widget.controller.sendInput(ctrl);
        return;
      }
    }
    // Multi-line IME text input (such as pasting from soft keyboard clipboard chips
    // or Gboard on mobile). Intercept so multi-line text is formatted with bracketed
    // paste or verified with the confirmation dialog rather than executing line by line.
    if (data.length > 1 && isMultiLine(data) && data != '\r\n') {
      _mobileAutoSpace.reset();
      unawaited(_handlePaste(data));
      return;
    }
    final effectiveData = _isMobile
        ? _mobileAutoSpace.processInput(data)
        : data;
    widget.controller.sendInput(effectiveData);
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

  // Send a raw byte sequence from an accessory-bar key. Ctrl+<letter> keys pass
  // the already-encoded control byte; a bare Ctrl toggle arms _ctrlArmed instead
  // of sending anything. Does not request focus so tapping shortcuts does not
  // pop open the soft keyboard.
  void _sendAccessory(String bytes) {
    if (!mounted || widget.isExited || !_isRouteCurrentAndUnobscured) return;
    widget.controller.sendInput(bytes);
    _disarmCtrl();
    _mobileAutoSpace.reset();
  }

  void _toggleCtrl() {
    if (!mounted || widget.isExited || !_isRouteCurrentAndUnobscured) return;
    if (_ctrlArmed) {
      _disarmCtrl();
    } else {
      _armCtrl();
    }
  }

  void _focusTerminal() {
    widget.controller.notifyInteraction();
    _requestTerminalFocus();
  }

  bool get _isRouteCurrentAndUnobscured {
    if (!mounted || widget.isObscured || !widget.interactionEnabled) {
      return false;
    }
    return ModalRoute.of(context)?.isCurrent != false;
  }

  /// Whether this pane may take keyboard focus right now. On mobile with the
  /// soft keyboard suppressed, focusing would raise the keyboard (or, with the
  /// IME path closed, focus a terminal the user cannot type into), so every
  /// focus request funnels through here. Desktop always passes: focusing
  /// never raises a keyboard there.
  bool get _mayTakeFocus =>
      (!_isMobile || widget.softKeyboardEnabled) &&
      _isRouteCurrentAndUnobscured;

  void _requestTerminalFocus() {
    if (_mayTakeFocus) _focusNode.requestFocus();
  }

  // The TerminalView auto-fits and calls this when the grid size changes. We
  // forward the settled size to the host (debounced); the program repaints and
  // the live byte stream renders the new layout. No replay here.
  void _onTerminalResize(
    int width,
    int height,
    int pixelWidth,
    int pixelHeight,
  ) {
    if (width > 0 && height > 0) {
      final sanitizedId = widget.terminalId.replaceAll(
        RegExp(r'[^a-zA-Z0-9-]'),
        '_',
      );
      _sessionLastGridSize[sanitizedId] = (height, width);
      _sessionLastGridSize[widget.terminalId] = (height, width);
      _lastWorkspaceFittedSize = (height, width);
      // Reflow (reflowEnabled is on) runs only on a column change, moving content
      // between rows and staling the cached shift-click anchor — a buffer
      // coordinate the identity guard in _extendSelectionTo can't detect as stale,
      // since reflow mutates lines within the same Buffer object. Drop it on a
      // width change so a later shift-click won't extend from a pre-reflow row
      // (with no anchor the extend is a no-op until the next fresh select). A
      // height-only resize doesn't reflow, so the anchor stays valid and is left
      // alone. `viewWidth` is still the old width here: onResize fires before the
      // terminal stores the new one. The live highlight is unaffected; only the
      // extend-from point is invalidated.
      if (width != _terminal.viewWidth) {
        _selectionAnchor = null;
        _selectionAnchorBuffer = null;
      }
      final lh = _lineHeight() ?? 2.0;
      final pos = _scrollController.hasClients
          ? _scrollController.position
          : null;
      final hasSavedScroll =
          _scrollAnchor.hasAnchor ||
          _sessionSavedScrollOffsets.containsKey(widget.terminalId);
      final isAtBottom =
          (pos == null || !pos.hasContentDimensions || pos.maxScrollExtent <= 0)
          ? !hasSavedScroll
          : pos.pixels >= pos.maxScrollExtent - 0.5;
      if (isAtBottom && !_metricsRestoreInFlight) {
        _scrollAnchor.clear();
        _clearSavedSessionScroll(widget.terminalId);
        if (_scrollController.hasClients) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scrollController.hasClients) {
              _snapToBottom(_scrollController.position);
            }
          });
        }
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollController.hasClients) {
            _restoreSavedScrollPosition(lh);
          }
        });
      }
      // This fires from inside RenderTerminal.performLayout (the view auto-fits
      // by calling terminal.resize). Replaying history writes to the terminal,
      // which would mark the render object dirty during its own layout: illegal.
      // Defer out of the layout pass via a microtask so the write lands after
      // layout completes (the terminal is already at the fitted size by then).
      scheduleMicrotask(() {
        if (mounted) {
          widget.onViewFit?.call(width, height);
        }
      });
      _scheduleResizeOut(width, height);
    }
  }

  void _scheduleResizeOut(int cols, int rows) {
    if (_sessionLastResizeOutCols[widget.terminalId] == cols &&
        _sessionLastResizeOutRows[widget.terminalId] == rows) {
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
      if (mounted && pendingCols != null && pendingRows != null) {
        _sendResizeOutNow(pendingCols, pendingRows);
      }
    });
  }

  void _sendResizeOutNow(int cols, int rows) {
    _resizeOutDebounceTimer?.cancel();
    _pendingResizeOutCols = null;
    _pendingResizeOutRows = null;
    final sanitizedId = widget.terminalId.replaceAll(
      RegExp(r'[^a-zA-Z0-9-]'),
      '_',
    );
    _sessionLastGridSize[sanitizedId] = (rows, cols);
    _sessionLastGridSize[widget.terminalId] = (rows, cols);
    if (_sessionLastResizeOutCols[widget.terminalId] == cols &&
        _sessionLastResizeOutRows[widget.terminalId] == rows) {
      return;
    }
    _sessionLastResizeOutCols[widget.terminalId] = cols;
    _sessionLastResizeOutRows[widget.terminalId] = rows;
    widget.controller.sendResizeOut(cols, rows);
  }

  // --- Scroll anchoring: keep the viewport stable across scrollback trims ---

  /// Height of one rendered terminal line in pixels, falling back to style metrics
  /// if the view isn't laid out yet or runs in a headless test. Always returns a
  /// finite positive double.
  double? _lineHeight() {
    final state = _terminalViewKey.currentState;
    if (state != null) {
      try {
        final lh = state.renderTerminal.lineHeight;
        if (lh > 0) return lh;
      } catch (_) {}
    }
    return _textStyle.fontSize * 1.2;
  }

  /// Returns the live maximum scroll extent for `_terminal` when `xt.TerminalView`
  /// is mounted and sized, matching `RenderTerminal._maxScrollExtent` even before
  /// the next `performLayout` updates [ScrollPosition.maxScrollExtent]. Falls back
  /// to `position.maxScrollExtent` in the headless test scroll view.
  double _effectiveMaxScrollExtent(ScrollPosition position) {
    final state = _terminalViewKey.currentState;
    if (state != null) {
      try {
        final render = state.renderTerminal;
        if (render.hasSize) {
          final lh = render.lineHeight;
          if (lh > 0) {
            return max(
              _terminal.buffer.lines.length * lh - render.size.height,
              0.0,
            );
          }
        }
      } catch (_) {}
    }
    return position.maxScrollExtent;
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    final hasSavedScroll =
        _scrollAnchor.hasAnchor ||
        _sessionSavedScrollOffsets.containsKey(widget.terminalId);
    if (!hasSavedScroll) return;
    // package:xterm's KeyboardVisibilty observer calls TerminalView._onKeyboardShow
    // on every positive bottomInset change, registering a postFrameCallback that
    // jumps the shared ScrollPosition to maxScrollExtent. Suppress anchor capture
    // across that callback and re-apply the saved scroll position immediately after
    // it within the same post-frame pass so keyboard/metric animations cannot wipe
    // out a scrolled-up reading position.
    _metricsRestoreInFlight = true;
    scheduleMicrotask(() {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _metricsRestoreInFlight = false;
        if (!mounted || !_scrollController.hasClients) return;
        _restoreSavedScrollPosition(_lineHeight() ?? 2.0);
      });
    });
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
      _jumpPositionTo(
        p,
        atBottom ? maxExtent : target,
        stickToBottom: atBottom,
      );
    }
  }

  // The user scrolled: pin to the buffer line at the top of the viewport, or
  // clear the anchor when at the bottom so xterm.dart's stick-to-bottom follows
  // new output. Ignored for our own corrections and during drag-select.
  void _onScrollChanged() {
    // Reposition the copy button against the new scroll offset so it stays with
    // its text; _buildCopyButton drops it once the selection leaves the
    // viewport. Gated on a selection existing, so scrolling with none (the
    // usual case) costs nothing.
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
    // Near the top of the loaded scrollback: ask for older history.
    // Paging coalesces in the session (single-flight + log-start stop),
    // so repeats while a page is in flight are cheap; our own programmatic
    // jumps return at the gate above and never retrigger.
    final lh = _lineHeight() ?? 2.0;
    final movedUp =
        (previousPixels != null && position.pixels < previousPixels - 0.5) ||
        _hasActivePointerOrPanZoom ||
        position.userScrollDirection == ScrollDirection.forward;
    if (movedUp &&
        position.pixels <= lh * 5 &&
        position.pixels < position.maxScrollExtent - 0.5) {
      widget.onNearTop?.call();
    }
  }

  void _saveScrollOffset([
    String? terminalId,
    double? lineHeight,
    double? maxScrollExtentOverride,
  ]) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final maxExtent = maxScrollExtentOverride ?? position.maxScrollExtent;
    if (!position.hasContentDimensions || maxExtent <= 0) return;
    final id = terminalId ?? widget.terminalId;
    final isAtBottom = position.pixels >= maxExtent - 0.5;
    if (!isAtBottom) {
      final clampedPixels = position.pixels.clamp(0.0, maxExtent);
      _sessionSavedScrollOffsets[id] = clampedPixels;
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
        // The user is chasing live output and nearly there. Dropping the pin
        // is what stops the treadmill, and is the whole fix; the snap only
        // saves them the last line or two.
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
          // Nothing is in flight, so jumpTo cannot tear down a gesture. When
          // something is, the pin is already off and the user's own movement
          // finishes the trip, which is why this needs no deferral.
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
        // Retain pending snap and suppress capture while stationary in grace band without reversing upward.
        _lastScrollPixels = position.pixels;
        return;
      } else {
        _pendingBottomSnapOnPointerUp = false;
        _scrollAnchor.capture(
          buffer: _terminal.buffer,
          pixels: position.pixels,
          maxScrollExtent: position.maxScrollExtent,
          lineHeight: lineHeight,
        );
      }
    }
    // Tracked on every scroll event, laid out or not: skipping it while the
    // line height is unmeasurable would leave the next event measuring
    // direction across the gap and reading one large jump as a bottom chase.
    _lastScrollPixels = position.pixels;
    _saveScrollOffset(widget.terminalId, lineHeight);
  }

  void _jumpPositionTo(
    ScrollPosition position,
    double target, {
    required bool stickToBottom,
  }) {
    if (!position.hasContentDimensions) return;
    final render = _terminalViewKey.currentState?.renderTerminal;
    if (render != null) {
      try {
        render.terminal = _terminal;
      } catch (_) {}
    }
    final layoutMaxExtent = position.maxScrollExtent;
    final effectiveMaxExtent = _effectiveMaxScrollExtent(position);
    // Suppressed like our own re-pin correction so the jump's notification
    // cannot re-capture an anchor from it. Saved and restored rather than
    // forced false, so a nested call cannot clear an outer suppressed region.
    final wasSuppressed = _suppressAnchorCapture;
    _suppressAnchorCapture = true;
    try {
      // RenderTerminal._onScroll sets `_stickToBottom = _scrollOffset >=
      // _maxScrollExtent - 0.5` against the last laid-out `_maxScrollExtent`
      // (`position.maxScrollExtent`), and `ScrollPosition.jumpTo` skips
      // `notifyListeners` when `pixels == value`. Drive `_onScroll` at an
      // offset that puts `_stickToBottom` in the desired state against
      // `layoutMaxExtent`, then settle `pixels` at `target` via `correctPixels`
      // without firing a second notification against a pre-layout extent.
      if (stickToBottom) {
        if (layoutMaxExtent > 0) {
          final notifyTarget = max(target, layoutMaxExtent);
          if ((position.pixels - notifyTarget).abs() < 1e-6) {
            position.correctPixels(notifyTarget - 0.01);
          }
          position.jumpTo(notifyTarget);
          if ((position.pixels - target).abs() > 1e-6) {
            position.correctPixels(target);
          }
        } else {
          if (target > 0 && (position.pixels - target).abs() < 1e-6) {
            position.correctPixels(target - 0.01);
          }
          position.jumpTo(target);
        }
      } else {
        if (layoutMaxExtent > 0) {
          final unstickTarget = min(target, layoutMaxExtent - 1.0);
          if ((position.pixels - unstickTarget).abs() < 1e-6) {
            position.correctPixels(unstickTarget + 0.01);
          }
          position.jumpTo(unstickTarget);
          if ((position.pixels - target).abs() > 1e-6) {
            position.correctPixels(target);
          }
        } else {
          position.jumpTo(target);
        }
      }
      if ((effectiveMaxExtent - layoutMaxExtent).abs() > 0.5) {
        render?.markNeedsLayout();
      }
    } finally {
      _suppressAnchorCapture = wasSuppressed;
      // Read the offset back rather than assuming the target: jumpTo can throw
      // on a transient scroll-range issue, and recording an offset we never
      // reached would make the next event measure a fake delta.
      _lastScrollPixels = position.pixels;
    }
  }

  void _snapToBottom(ScrollPosition position) {
    if (!position.hasContentDimensions) return;
    final target = _effectiveMaxScrollExtent(position);
    _jumpPositionTo(position, target, stickToBottom: true);
    // Saving at the bottom retires this session's stored offset and anchor, so
    // a later revisit follows live output instead of being pulled back to the
    // position the user just scrolled away from.
    _clearSavedSessionScroll(widget.terminalId);
    _saveScrollOffset(widget.terminalId, _lineHeight(), target);
  }

  void _onTerminalContentChanged() {
    if (_terminal.isUsingAltBuffer != _lastIsAltBuffer) {
      _lastIsAltBuffer = _terminal.isUsingAltBuffer;
      _altScrollDeltaAccum = 0.0;
      _rebuildForCopyButton();
    }
    // Reposition the copy button as content arrives. The scroll listener alone
    // is not enough: xterm's stick-to-bottom runs through `correctBy` during
    // layout, which moves the viewport without notifying the ScrollController,
    // so output growth (the common case) would otherwise never reposition the
    // button or hide it once its text scrolled away.
    if (_copyTarget != null) {
      // A selection can also go away *without* notifying: trimming its anchor
      // line out of scrollback detaches the anchor, so the controller starts
      // returning null with no event and nothing would ever retire the target.
      //
      // Tested against the controller rather than `_liveCopySelection`, which
      // is also false while the alternate screen is up. That is a temporary
      // condition, not a dead selection: `useAltBuffer`/`useMainBuffer` swap
      // between two fixed buffer objects, so a selection made on the main
      // screen matches `_copyTargetBuffer` again once a full-screen program
      // exits. Retiring on the swap would leave its highlight painted with no
      // way to copy it, which is the failure this whole change exists to fix.
      final selection = _xtermController.selection;
      if (selection == null || selection.isCollapsed) {
        _copyTarget = null;
        _copyTargetBuffer = null;
        _rebuildForCopyButton();
      } else if (identical(_terminal.buffer, _copyTargetBuffer)) {
        if (terminalSelectionIsLive(_terminal.buffer, selection)) {
          _rebuildForCopyButton();
        } else {
          // The text was cleared out from under the selection, which xterm
          // leaves us to notice: it drops those lines without detaching them,
          // so the controller keeps offering a range over rows that are gone.
          // Clearing takes the stale highlight with it, and re-enters
          // `_syncCopyTarget`, which retires the target and rebuilds.
          _xtermController.clearSelection();
        }
      }
      // The remaining case is a live selection belonging to the screen that is
      // not currently shown. Nothing to draw, so no rebuild: a full-screen
      // program writes on every frame, and the offered selection sits on the
      // other buffer where it can never be trimmed, so rebuilding here would
      // run for as long as the program does. Nothing to retire either, since
      // the selection is still live and its screen may come back.
    }
    final hasSavedScroll =
        _scrollAnchor.hasAnchor ||
        _sessionSavedScrollOffsets.containsKey(widget.terminalId);
    if (!hasSavedScroll) {
      // When a short session (`maxScrollExtent <= 0`) first grows past the
      // viewport height, `RenderTerminal._stickToBottom` can still be `false`
      // from an earlier scrolled-up session because `RenderTerminal._onScroll`
      // ignores notifications while `_maxScrollExtent == 0`. Snap to the live
      // bottom extent so `RenderTerminal._stickToBottom` is restored to `true`.
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
              !_scrollController.hasClients ||
              _scrollAnchor.hasAnchor ||
              _sessionSavedScrollOffsets.containsKey(widget.terminalId) ||
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
    // Re-pin after xterm.dart's layout has applied the new content dimensions;
    // coalesce bursts of writes into one correction per frame.
    if (_repinScheduled) return;
    _repinScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _repinScheduled = false;
      _repinScrollAnchor();
    });
  }

  // Re-pin the viewport to the anchored buffer line. As lines trim off the top
  // the line's `index` drops, so jumping to `index * lineHeight` cancels the
  // drift that would otherwise scroll the user's content out from under them.
  void _repinScrollAnchor() {
    if (!mounted || !_scrollController.hasClients) return;
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
    if (desired == null || desired < 0.0) return;
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
      // Restored rather than forced false, so a nested correction cannot clear
      // an outer suppressed region. Runs even if jumpTo throws on a transient
      // scroll-range issue, so user scrolls keep capturing either way.
      _suppressAnchorCapture = wasSuppressed;
      _lastScrollPixels = position.pixels;
    }
  }

  void _scrollToCursor({required bool requestFocus, bool forceBottom = false}) {
    final scrollGen = ++_scrollToCursorGeneration;
    var retriesLeft = 8;
    void jump() {
      if (!mounted || scrollGen != _scrollToCursorGeneration) return;
      if (_scrollController.hasClients) {
        final position = _scrollController.position;
        final maxExtent = _effectiveMaxScrollExtent(position);
        if (!position.hasContentDimensions || maxExtent <= 0) {
          if (_terminal.buffer.lines.length > _terminal.viewHeight &&
              retriesLeft > 0) {
            retriesLeft--;
            _terminalViewKey.currentState?.renderTerminal.markNeedsLayout();
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
        final saved = _sessionSavedScrollOffsets[widget.terminalId];
        final savedDistance =
            _sessionSavedDistanceFromBottom[widget.terminalId];
        final savedFraction = _sessionSavedScrollFractions[widget.terminalId];
        final lineHeight = _lineHeight();
        final wasScrolledUp =
            !forceBottom &&
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

  // xterm.dart copies selected text via BufferLine.getText, which drops every
  // blank (codePoint 0) cell: so columns a TUI lays out by moving the cursor
  // (rather than writing literal spaces) concatenate on copy. Intercept the
  // copy chord before xterm's shortcut manager runs (TerminalView.onKeyEvent
  // short-circuits it when we return a non-ignored result) and rebuild the text
  // with the gap spaces restored. Returning `ignored` for everything else
  // leaves xterm's normal key handling, including Ctrl+C -> SIGINT, untouched.
  KeyEventResult _handleTerminalKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isRouteCurrentAndUnobscured) {
      return KeyEventResult.handled;
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
        widget.controller.notifyInteraction();
        _clearSavedSessionScroll(widget.terminalId);
        _scrollAnchor.clear();
        if (_scrollController.hasClients &&
            _scrollController.position.hasContentDimensions) {
          try {
            _snapToBottom(_scrollController.position);
          } catch (_) {}
        }
        final shiftKey = keyboard.isShiftPressed;
        widget.controller.sendInput(shiftKey ? '\x1b[Z' : '\t');
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return widget.isExited ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if ((event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !widget.isExited) {
      // Shift+Enter inserts a newline (LF) instead of submitting (CR);
      // anything else falls through to xterm's default handling below.
      final keys = HardwareKeyboard.instance;
      final bytes = bytesForEnterKey(
        shift: keys.isShiftPressed,
        ctrl: keys.isControlPressed,
        alt: keys.isAltPressed,
        meta: keys.isMetaPressed,
      );
      if (bytes != null) {
        widget.controller.notifyInteraction();
        widget.controller.sendInput(bytes);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC && _isCopyChord()) {
      // Nothing selected (or nothing in it) leaves xterm's own handling in place.
      if (_copySelectionToClipboard()) return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyA && _isSelectAllChord()) {
      final lastRow = _terminal.buffer.lines.length - 1;
      if (lastRow >= 0 && _terminal.viewWidth > 0) {
        _applySelection(
          const xt.CellOffset(0, 0),
          xt.CellOffset(_terminal.viewWidth - 1, lastRow),
        );
        _selectionAnchor = const xt.CellOffset(0, 0);
        _selectionAnchorBuffer = _terminal.buffer;
      }
      return KeyEventResult.handled;
    }
    if (widget.isExited) {
      return KeyEventResult.handled;
    }
    if (_isPasteChord(event)) {
      unawaited(_pasteFromClipboard());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // Track what the floating Copy button should offer. The collapsed check is
  // defensive: on touch, selections come from xterm's `selectWord`, which never
  // produces an empty range, and a tap clears the selection outright rather
  // than leaving a caret. It costs nothing and keeps the invariant local.
  void _syncCopyTarget() {
    if (!_isMobile) return;
    final selection = _xtermController.selection;
    final next = (selection == null || selection.isCollapsed)
        ? null
        : selection;
    final nextBuffer = next == null ? null : _terminal.buffer;
    // BufferRange defines ==, and a drag re-sets the selection on every pointer
    // move, most of which stay within the same cell; skipping those rebuilds
    // nothing. The buffer is part of the comparison so a range that happens to
    // match one made on the other screen still refreshes the guard below.
    if (next == _copyTarget && identical(nextBuffer, _copyTargetBuffer)) return;
    _copyTarget = next;
    _copyTargetBuffer = nextBuffer;
    _rebuildForCopyButton();
  }

  /// The selection the button may act on, or null when there is none to offer.
  ///
  /// Read live rather than from `_copyTarget` so a trimmed scrollback moves the
  /// button with its text, and so a selection the controller has dropped (its
  /// anchor line trimmed away) takes the button with it instead of leaving a
  /// button whose tap would do nothing.
  ///
  /// The buffer identity check is what keeps a selection to its own screen: it
  /// is why the button disappears while a full-screen program is up and returns
  /// when that program exits. `_onTerminalContentChanged` deliberately does not
  /// use this getter for retirement, because "not showing" and "gone" differ.
  xt.BufferRange? get _liveCopySelection {
    if (_copyTarget == null) return null;
    if (!identical(_terminal.buffer, _copyTargetBuffer)) return null;
    final selection = _xtermController.selection;
    if (selection == null || selection.isCollapsed) return null;
    if (!terminalSelectionIsLive(_terminal.buffer, selection)) return null;
    return selection;
  }

  // Rebuild to show, move, or drop the copy button.
  //
  // The known in-frame caller is this file's own `didUpdateWidget`, which
  // clears the controller's selection on a session swap and so re-enters
  // `_syncCopyTarget` synchronously while the tree is being rebuilt. `setState`
  // throws in that phase, so defer to after the frame. Written as a phase check
  // rather than a special case at that one call site because the other two
  // triggers are notifications from xterm and from the scroll position, neither
  // of which promises which phase it fires in.
  void _rebuildForCopyButton() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // Latched so re-entry within one frame schedules a single rebuild. In
      // practice that is the `didUpdateWidget` path above; writes arrive from
      // the event loop with the scheduler idle and take the direct branch.
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

  // Copy the current selection, reporting whether there was anything to copy.
  //
  // The single copy path for both the chord and the floating button, so the
  // text they produce cannot drift: both go through terminalSelectionText,
  // which restores the blank cells xterm's own getText drops, and both clear
  // the selection afterwards as the confirmation.
  //
  // Callers own their own preconditions. The button checks that the selection
  // still belongs to the screen on show; the chord does not, matching what it
  // did before this button existed.
  bool _copySelectionToClipboard() {
    final selection = _xtermController.selection;
    if (selection == null) return false;
    final text = terminalSelectionText(_terminal.buffer, selection);
    if (text.isEmpty) return false;
    // Fire-and-forget: the chord's handler is synchronous, so detach the
    // clipboard write rather than leaving a dangling future.
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _xtermController.clearSelection();
    return true;
  }

  // The floating Copy button, or null when there is nothing to offer or the
  // geometry is not yet readable. See placeCopyButton for where it lands: above
  // the selection's first visible line where there is room, below it otherwise.
  //
  // Positioned from the same render object the pointer code hit-tests through:
  // `getOffset` is the inverse of the `getCellOffset` used there and is likewise
  // scroll-aware, so the button tracks its text as the viewport scrolls.
  Widget? _buildCopyButton() {
    final selection = _liveCopySelection;
    if (selection == null) return null;
    final viewState = _terminalViewKey.currentState;
    final overlayBox =
        _copyOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewState == null || overlayBox == null || !overlayBox.hasSize) {
      return null;
    }

    final Offset anchor;
    final double selectionBottom;
    final double lineHeight;
    try {
      final render = viewState.renderTerminal;
      final normalized = selection.normalized;
      lineHeight = render.lineHeight;
      anchor = overlayBox.globalToLocal(
        render.localToGlobal(render.getOffset(normalized.begin)),
      );
      // The bottom of the last selected line, so a selection whose start has
      // scrolled away is still recognised as partly on screen.
      final end = overlayBox.globalToLocal(
        render.localToGlobal(render.getOffset(normalized.end)),
      );
      selectionBottom = end.dy + lineHeight;
    } catch (_) {
      // Same guard as _cellAtGlobal: mid-rebuild or before layout the render
      // object is not readable, and a frame without the button beats throwing.
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
        // Re-checked at tap time, not just at placement: the button is drawn a
        // frame before it can be pressed, and a program switching to the
        // alternate screen in that gap would otherwise copy main-screen rows
        // out of the alt screen.
        onCopy: () {
          if (_liveCopySelection == null) return;
          _copySelectionToClipboard();
        },
      ),
    );
  }

  // Platform primary terminal shortcut modifiers: Cmd+<Key> on macOS/iOS,
  // Ctrl+Shift+<Key> elsewhere so plain Ctrl+C (SIGINT) and Ctrl+A (0x01 /
  // start-of-line in shells and readline) still reach the PTY.
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

  // The platform paste chord, matching terminal emulator conventions across
  // platforms: Cmd+V on macOS/iOS, Ctrl+Shift+V / Shift+Insert elsewhere so plain
  // Ctrl+V (0x16 / LNEXT / Vim visual block) still reaches the program.
  bool _isPasteChord(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    // Shift+Insert (Universal across Linux/Windows/X11)
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
        // Linux / BSD: Ctrl+Shift+V
        return keys.isControlPressed &&
            keys.isShiftPressed &&
            !keys.isMetaPressed &&
            !keys.isAltPressed;
    }
  }

  bool _isBracketedPasteEnabled() {
    return widget.bracketedPasteEnabled ||
        (_sessionBracketedPasteModes[widget.terminalId] ?? false) ||
        _terminal.bracketedPasteMode;
  }

  Future<void> _handlePaste(String text) async {
    if (!mounted ||
        text.isEmpty ||
        widget.isExited ||
        !_isRouteCurrentAndUnobscured) {
      return;
    }
    final isBracketed = _isBracketedPasteEnabled();
    if (isBracketed || !isMultiLine(text)) {
      final formatted = formatPasteInput(text, isBracketed);
      widget.controller.sendInput(formatted);
      _xtermController.clearSelection();
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
        final formatted = formatPasteInput(chosenText, false);
        widget.controller.sendInput(formatted);
        _xtermController.clearSelection();
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
        _xtermController.clearSelection();
      }
    } catch (e) {
      debugPrint('TerminalPane: failed to read clipboard on paste: $e');
    } finally {
      _isPasting = false;
    }
  }

  // Touch platforms (no physical keyboard by default), which get the soft
  // keyboard (IME) input path and the on-screen key accessory bar. Desktop
  // (macOS/Linux/Windows) keeps the hardware-keyboard path and its IME fix.
  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  // On-screen row of keys a soft keyboard lacks (Esc, Ctrl, Tab, arrows, common
  // shell symbols). Sits directly above the keyboard via the Scaffold's
  // resize-to-inset. The shared widget renders the identical row on the mobile
  // web client.
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
    // Detect if we are running inside a widget test environment to preserve
    // finder-based assertions on the plain fallback rows.
    final isTest = runningUnderFlutterTest();
    final useTestFallback =
        isTest && !TerminalPane.debugForceNativeTerminalView;
    if (useTestFallback) {
      return Focus(
        focusNode: _focusNode,
        autofocus: _mayTakeFocus,
        onKeyEvent: _handleTerminalKeyEvent,
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

    // Tighter padding on mobile — screen space is scarce and the accessory bar
    // already separates the terminal from the keyboard.
    final padding = _isMobile
        ? const EdgeInsets.all(8)
        : const EdgeInsets.only(left: 22, top: 22, bottom: 22, right: 18);

    // Null whenever there is nothing to offer: no selection, desktop, a
    // selection scrolled out of view, or a terminal not yet laid out (this
    // reads the previous frame's geometry).
    final copyButton = _buildCopyButton();

    return Container(
      color: const Color(0xff0d1113),
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _focusTerminal,
              // The copy button is a sibling of the terminal rather than an
              // Overlay entry: it is then torn down with this pane, cannot
              // outlive a session swap, and sits outside the Listener below, so
              // tapping it never enters the pointer paths that drive selection.
              child: TerminalScrollbar(
                controller: _scrollController,
                enabled: !_isMobile && widget.interactionEnabled,
                child: Stack(
                  key: _copyOverlayKey,
                  // Without this the terminal would receive loose constraints and
                  // shrink-wrap; it previously sat under Expanded and filled the
                  // pane, and the grid size is derived from those pixels.
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
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: _handlePointerDown,
                            onPointerMove: _handlePointerMove,
                            onPointerUp: _handlePointerUp,
                            onPointerCancel: _handlePointerCancel,
                            onPointerSignal: _handlePointerSignal,
                            onPointerPanZoomStart: _handlePointerPanZoomStart,
                            onPointerPanZoomUpdate: _handlePointerPanZoomUpdate,
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
                                      physics: _terminal.isUsingAltBuffer
                                          ? const NeverScrollableScrollPhysics()
                                          : const _TerminalScrollPhysics(),
                                    ),
                                child: xt.TerminalView(
                                  _terminal,
                                  key: _terminalViewKey,
                                  controller: _xtermController,
                                  theme: _theme,
                                  focusNode: _focusNode,
                                  autofocus: _mayTakeFocus,
                                  scrollController: _scrollController,
                                  onKeyEvent: _handleTerminalKeyEvent,
                                  textStyle: _textStyle,
                                  // Desktop always takes the hardware-keyboard path
                                  // instead of xterm's hidden IME TextInput connection:
                                  // on macOS the IME path desyncs Flutter's
                                  // HardwareKeyboard state ("physical key already
                                  // pressed") and swallows keystrokes. Mobile must use
                                  // the IME path, though: it is what raises the soft
                                  // keyboard, so disabling it leaves a phone unable to
                                  // type — which is exactly what the soft-keyboard kill
                                  // switch asks for.
                                  hardwareKeyboardOnly:
                                      terminalHardwareKeyboardOnly(
                                        isMobile: _isMobile,
                                        softKeyboardEnabled:
                                            widget.softKeyboardEnabled,
                                      ),
                                  readOnly:
                                      !terminalHardwareKeyboardOnly(
                                        isMobile: _isMobile,
                                        softKeyboardEnabled:
                                            widget.softKeyboardEnabled,
                                      ) &&
                                      (widget.isExited ||
                                          !_isRouteCurrentAndUnobscured),
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

/// The floating "Copy" affordance shown over a touch selection.
///
/// Styled to match the accessory bar rather than the ambient Material theme, so
/// it reads as part of the terminal chrome.
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
      // A raw GestureDetector, like the accessory bar's keys: no focus node, so
      // tapping copy never takes focus from the terminal and never dismisses the
      // soft keyboard.
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

/// Scroll physics for the native `xt.TerminalView` (`RenderTerminal`).
///
/// `RenderTerminal.performLayout` calls `_offset.applyContentDimensions` before
/// applying its stick-to-bottom `correctBy` adjustment. With standard
/// [RangeMaintainingScrollPhysics], that ordering leaves `_lastMetrics.pixels`
/// out of sync with `pixels`, so a later shrink in `maxScrollExtent` (buffer
/// clear, session swap, or scrollback trim) skips boundary enforcement and
/// triggers `IdleScrollActivity.applyNewDimensions` -> `goBallistic(0.0)`. While
/// a zero-velocity [BallisticScrollActivity] ticks in
/// `SchedulerPhase.transientCallbacks`, `RenderTerminal._onScroll` flips
/// `_stickToBottom = false`, and `_onScrollChanged` pins the scroll anchor at
/// the top of the buffer and triggers backward history paging.
///
/// Clamping out-of-range offsets synchronously during
/// `adjustPositionForNewDimensions` when idle and declining zero-velocity
/// ballistic simulations prevents layout-driven content changes from launching
/// phantom scroll activities while preserving normal user fling momentum.
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
