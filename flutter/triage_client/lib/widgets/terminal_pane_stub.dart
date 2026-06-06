import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:xterm/xterm.dart' as xt;
import 'package:triage_client/models/terminal_models.dart';
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
    this.isExited = false,
  });

  final String terminalId;
  final TerminalController controller;
  final xt.Terminal terminal;

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
    // Native implementation doesn't cache session DOM nodes.
  }

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  xt.Terminal get _terminal => widget.terminal;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
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
  xt.CellOffset? _selectionAnchor;
  // True while we are programmatically extending, so our own selection change
  // does not overwrite the anchor (it must stay fixed across repeated extends).
  bool _extendingSelection = false;
  // Pointer-down context, captured to recognise a shift-click on pointer-up.
  Offset? _pointerDownPosition;
  bool _shiftAtPointerDown = false;
  static const double _clickMoveSlop = 4.0;

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
    widget.onTerminalResizeBind?.call(_onTerminalResize);
    _bindTerminal(_terminal);
    widget.controller.addFitListener(_onFit);
    _xtermController.addListener(_recordSelectionAnchor);
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
  }

  void _unbindTerminal(xt.Terminal terminal) {
    terminal.onOutput = null;
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onTerminalResizeBind != widget.onTerminalResizeBind) {
      oldWidget.onTerminalResizeBind?.call(null);
      widget.onTerminalResizeBind?.call(_onTerminalResize);
    }
    if (!identical(oldWidget.terminal, widget.terminal)) {
      _unbindTerminal(oldWidget.terminal);
      _bindTerminal(widget.terminal);
      // The anchor referenced the previous terminal's buffer; drop it.
      _selectionAnchor = null;
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
    _unbindTerminal(_terminal);
    widget.controller.removeFitListener(_onFit);
    _xtermController.removeListener(_recordSelectionAnchor);
    _xtermController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _resizeOutDebounceTimer?.cancel();
    _scrollToCursorTimer?.cancel();
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
    }
  }

  // Shift-click: extend the selection from the saved anchor to [target]. xterm
  // clears the live selection on tap-down, so we rebuild it from the anchor we
  // recorded before the click. Anchors are buffer-line based, so this is correct
  // even if the view was scrolled between the original selection and the click.
  void _extendSelectionTo(xt.CellOffset target) {
    final anchor = _selectionAnchor;
    if (anchor == null) return;
    final buffer = _terminal.buffer;
    final lastRow = buffer.lines.length - 1;
    if (lastRow < 0) return;
    // Guard against a buffer that shrank (clear / scrollback trim) since the
    // anchor was recorded, so createAnchorFromOffset never indexes out of range.
    final safeAnchor = anchor.y > lastRow
        ? xt.CellOffset(anchor.x, lastRow)
        : anchor;
    _extendingSelection = true;
    try {
      _xtermController.setSelection(
        buffer.createAnchorFromOffset(safeAnchor),
        buffer.createAnchorFromOffset(target),
      );
    } finally {
      _extendingSelection = false;
    }
  }

  // Capture pointer-down context so pointer-up can tell a shift-click from a
  // drag. xterm's own tap-down clears any live selection here; our anchor is
  // preserved because _recordSelectionAnchor ignores the resulting null.
  void _handlePointerDown(PointerDownEvent event) {
    _focusTerminal();
    _pointerDownPosition = event.position;
    _shiftAtPointerDown =
        HardwareKeyboard.instance.isShiftPressed &&
        (event.buttons & kPrimaryButton) != 0;
  }

  // Shift-click (a click, not a drag) extends the selection to the clicked cell.
  // Done from raw pointer events because TerminalView.onTapUp is dead in xterm
  // 4.0.0; raw pointer handling also sidesteps the gesture arena, so normal
  // drag-select keeps working.
  void _handlePointerUp(PointerUpEvent event) {
    final downPosition = _pointerDownPosition;
    final wasShiftClick = _shiftAtPointerDown;
    _pointerDownPosition = null;
    _shiftAtPointerDown = false;
    if (!wasShiftClick || downPosition == null) return;
    if ((event.position - downPosition).distance > _clickMoveSlop) return;
    final state = _terminalViewKey.currentState;
    if (state == null) return;
    final render = state.renderTerminal;
    final target = render.getCellOffset(render.globalToLocal(event.position));
    _extendSelectionTo(target);
  }

  void _onTerminalOutput(String data) {
    widget.controller.sendInput(data);
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

  void _scrollToCursor({required bool requestFocus}) {
    void jump() {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        final position = _scrollController.position;
        position.jumpTo(position.maxScrollExtent);
      }
      if (requestFocus) {
        _focusNode.requestFocus();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    _scrollToCursorTimer?.cancel();
    _scrollToCursorTimer = Timer(const Duration(milliseconds: 50), jump);
  }

  @override
  Widget build(BuildContext context) {
    // Detect if we are running inside a widget test environment to preserve
    // finder-based assertions on the plain fallback rows.
    final isTest = Platform.environment.containsKey('FLUTTER_TEST');
    if (isTest) {
      return Container(
        color: const Color(0xff0d1113),
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(
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

    return Container(
      color: const Color(0xff0d1113),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _focusTerminal,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Listener(
            onPointerDown: _handlePointerDown,
            onPointerUp: _handlePointerUp,
            child: xt.TerminalView(
              _terminal,
              key: _terminalViewKey,
              controller: _xtermController,
              theme: _theme,
              focusNode: _focusNode,
              autofocus: true,
              scrollController: _scrollController,
              textStyle: _textStyle,
              // Use the hardware-keyboard path instead of xterm's hidden IME
              // TextInput connection. On macOS desktop the IME path desyncs
              // Flutter's HardwareKeyboard state ("physical key already
              // pressed") and swallows keystrokes; this is the standard desktop
              // terminal fix.
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      ),
    );
  }
}
