import 'dart:async';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
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
import 'package:triage_client/terminal/terminal_paste.dart';
import 'package:triage_client/terminal/terminal_scroll_anchor.dart';
import 'package:triage_client/platform_env_io.dart';
import 'package:triage_client/terminal/terminal_selection.dart';
import 'package:triage_client/widgets/multiline_paste_dialog.dart';
import 'package:triage_client/widgets/terminal_accessory_bar.dart';
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
    this.bracketedPasteEnabled = false,
    this.isExited = false,
  });

  final String terminalId;
  final TerminalController controller;
  final xt.Terminal terminal;
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

  static void destroySession(String terminalId) {
    _TerminalPaneState._sessionSavedScrollOffsets.remove(terminalId);
    _TerminalPaneState._sessionSavedScrollAnchors.remove(terminalId);
    _TerminalPaneState._sessionBracketedPasteModes.remove(terminalId);
  }

  static void setBracketedPasteMode(String terminalId, bool enabled) {
    _TerminalPaneState._sessionBracketedPasteModes[terminalId] = enabled;
  }

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  static final Map<String, double> _sessionSavedScrollOffsets = {};
  static final Map<String, TerminalScrollAnchor> _sessionSavedScrollAnchors =
      {};

  /// A finite initial scroll offset sentinel (1 billion pixels) that complies
  /// with Flutter's ScrollController bounds checking (`assert(initialScrollOffset.isFinite)`),
  /// while safely clamping to `maxScrollExtent` during the very first layout pass to
  /// prevent frame-0 rendering jumps.
  static const double _kBottomScrollSentinel = 1e9;
  xt.Terminal get _terminal => widget.terminal;
  final FocusNode _focusNode = FocusNode();
  late final ScrollController _scrollController;

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
  // the bottom snap) record the offset they landed on. Anything that leaves no meaningful previous *user* position
  // nulls it instead: a terminal swap, a cursor jump, and the end of a
  // drag-select. Output-driven jumps to the bottom deliberately leave it
  // alone, since they clear the anchor on the way and land at the bottom, so
  // there is no pin left for a stale reading to release.
  double? _lastScrollPixels;
  // The scroll position's isScrollingNotifier while a bottom snap waits for the
  // user's gesture to settle. Held as the notifier we actually subscribed to,
  // so the listener comes off that same object even if the position has since
  // been replaced.
  ValueNotifier<bool>? _snapWatchedNotifier;
  // A released pin still owes a trip to the bottom. Kept separate from the
  // subscription because _maybeFinishBottomSnap re-arms against the live
  // position, so a replaced ScrollPosition cannot strand the debt.
  bool _snapPending = false;
  // Pointers currently down on the terminal. A hold activity reports *not*
  // scrolling, so the scroll state alone would treat a finger resting on a
  // stopped fling as settled.
  final Set<int> _activePointers = <int>{};

  Timer? _resizeOutDebounceTimer;
  Timer? _scrollToCursorTimer;
  int? _pendingResizeOutCols;
  int? _pendingResizeOutRows;
  int? _lastResizeOutCols;
  int? _lastResizeOutRows;

  // Selection state. The view owns selection through this xterm controller; we
  // observe it to keep the live anchor (the cell a selection started from) so a
  // later shift-click can extend the range to a new cell — even after scrolling,
  // since anchors track buffer lines, not viewport rows.
  final xt.TerminalController _xtermController = xt.TerminalController();
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
    final initialOffset =
        _sessionSavedScrollOffsets[widget.terminalId] ?? _kBottomScrollSentinel;
    final savedAnchor = _sessionSavedScrollAnchors[widget.terminalId];
    if (savedAnchor != null) {
      _scrollAnchor.copyFrom(savedAnchor);
    }
    _scrollController = ScrollController(initialScrollOffset: initialOffset);
    widget.onTerminalResizeBind?.call(_onTerminalResize);
    _scrollController.addListener(_onScrollChanged);
    _bindTerminal(_terminal);
    widget.controller.addFitListener(_onFit);
    _xtermController.addListener(_recordSelectionAnchor);
    _xtermController.addListener(_syncCopyTarget);
    if (widget.focusCursorRevision > 0) {
      _scrollToCursor(requestFocus: true);
    }
  }

  // The persistent terminal lives on SessionVm, so it can be swapped underneath
  // this State (a session swap reuses the State under the same `triage / <sid>`
  // key). Bind keyboard output through a paired seam so initState and
  // didUpdateWidget can't leave the new terminal's onOutput null.
  void _bindTerminal(xt.Terminal terminal) {
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
    if (!identical(oldWidget.terminal, widget.terminal)) {
      _saveScrollOffset(oldWidget.terminalId);
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
      _cancelPendingBottomSnap();
      _activePointers.clear();
      // The last scroll position belongs to the outgoing terminal; a direction
      // measured against it could release the incoming session's pin on its
      // first scroll event.
      _lastScrollPixels = null;
      // Drop any latched sticky Ctrl so it can't fold into the new session's
      // first keystroke (a Ctrl armed for session A must not reach session B).
      _ctrlArmed = false;
      _endDrag();
      _scrollToCursor(requestFocus: true);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeFitListener(_onFit);
      widget.controller.addFitListener(_onFit);
    }
    if (oldWidget.focusCursorRevision != widget.focusCursorRevision) {
      _scrollToCursor(requestFocus: true);
    }
  }

  @override
  void dispose() {
    widget.onTerminalResizeBind?.call(null);
    _saveScrollOffset();
    _unbindTerminal(_terminal);
    widget.controller.removeFitListener(_onFit);
    _xtermController.removeListener(_recordSelectionAnchor);
    _xtermController.removeListener(_syncCopyTarget);
    _xtermController.dispose();
    _scrollController.removeListener(_onScrollChanged);
    _cancelPendingBottomSnap();
    _scrollController.dispose();
    _focusNode.dispose();
    _resizeOutDebounceTimer?.cancel();
    _scrollToCursorTimer?.cancel();
    _autoScrollTimer?.cancel();
    super.dispose();
  }

  void _onFit() {
    setState(() {});
  }

  // Remember where the current selection is anchored so a shift-click can extend
  // from it. Skipped while we are doing the extending ourselves so the anchor
  // stays pinned to the original start across repeated shift-clicks.
  void _recordSelectionAnchor() {
    if (_extendingSelection) return;
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
  // the +1 trailing column on forward selections, matching xterm's own
  // selectCharacters so the clicked/dragged cell is included.
  void _applySelection(xt.CellOffset anchorCell, xt.CellOffset targetCell) {
    final buffer = _terminal.buffer;
    final lastRow = buffer.lines.length - 1;
    if (lastRow < 0) return;
    final maxCol = _terminal.viewWidth - 1;
    final safeAnchor = xt.CellOffset(
      anchorCell.x.clamp(0, maxCol),
      anchorCell.y.clamp(0, lastRow),
    );
    // Forward/backward follows the full (row, col) order, not the column alone:
    // a target on a later row is forward even when its column is smaller. xterm's
    // selectCharacters adds 1 to the trailing column so the pointed cell is
    // included; deciding that on column alone drops the last character of a
    // diagonal forward (multi-row) selection.
    final forward =
        targetCell.y > safeAnchor.y ||
        (targetCell.y == safeAnchor.y && targetCell.x >= safeAnchor.x);
    final extentX = forward ? targetCell.x + 1 : targetCell.x;
    final extent = xt.CellOffset(extentX, targetCell.y.clamp(0, lastRow));
    _extendingSelection = true;
    try {
      _xtermController.setSelection(
        buffer.createAnchorFromOffset(safeAnchor),
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
    _activePointers.add(event.pointer);
    // Desktop only: focus on pointer-down so a mouse click focuses the terminal
    // before a drag-select. On mobile this same pointer-down begins a scroll
    // swipe, and requesting focus here raises the soft keyboard mid-scroll — the
    // Scaffold then insets for the keyboard and the viewport jumps under the
    // finger. Mobile tap-to-focus is handled by the GestureDetector.onTap
    // (a real tap, not a swipe), so skip focusing on the raw pointer-down.
    if (!_isMobile) {
      _focusTerminal();
    }
    if ((event.buttons & kPrimaryButton) == 0) return;
    // Touch: let the terminal's own gestures handle scrolling (a swipe) and
    // selection (long-press). The pointer-driven drag-select below is for a
    // mouse — on touch it would hijack a swipe-to-scroll into a text selection.
    if (_isMobile || ModalRoute.of(context)?.isCurrent == false) return;
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
  void _handlePointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer == _dragPointer) {
      _endDrag();
      return;
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
    // Last: the snap moves the scroll offset, and _cellAtGlobal resolves
    // against the live offset.
    _maybeFinishBottomSnap();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer == _dragPointer) {
      _endDrag();
      return;
    }
    if (event.pointer == _shiftClickPointer) {
      _shiftClickPointer = null;
      _shiftClickDownPosition = null;
    }
  }

  void _endDrag() {
    _stopAutoScroll();
    // A snap queued just before the drag would otherwise settle mid-selection
    // and jump the viewport out from under the text being highlighted.
    _cancelPendingBottomSnap();
    // Auto-scroll moved the viewport while _onScrollChanged was short-circuited
    // on _dragSelecting, so the offset from before the drag is no longer a
    // previous *user* position. Left in place it reads as one large downward
    // delta and releases a pin the user never gave up.
    _lastScrollPixels = null;
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
    final target = _cellAtGlobal(position);
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
    _sessionSavedScrollOffsets.remove(widget.terminalId);
    _sessionSavedScrollAnchors.remove(widget.terminalId);
    _scrollAnchor.clear();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
    // Sticky Ctrl (accessory bar): fold the armed Ctrl into the next single
    // character before it reaches the session, so e.g. arming Ctrl then typing
    // "c" on the soft keyboard sends 0x03 (SIGINT) instead of a literal "c".
    if (_ctrlArmed) {
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
      unawaited(_handlePaste(data));
      return;
    }
    widget.controller.sendInput(data);
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
    widget.controller.sendInput(bytes);
    _disarmCtrl();
  }

  void _toggleCtrl() {
    if (_ctrlArmed) {
      _disarmCtrl();
    } else {
      _armCtrl();
    }
  }

  void _focusTerminal() {
    _focusNode.requestFocus();
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
      // Reflow (reflowEnabled is on) runs only on a column change, moving content
      // between rows and staling the cached shift-click anchor — a buffer
      // coordinate the identity guard in _extendSelectionTo can't detect as stale,
      // since reflow mutates lines within the same Buffer object. Drop it on a
      // width change so a later shift-click won't extend from a pre-reflow row
      // (with no anchor the extend is a no-op until the next fresh select). A
      // height-only resize doesn't reflow, so the anchor stays valid and is left
      // alone. `viewWidth` is still the old width here — onResize fires before the
      // terminal stores the new one. The live highlight is unaffected; only the
      // extend-from point is invalidated.
      if (width != _terminal.viewWidth) {
        _selectionAnchor = null;
        _selectionAnchorBuffer = null;
      }
      // This fires from inside RenderTerminal.performLayout (the view auto-fits
      // by calling terminal.resize). Replaying history writes to the terminal,
      // which would mark the render object dirty during its own layout — illegal.
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
    if (_lastResizeOutCols == cols && _lastResizeOutRows == rows) {
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
    if (_lastResizeOutCols == cols && _lastResizeOutRows == rows) {
      return;
    }
    _lastResizeOutCols = cols;
    _lastResizeOutRows = rows;
    widget.controller.sendResizeOut(cols, rows);
  }

  // --- Scroll anchoring: keep the viewport stable across scrollback trims ---

  /// Height of one rendered terminal line in pixels, or null if the view isn't
  /// laid out yet (the render object asserts a present viewport).
  double? _lineHeight() {
    final state = _terminalViewKey.currentState;
    if (state == null) return null;
    try {
      return state.renderTerminal.lineHeight;
    } catch (_) {
      return null;
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
    if (_suppressAnchorCapture || _dragSelecting) return;
    _captureScrollAnchor();
  }

  void _saveScrollOffset([String? terminalId, double? lineHeight]) {
    if (!_scrollController.hasClients) return;
    final id = terminalId ?? widget.terminalId;
    final position = _scrollController.position;
    final lh = lineHeight ?? _lineHeight() ?? 2.0;
    if (position.pixels < position.maxScrollExtent - lh) {
      _sessionSavedScrollOffsets[id] = position.pixels;
      if (_scrollAnchor.hasAnchor) {
        _sessionSavedScrollAnchors[id] = _scrollAnchor.clone();
      } else {
        _sessionSavedScrollAnchors.remove(id);
      }
    } else {
      _sessionSavedScrollOffsets.remove(id);
      _sessionSavedScrollAnchors.remove(id);
    }
  }

  void _captureScrollAnchor() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final lineHeight = _lineHeight();
    if (lineHeight != null) {
      if (_scrollAnchor.hasAnchor &&
          shouldReleaseScrollPin(
            lastPixels: _lastScrollPixels,
            pixels: position.pixels,
            maxScrollExtent: position.maxScrollExtent,
            lineHeight: lineHeight,
          )) {
        // The user is chasing live output and nearly there. Dropping the pin
        // stops the treadmill at once; completing the trip is what keeps the
        // viewport from parking short while new lines arrive beneath it.
        _scrollAnchor.clear();
        // A snap that ran here already recorded the offset and saved.
        if (_snapToBottomWhenIdle()) return;
      } else if (!_snapPending) {
        // While a snap is queued the viewport is on its way to the bottom.
        // Re-pinning here would capture an anchor 1 to 3 lines short, and the
        // pending snap would then see a held pin and retire itself, so the
        // release would silently no-op on any gesture that reports more than
        // one scroll event.
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

  /// Queues the released pin's trip to the bottom, running it immediately when
  /// nothing is in flight. Returns whether the snap actually happened.
  bool _snapToBottomWhenIdle() {
    if (!_scrollController.hasClients) return false;
    _snapPending = true;
    _watchScrollSettle(_scrollController.position);
    return _maybeFinishBottomSnap();
  }

  /// Subscribes to [position]'s scroll state, reconciling against whatever we
  /// were watching before. A replaced ScrollPosition disposes its notifier, and
  /// holding the dead one would strand the pending snap and, worse, block every
  /// later one for the life of the pane.
  void _watchScrollSettle(ScrollPosition position) {
    final notifier = position.isScrollingNotifier;
    if (identical(_snapWatchedNotifier, notifier)) return;
    _snapWatchedNotifier?.removeListener(_onScrollSettled);
    _snapWatchedNotifier = notifier..addListener(_onScrollSettled);
  }

  void _onScrollSettled() => _maybeFinishBottomSnap();

  /// Finishes a released pin's trip to the bottom, but never mid-gesture.
  ///
  /// `jumpTo` runs `goIdle()`, which tears down the drag or fling delivering
  /// the very scroll notification we are reacting to, so a held finger would
  /// then scroll nothing until it lifted. While a gesture is in flight the
  /// user's own movement carries the viewport down, and this closes only
  /// whatever distance is left once everything settles.
  bool _maybeFinishBottomSnap() {
    if (!_snapPending) return false;
    if (!mounted || !_scrollController.hasClients) {
      _cancelPendingBottomSnap();
      return false;
    }
    final position = _scrollController.position;
    // Re-arm against the live position: a replaced ScrollPosition disposes the
    // notifier we were watching, and nothing else would ever resubscribe.
    _watchScrollSettle(position);
    if (!shouldFinishBottomSnap(
      isScrolling: position.isScrollingNotifier.value,
      pointerDown: _activePointers.isNotEmpty,
      pixels: position.pixels,
      maxScrollExtent: position.maxScrollExtent,
      hasAnchor: _scrollAnchor.hasAnchor,
    )) {
      // Either still in flight, or the trip is moot: the gesture arrived on its
      // own or the user re-pinned on the way. Only the latter retires the snap.
      if (!position.isScrollingNotifier.value && _activePointers.isEmpty) {
        _cancelPendingBottomSnap();
      }
      return false;
    }
    _cancelPendingBottomSnap();
    _snapToBottom(position);
    return true;
  }

  void _snapToBottom(ScrollPosition position) {
    // Suppressed like our own re-pin correction so the snap's notification
    // cannot re-capture an anchor from it. Saved and restored rather than
    // forced false, so a nested call cannot clear an outer suppressed region.
    final wasSuppressed = _suppressAnchorCapture;
    _suppressAnchorCapture = true;
    try {
      position.jumpTo(position.maxScrollExtent);
    } finally {
      _suppressAnchorCapture = wasSuppressed;
      // Read the offset back rather than assuming the target: jumpTo can throw
      // on a transient scroll-range issue, and recording a bottom we never
      // reached would make the next event measure a fake delta.
      _lastScrollPixels = position.pixels;
    }
    // Saving at the bottom retires this session's stored offset and anchor, so
    // a later revisit follows live output instead of being pulled back to the
    // position the user just scrolled away from.
    _saveScrollOffset(widget.terminalId, _lineHeight());
  }

  void _cancelPendingBottomSnap() {
    _snapPending = false;
    _snapWatchedNotifier?.removeListener(_onScrollSettled);
    _snapWatchedNotifier = null;
  }

  void _onTerminalContentChanged() {
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
    // Re-pin after xterm.dart's layout has applied the new content dimensions;
    // coalesce bursts of writes into one correction per frame. No anchor means
    // we're following the bottom and xterm.dart already handles it.
    if (!_scrollAnchor.hasAnchor || _repinScheduled) return;
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
    final lineHeight = _lineHeight();
    if (lineHeight == null) return;
    final position = _scrollController.position;
    final desired = _scrollAnchor.desiredOffset(
      maxScrollExtent: position.maxScrollExtent,
      lineHeight: lineHeight,
    );
    if (desired == null) return;
    if ((desired - position.pixels).abs() < 0.5) return;
    final wasSuppressed = _suppressAnchorCapture;
    _suppressAnchorCapture = true;
    try {
      position.jumpTo(desired);
    } finally {
      _suppressAnchorCapture = wasSuppressed;
      _lastScrollPixels = position.pixels;
      // Guarantee the guard resets even if jumpTo throws on a transient
      // scroll-range issue — otherwise user scrolls would stop capturing.
      _suppressAnchorCapture = false;
    }
  }

  void _scrollToCursor({required bool requestFocus}) {
    void jump() {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        final position = _scrollController.position;
        // A jump of our own must not read as a user scroll direction, so the
        // capture it triggers can pin (or clear at the bottom) normally.
        _lastScrollPixels = null;
        final saved = _sessionSavedScrollOffsets[widget.terminalId];
        final lineHeight = _lineHeight();
        double target;
        if (_scrollAnchor.hasAnchor && lineHeight != null) {
          final anchored = _scrollAnchor.desiredOffset(
            maxScrollExtent: position.maxScrollExtent,
            lineHeight: lineHeight,
          );
          target =
              anchored ??
              (saved?.clamp(0.0, position.maxScrollExtent) ??
                  position.maxScrollExtent);
        } else if (saved != null) {
          target = saved.clamp(0.0, position.maxScrollExtent);
        } else {
          target = position.maxScrollExtent;
        }
        if ((position.pixels - target).abs() > 0.5) {
          position.jumpTo(target);
        }
      }
      if (requestFocus) {
        _focusNode.requestFocus();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    _scrollToCursorTimer?.cancel();
    _scrollToCursorTimer = Timer(const Duration(milliseconds: 50), jump);
  }

  // xterm.dart copies selected text via BufferLine.getText, which drops every
  // blank (codePoint 0) cell — so columns a TUI lays out by moving the cursor
  // (rather than writing literal spaces) concatenate on copy. Intercept the
  // copy chord before xterm's shortcut manager runs (TerminalView.onKeyEvent
  // short-circuits it when we return a non-ignored result) and rebuild the text
  // with the gap spaces restored. Returning `ignored` for everything else
  // leaves xterm's normal key handling — including Ctrl+C -> SIGINT — untouched.
  KeyEventResult _handleTerminalKeyEvent(FocusNode node, KeyEvent event) {
    if (ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC && _isCopyChord()) {
      // Nothing selected (or nothing in it) leaves xterm's own handling in place.
      if (_copySelectionToClipboard()) return KeyEventResult.handled;
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

  // The platform copy chord, matching terminal emulator conventions: Cmd+C on
  // macOS/iOS, Ctrl+Shift+C elsewhere so plain Ctrl+C still reaches the program.
  bool _isCopyChord() {
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
    if (!mounted || text.isEmpty || widget.isExited) return;
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
      if (chosenText != null && mounted && !widget.isExited) {
        final formatted = formatPasteInput(chosenText, false);
        widget.controller.sendInput(formatted);
        _xtermController.clearSelection();
      }
    } catch (e) {
      debugPrint('TerminalPane: failed to handle paste: $e');
    } finally {
      _isPasteDialogShowing = false;
      if (mounted && !widget.isExited) {
        _focusNode.requestFocus();
      }
    }
  }

  Future<void> _pasteFromClipboard() async {
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
      ctrlArmed: _ctrlArmed,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Detect if we are running inside a widget test environment to preserve
    // finder-based assertions on the plain fallback rows.
    final isTest = runningUnderFlutterTest();
    if (isTest) {
      return Container(
        color: const Color(0xff0d1113),
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(
          controller: _scrollController,
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
                            text: span.text.isEmpty ? ' ' : span.text,
                            style: TextStyle(
                              fontFamily: 'JetBrains Mono',
                              fontSize: 15,
                              height: 1.35,
                              color:
                                  span.style.foreground?.toColor() ??
                                  const Color(0xffd9e5e3),
                              backgroundColor: span.style.background?.toColor(),
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
      );
    }

    // Tighter padding on mobile — screen space is scarce and the accessory bar
    // already separates the terminal from the keyboard.
    final padding = _isMobile
        ? const EdgeInsets.all(8)
        : const EdgeInsets.all(22);

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
              child: Stack(
                key: _copyOverlayKey,
                // Without this the terminal would receive loose constraints and
                // shrink-wrap; it previously sat under Expanded and filled the
                // pane, and the grid size is derived from those pixels.
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: padding,
                    child: Listener(
                      onPointerDown: _handlePointerDown,
                      onPointerMove: _handlePointerMove,
                      onPointerUp: _handlePointerUp,
                      onPointerCancel: _handlePointerCancel,
                      child: xt.TerminalView(
                        _terminal,
                        key: _terminalViewKey,
                        controller: _xtermController,
                        theme: _theme,
                        focusNode: _focusNode,
                        autofocus: true,
                        scrollController: _scrollController,
                        onKeyEvent: _handleTerminalKeyEvent,
                        textStyle: _textStyle,
                        // Desktop uses the hardware-keyboard path instead of
                        // xterm's hidden IME TextInput connection: on macOS the
                        // IME path desyncs Flutter's HardwareKeyboard state
                        // ("physical key already pressed") and swallows
                        // keystrokes. Mobile must use the IME path, though — it
                        // is what raises the soft keyboard, so disabling it
                        // leaves a phone unable to type.
                        hardwareKeyboardOnly: !_isMobile,
                      ),
                    ),
                  ),
                  if (copyButton != null) copyButton,
                ],
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
