import 'dart:collection';
import 'dart:math' show max, min, sin, pi;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';
import 'package:triage_client/terminal/terminal_links.dart';
import 'package:triage_client/terminal/terminal_selection.dart';

typedef TerminalGridSizeCallback =
    void Function(int cols, int rows, double cellWidth, double cellHeight);

typedef TerminalMissingRowsCallback =
    void Function(int firstVirtualRow, int lastVirtualRow);

const List<String> kTerminalFontFallbacks = <String>[
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
];

/// Scrollable GPU-rendered terminal cell-grid widget backed by [RenderTerminalGrid].
class TerminalGridView extends StatefulWidget {
  const TerminalGridView({
    super.key,
    required this.buffer,
    required this.scrollController,
    this.selection,
    this.hoveredLink,
    this.focusNode,
    this.autofocus = false,
    this.onKeyEvent,
    this.autoResize = true,
    this.stickToBottom = true,
    this.showCursor = true,
    this.fontSize = 15.0,
    this.lineHeightScale = 1.2,
    this.textScaler = TextScaler.noScaling,
    this.physics,
    this.onGridMetricsChanged,
    this.onMissingRowsVisible,
  });

  final TerminalCellBuffer buffer;
  final ScrollController scrollController;
  final TerminalSelectionRange? selection;
  final TerminalLink? hoveredLink;
  final FocusNode? focusNode;
  final bool autofocus;
  final FocusOnKeyEventCallback? onKeyEvent;
  final bool autoResize;
  final bool stickToBottom;
  final bool showCursor;
  final double fontSize;
  final double lineHeightScale;
  final TextScaler textScaler;
  final ScrollPhysics? physics;
  final TerminalGridSizeCallback? onGridMetricsChanged;
  final TerminalMissingRowsCallback? onMissingRowsVisible;

  @override
  State<TerminalGridView> createState() => TerminalGridViewState();
}

class TerminalGridViewState extends State<TerminalGridView> {
  final GlobalKey _scrollableKey = GlobalKey();
  final GlobalKey _renderKey = GlobalKey();
  bool _hasFocus = false;

  RenderTerminalGrid? get renderGrid =>
      _renderKey.currentContext?.findRenderObject() as RenderTerminalGrid?;

  bool get _usesFocusWrapper =>
      widget.focusNode != null || widget.autofocus || widget.onKeyEvent != null;

  @override
  void initState() {
    super.initState();
    _hasFocus = widget.focusNode?.hasFocus ?? false;
    widget.focusNode?.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant TerminalGridView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_onFocusChanged);
      if (widget.focusNode != null) {
        _hasFocus = widget.focusNode!.hasFocus;
        widget.focusNode!.addListener(_onFocusChanged);
      } else {
        _hasFocus = false;
      }
    } else if (!_usesFocusWrapper && _hasFocus) {
      _hasFocus = false;
    }
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    final next = widget.focusNode?.hasFocus ?? false;
    if (next != _hasFocus && mounted) {
      setState(() {
        _hasFocus = next;
      });
    }
  }

  void _handleFocusChange(bool focused) {
    if (focused != _hasFocus && mounted) {
      setState(() {
        _hasFocus = focused;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content = Scrollable(
      key: _scrollableKey,
      axisDirection: AxisDirection.down,
      controller: widget.scrollController,
      physics: widget.physics,
      viewportBuilder: (BuildContext context, ViewportOffset offset) {
        return _TerminalGridRenderWidget(
          key: _renderKey,
          buffer: widget.buffer,
          offset: offset,
          scrollControllerIdentity: widget.scrollController,
          selection: widget.selection,
          hoveredLink: widget.hoveredLink,
          hasFocus: _hasFocus,
          autoResize: widget.autoResize,
          stickToBottom: widget.stickToBottom,
          showCursor: widget.showCursor,
          fontSize: widget.fontSize,
          lineHeightScale: widget.lineHeightScale,
          textScaler: widget.textScaler,
          onGridMetricsChanged: widget.onGridMetricsChanged,
          onMissingRowsVisible: widget.onMissingRowsVisible,
        );
      },
    );

    if (_usesFocusWrapper) {
      content = Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onFocusChange: _handleFocusChange,
        onKeyEvent: widget.onKeyEvent,
        child: content,
      );
    }
    return RepaintBoundary(child: content);
  }
}

class _TerminalGridRenderWidget extends LeafRenderObjectWidget {
  const _TerminalGridRenderWidget({
    super.key,
    required this.buffer,
    required this.offset,
    required this.scrollControllerIdentity,
    required this.selection,
    required this.hoveredLink,
    required this.hasFocus,
    required this.autoResize,
    required this.stickToBottom,
    required this.showCursor,
    required this.fontSize,
    required this.lineHeightScale,
    required this.textScaler,
    required this.onGridMetricsChanged,
    required this.onMissingRowsVisible,
  });

  final TerminalCellBuffer buffer;
  final ViewportOffset offset;
  final Object? scrollControllerIdentity;
  final TerminalSelectionRange? selection;
  final TerminalLink? hoveredLink;
  final bool hasFocus;
  final bool autoResize;
  final bool stickToBottom;
  final bool showCursor;
  final double fontSize;
  final double lineHeightScale;
  final TextScaler textScaler;
  final TerminalGridSizeCallback? onGridMetricsChanged;
  final TerminalMissingRowsCallback? onMissingRowsVisible;

  @override
  RenderTerminalGrid createRenderObject(BuildContext context) {
    return RenderTerminalGrid(
      buffer: buffer,
      offset: offset,
      scrollControllerIdentity: scrollControllerIdentity,
      selection: selection,
      hoveredLink: hoveredLink,
      hasFocus: hasFocus,
      autoResize: autoResize,
      stickToBottom: stickToBottom,
      showCursor: showCursor,
      fontSize: fontSize,
      lineHeightScale: lineHeightScale,
      textScaler: textScaler,
      onGridMetricsChanged: onGridMetricsChanged,
      onMissingRowsVisible: onMissingRowsVisible,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderTerminalGrid renderObject,
  ) {
    renderObject
      ..scrollControllerIdentity = scrollControllerIdentity
      ..buffer = buffer
      ..offset = offset
      ..selection = selection
      ..hoveredLink = hoveredLink
      ..hasFocus = hasFocus
      ..autoResize = autoResize
      ..stickToBottom = stickToBottom
      ..showCursor = showCursor
      ..fontSize = fontSize
      ..lineHeightScale = lineHeightScale
      ..textScaler = textScaler
      ..onGridMetricsChanged = onGridMetricsChanged
      ..onMissingRowsVisible = onMissingRowsVisible;
  }
}

class _GlyphCacheKey {
  const _GlyphCacheKey(this.text, this.colorValue, this.styleMask);

  final String text;
  final int colorValue;
  final int styleMask;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _GlyphCacheKey &&
          other.colorValue == colorValue &&
          other.styleMask == styleMask &&
          other.text == text);

  @override
  int get hashCode => Object.hash(text, colorValue, styleMask);
}

/// Custom [RenderBox] that paints only the visible slice of a
/// [TerminalCellBuffer] (up to 210,000+ virtual rows) directly onto a Flutter
/// GPU [Canvas].
class RenderTerminalGrid extends RenderBox {
  RenderTerminalGrid({
    required TerminalCellBuffer buffer,
    required ViewportOffset offset,
    Object? scrollControllerIdentity,
    required TerminalSelectionRange? selection,
    TerminalLink? hoveredLink,
    required bool hasFocus,
    required bool autoResize,
    required bool stickToBottom,
    required bool showCursor,
    required double fontSize,
    required double lineHeightScale,
    required TextScaler textScaler,
    required TerminalGridSizeCallback? onGridMetricsChanged,
    required TerminalMissingRowsCallback? onMissingRowsVisible,
  }) : _buffer = buffer,
       _offset = offset,
       _scrollControllerIdentity = scrollControllerIdentity,
       _selection = selection,
       _hoveredLink = hoveredLink,
       _hasFocus = hasFocus,
       _autoResize = autoResize,
       _stickToBottom = stickToBottom,
       _showCursor = showCursor,
       _fontSize = fontSize,
       _lineHeightScale = lineHeightScale,
       _textScaler = textScaler,
       _onGridMetricsChanged = onGridMetricsChanged,
       _onMissingRowsVisible = onMissingRowsVisible,
       _fittedCols = max(2, buffer.viewWidth),
       _fittedRows = max(1, buffer.viewHeight);

  static const int _maxGlyphCacheEntries = 4096;

  TerminalCellBuffer _buffer;
  ViewportOffset _offset;
  Object? _scrollControllerIdentity;
  bool _scrollControllerSwapped = false;
  TerminalSelectionRange? _selection;
  TerminalLink? _hoveredLink;
  bool _hasFocus;
  bool _autoResize;
  bool _stickToBottom;
  bool _showCursor;
  double _fontSize;
  double _lineHeightScale;
  TextScaler _textScaler;

  TerminalGridSizeCallback? _onGridMetricsChanged;
  TerminalMissingRowsCallback? _onMissingRowsVisible;

  double _cellWidth = 9.0;
  double _cellHeight = 18.0;
  double _glyphBaselineOffset = 0.0;
  bool _metricsDirty = true;

  int _fittedCols;
  int _fittedRows;
  int _notifiedCols = -1;
  int _notifiedRows = -1;
  double _notifiedCellWidth = -1.0;
  double _notifiedCellHeight = -1.0;
  int _knownTotalLines = -1;
  double _lastMaxScrollExtent = 0.0;
  bool _inPerformLayout = false;
  bool _layoutInputsConsumed = false;
  bool _deferredLayoutNeeded = false;
  bool _deferredLayoutScheduled = false;
  bool _missingNotifyScheduled = false;
  int _pendingMissingFirst = -1;
  int _pendingMissingLast = -1;

  final LinkedHashMap<_GlyphCacheKey, TextPainter> _glyphCache =
      LinkedHashMap<_GlyphCacheKey, TextPainter>();

  int _cachedLinksFirstRow = -1;
  int _cachedLinksLastRow = -1;
  int _cachedLinksRevision = -1;
  int _cachedLinksCols = -1;
  TerminalCellBuffer? _cachedLinksBuffer;
  List<TerminalLink> _cachedLinks = const <TerminalLink>[];

  double get cellWidth => _cellWidth;
  double get lineHeight => _cellHeight;
  Size get cellSize => Size(_cellWidth, _cellHeight);
  int get fittedCols => _fittedCols;
  int get fittedRows => _fittedRows;

  TerminalGridSizeCallback? get onGridMetricsChanged => _onGridMetricsChanged;
  set onGridMetricsChanged(TerminalGridSizeCallback? value) {
    if (identical(_onGridMetricsChanged, value)) return;
    final wasNull = _onGridMetricsChanged == null;
    _onGridMetricsChanged = value;
    if (value == null) {
      _resetMetricsNotification();
    } else if (wasNull && _autoResize) {
      markNeedsLayout();
    }
  }

  TerminalMissingRowsCallback? get onMissingRowsVisible =>
      _onMissingRowsVisible;
  set onMissingRowsVisible(TerminalMissingRowsCallback? value) {
    if (identical(_onMissingRowsVisible, value)) return;
    final wasNull = _onMissingRowsVisible == null;
    _onMissingRowsVisible = value;
    if (wasNull && value != null) {
      markNeedsPaint();
    }
  }

  void _resetMetricsNotification() {
    _notifiedCols = -1;
    _notifiedRows = -1;
    _notifiedCellWidth = -1.0;
    _notifiedCellHeight = -1.0;
  }

  bool get _hasPendingMetricsNotification =>
      _autoResize &&
      _onGridMetricsChanged != null &&
      (_fittedCols != _notifiedCols ||
          _fittedRows != _notifiedRows ||
          _cellWidth != _notifiedCellWidth ||
          _cellHeight != _notifiedCellHeight);

  Object? get scrollControllerIdentity => _scrollControllerIdentity;
  set scrollControllerIdentity(Object? value) {
    if (identical(_scrollControllerIdentity, value)) return;
    _scrollControllerIdentity = value;
    _scrollControllerSwapped = true;
  }

  TerminalCellBuffer get buffer => _buffer;
  set buffer(TerminalCellBuffer value) {
    if (identical(_buffer, value)) return;
    if (attached) {
      _buffer.removeListener(_onBufferChanged);
    }
    _buffer = value;
    if (!hasSize || !constraints.hasBoundedWidth) {
      _fittedCols = max(2, value.viewWidth);
    }
    if (!hasSize || !constraints.hasBoundedHeight) {
      _fittedRows = max(1, value.viewHeight);
    }
    _knownTotalLines = -1;
    _lastMaxScrollExtent = 0.0;
    _resetMetricsNotification();
    _pendingMissingFirst = -1;
    _pendingMissingLast = -1;
    if (attached) {
      _buffer.addListener(_onBufferChanged);
    }
    if (_inPerformLayout) {
      _deferredLayoutNeeded = true;
    }
    markNeedsLayout();
    markNeedsPaint();
  }

  ViewportOffset get offset => _offset;
  set offset(ViewportOffset value) {
    if (identical(_offset, value)) {
      _scrollControllerSwapped = false;
      return;
    }
    final preserveExtent =
        !_scrollControllerSwapped &&
        _offset.hasPixels &&
        value.hasPixels &&
        (value.pixels - _offset.pixels).abs() < 0.5;
    _scrollControllerSwapped = false;
    if (!preserveExtent) {
      _lastMaxScrollExtent = 0.0;
    }
    if (attached) {
      _offset.removeListener(_onScrollOffsetChanged);
    }
    _offset = value;
    if (attached) {
      _offset.addListener(_onScrollOffsetChanged);
    }
    if (_inPerformLayout) {
      _deferredLayoutNeeded = true;
    }
    markNeedsLayout();
  }

  TerminalSelectionRange? get selection => _selection;
  set selection(TerminalSelectionRange? value) {
    if (_selection == value) return;
    _selection = value;
    markNeedsPaint();
  }

  TerminalLink? get hoveredLink => _hoveredLink;
  set hoveredLink(TerminalLink? value) {
    if (_hoveredLink == value) return;
    _hoveredLink = value;
    markNeedsPaint();
  }

  bool get hasFocus => _hasFocus;
  set hasFocus(bool value) {
    if (_hasFocus == value) return;
    _hasFocus = value;
    markNeedsPaint();
  }

  bool get autoResize => _autoResize;
  set autoResize(bool value) {
    if (_autoResize == value) return;
    _autoResize = value;
    if (value) {
      markNeedsLayout();
    }
  }

  bool get stickToBottom => _stickToBottom;
  set stickToBottom(bool value) {
    if (_stickToBottom == value) return;
    _stickToBottom = value;
    if (value) {
      markNeedsLayout();
    }
  }

  bool get showCursor => _showCursor;
  set showCursor(bool value) {
    if (_showCursor == value) return;
    _showCursor = value;
    markNeedsPaint();
  }

  double get fontSize => _fontSize;
  set fontSize(double value) {
    if (_fontSize == value || (_fontSize.isNaN && value.isNaN)) return;
    _fontSize = value;
    _invalidateFontMetrics();
  }

  double get lineHeightScale => _lineHeightScale;
  set lineHeightScale(double value) {
    if (_lineHeightScale == value || (_lineHeightScale.isNaN && value.isNaN)) {
      return;
    }
    _lineHeightScale = value;
    _invalidateFontMetrics();
  }

  TextScaler get textScaler => _textScaler;
  set textScaler(TextScaler value) {
    if (_textScaler == value) return;
    _textScaler = value;
    _invalidateFontMetrics();
  }

  void _invalidateFontMetrics() {
    _metricsDirty = true;
    _resetMetricsNotification();
    for (final tp in _glyphCache.values) {
      tp.dispose();
    }
    _glyphCache.clear();
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _buffer.addListener(_onBufferChanged);
    _offset.addListener(_onScrollOffsetChanged);
    if (_deferredLayoutNeeded ||
        _metricsDirty ||
        _hasPendingMetricsNotification ||
        _buffer.totalLines != _knownTotalLines) {
      _deferredLayoutNeeded = false;
      markNeedsLayout();
    }
    markNeedsPaint();
  }

  @override
  void detach() {
    _buffer.removeListener(_onBufferChanged);
    _offset.removeListener(_onScrollOffsetChanged);
    _pendingMissingFirst = -1;
    _pendingMissingLast = -1;
    super.detach();
  }

  @override
  void dispose() {
    for (final tp in _glyphCache.values) {
      tp.dispose();
    }
    _glyphCache.clear();
    super.dispose();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool hitTestSelf(Offset position) => true;

  void _scheduleDeferredLayout() {
    _deferredLayoutNeeded = true;
    if (!_deferredLayoutScheduled && attached) {
      _deferredLayoutScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _deferredLayoutScheduled = false;
        if (attached && _deferredLayoutNeeded) {
          _deferredLayoutNeeded = false;
          super.markNeedsLayout();
        }
      });
    }
  }

  @override
  void markNeedsLayout() {
    if (_inPerformLayout) {
      markNeedsPaint();
      if (_deferredLayoutNeeded ||
          _layoutInputsConsumed ||
          _metricsDirty ||
          _hasPendingMetricsNotification) {
        _scheduleDeferredLayout();
      }
      return;
    }
    _deferredLayoutNeeded = false;
    super.markNeedsLayout();
  }

  void _onBufferChanged() {
    if (_inPerformLayout) {
      markNeedsPaint();
      if (_layoutInputsConsumed && _buffer.totalLines != _knownTotalLines) {
        _scheduleDeferredLayout();
      }
      return;
    }
    if (_buffer.totalLines != _knownTotalLines) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  void _onScrollOffsetChanged() {
    markNeedsPaint();
  }

  double get _safeFontSize =>
      (_fontSize.isFinite && _fontSize > 0.0) ? _fontSize : 14.0;

  double get _safeLineHeightScale =>
      (_lineHeightScale.isFinite && _lineHeightScale > 0.0)
      ? _lineHeightScale
      : 1.2;

  void _ensureCellMetrics() {
    if (!_metricsDirty) return;
    _metricsDirty = false;
    final fontSize = _safeFontSize;
    final lineHeightScale = _safeLineHeightScale;
    final probe = TextPainter(
      text: TextSpan(
        text: 'MMMMMMMMMM',
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontFamilyFallback: kTerminalFontFallbacks,
          fontSize: fontSize,
          height: lineHeightScale,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
    )..layout();
    final measuredW = probe.width / 10.0;
    final measuredH = probe.height;
    probe.dispose();

    final rawW = (measuredW.isFinite && measuredW > 1.0)
        ? measuredW
        : (fontSize * 0.6);
    final rawH = (measuredH.isFinite && measuredH > 2.0)
        ? measuredH.ceilToDouble()
        : (fontSize * lineHeightScale).ceilToDouble();
    _cellWidth = max(1.0, rawW);
    _cellHeight = max(1.0, rawH);
    _glyphBaselineOffset = measuredH.isFinite
        ? max(0.0, (_cellHeight - measuredH) * 0.5)
        : 0.0;
  }

  /// Maps a local pixel [position] inside this [RenderBox] to a virtual buffer
  /// [CellOffset] `(col, virtualRow)`.
  CellOffset getCellOffset(Offset position) {
    final totalLines = max(1, _buffer.totalLines);
    final cols = max(1, _buffer.viewWidth);
    final rawScrollY = _offset.hasPixels ? _offset.pixels : 0.0;
    final scrollY = rawScrollY.isFinite ? rawScrollY : 0.0;
    final dx = position.dx.isFinite ? position.dx : 0.0;
    final dy = position.dy.isFinite ? position.dy : 0.0;
    final col = (dx / _cellWidth).floor().clamp(0, cols - 1);
    final row = ((dy + scrollY) / _cellHeight).floor().clamp(0, totalLines - 1);
    return CellOffset(col, row);
  }

  /// Strictly maps a local pixel [position] to a `(col, virtualRow)` cell
  /// without clamping outside the active grid columns or total rows. Returns
  /// `null` when [position] falls in margin padding or past the last row.
  CellOffset? hitTestCellOffset(Offset position) {
    if (!hasSize || _cellWidth <= 0 || _cellHeight <= 0) return null;
    if (position.dx < 0 ||
        position.dy < 0 ||
        position.dx >= size.width ||
        position.dy >= size.height) {
      return null;
    }
    final cols = _buffer.viewWidth;
    final totalLines = _buffer.totalLines;
    if (cols <= 0 || totalLines <= 0) return null;
    final col = (position.dx / _cellWidth).floor();
    if (col < 0 || col >= cols) return null;
    final scrollY = _offset.hasPixels ? _offset.pixels : 0.0;
    final row = ((position.dy + scrollY) / _cellHeight).floor();
    if (row < 0 || row >= totalLines) return null;
    return CellOffset(col, row);
  }

  /// Returns the detected [TerminalLink] covering local pixel [position], or
  /// `null` when no URL is under that cell.
  TerminalLink? linkAtOffset(Offset position) {
    final cell = hitTestCellOffset(position);
    if (cell == null) return null;
    if (identical(_cachedLinksBuffer, _buffer) &&
        _cachedLinksRevision == _buffer.revision &&
        _cachedLinksCols == _buffer.viewWidth &&
        cell.y >= _cachedLinksFirstRow &&
        cell.y < _cachedLinksLastRow) {
      for (final link in _cachedLinks) {
        if (link.containsCell(cell)) return link;
      }
      return null;
    }
    return detectLinkAtCell(_buffer, cell);
  }

  /// Maps a local pixel [position] inside this [RenderBox] to a 0-based
  /// viewport `(col, row)` coordinate (`0 .. viewWidth - 1`, `0 .. viewHeight - 1`),
  /// aligned with [paint]'s row positions across scrollback slack.
  CellOffset getViewportCellOffset(Offset position) {
    final cols = max(1, _buffer.viewWidth);
    final rows = max(1, _buffer.viewHeight);
    final rawScrollY = _offset.hasPixels ? _offset.pixels : 0.0;
    final scrollY = rawScrollY.isFinite ? rawScrollY : 0.0;
    final dx = position.dx.isFinite ? position.dx : 0.0;
    final dy = position.dy.isFinite ? position.dy : 0.0;
    final col = (dx / _cellWidth).floor().clamp(0, cols - 1);
    final virtualRow = ((dy + scrollY) / _cellHeight).floor();
    final row = (virtualRow - _buffer.totalScrollbackRows).clamp(0, rows - 1);
    return CellOffset(col, row);
  }

  /// Maps a virtual buffer [cell] back to local pixel coordinates inside this
  /// [RenderBox] (taking the current scroll offset into account).
  Offset getOffset(CellOffset cell) {
    final rawScrollY = _offset.hasPixels ? _offset.pixels : 0.0;
    final scrollY = rawScrollY.isFinite ? rawScrollY : 0.0;
    return Offset(cell.x * _cellWidth, cell.y * _cellHeight - scrollY);
  }

  @override
  void performLayout() {
    _inPerformLayout = true;
    _layoutInputsConsumed = false;
    _deferredLayoutNeeded = false;
    try {
      _ensureCellMetrics();
      final fallbackCols = max(2, _fittedCols);
      final fallbackRows = max(1, _fittedRows);
      final fallbackW = fallbackCols * _cellWidth;
      final fallbackH = fallbackRows * _cellHeight;
      size = constraints.constrain(
        Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : fallbackW,
          constraints.hasBoundedHeight ? constraints.maxHeight : fallbackH,
        ),
      );

      final hasValidViewport =
          size.width >= _cellWidth && size.height >= _cellHeight;
      if (hasValidViewport) {
        final nextCols =
            (!constraints.hasBoundedWidth && size.width == fallbackW)
            ? fallbackCols
            : max(2, (size.width / _cellWidth).floor());
        final nextRows =
            (!constraints.hasBoundedHeight && size.height == fallbackH)
            ? fallbackRows
            : max(1, (size.height / _cellHeight).floor());
        _fittedCols = nextCols;
        _fittedRows = nextRows;

        final callback = _onGridMetricsChanged;
        final metricsDiffer =
            _fittedCols != _notifiedCols ||
            _fittedRows != _notifiedRows ||
            _cellWidth != _notifiedCellWidth ||
            _cellHeight != _notifiedCellHeight;
        if (_autoResize && callback != null && metricsDiffer) {
          _notifiedCols = _fittedCols;
          _notifiedRows = _fittedRows;
          _notifiedCellWidth = _cellWidth;
          _notifiedCellHeight = _cellHeight;
          callback(_fittedCols, _fittedRows, _cellWidth, _cellHeight);
        }
      }

      final totalLines = _buffer.totalLines;
      _knownTotalLines = totalLines;
      _layoutInputsConsumed = true;
      final contentHeight = max(size.height, totalLines * _cellHeight);
      final newMaxExtent = max(0.0, contentHeight - size.height);

      _offset.applyViewportDimension(size.height);

      // Apply stick-to-bottom correction BEFORE applyContentDimensions so
      // ScrollPosition's `_lastMetrics.pixels` and `pixels` remain in lockstep
      // without launching zero-velocity ballistic scroll activities.
      if (_offset.hasPixels) {
        final currentPixels = _offset.pixels;
        if (!currentPixels.isFinite) {
          final targetPixels = currentPixels.isNaN
              ? (_stickToBottom ? newMaxExtent : 0.0)
              : (currentPixels > 0.0 ? newMaxExtent : 0.0);
          if (_offset is ScrollPosition) {
            (_offset as ScrollPosition).correctPixels(targetPixels);
          }
        } else {
          final wasAtBottom = currentPixels >= _lastMaxScrollExtent - 0.5;
          if (_stickToBottom && wasAtBottom && newMaxExtent != currentPixels) {
            _offset.correctBy(newMaxExtent - currentPixels);
          } else if (currentPixels > newMaxExtent) {
            _offset.correctBy(newMaxExtent - currentPixels);
          } else if (currentPixels < 0.0) {
            _offset.correctBy(-currentPixels);
          }
        }
      }
      _lastMaxScrollExtent = newMaxExtent;
      _offset.applyContentDimensions(0.0, newMaxExtent);
    } finally {
      _inPerformLayout = false;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRect(offset & size);

    final reverseScreen = _buffer.reverseVideo;
    final defaultFg = reverseScreen
        ? TriageTerminalPalette.background
        : TriageTerminalPalette.foreground;
    final defaultBg = reverseScreen
        ? TriageTerminalPalette.foreground
        : TriageTerminalPalette.background;

    final bgPaint = Paint()..style = PaintingStyle.fill;
    bgPaint.color = defaultBg;
    canvas.drawRect(offset & size, bgPaint);

    final rawScrollY = _offset.hasPixels ? _offset.pixels : 0.0;
    final scrollY = rawScrollY.isFinite ? rawScrollY : 0.0;
    final totalLines = _buffer.totalLines;
    if (totalLines <= 0) {
      canvas.restore();
      return;
    }

    final firstRow = (scrollY / _cellHeight).floor().clamp(0, totalLines - 1);
    final lastRowExclusive = ((scrollY + size.height) / _cellHeight)
        .ceil()
        .clamp(firstRow + 1, totalLines);
    final gridCols = _buffer.viewWidth;

    int? missingMin;
    int? missingMax;

    final sel = _selection;
    final selPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = TriageTerminalPalette.selection;
    final skeletonPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x1874838a);

    for (
      var virtualRow = firstRow;
      virtualRow < lastRowExclusive;
      virtualRow++
    ) {
      final rowTop = offset.dy + virtualRow * _cellHeight - scrollY;
      final line = _buffer.lineAtVirtualRow(virtualRow, touchCache: true);

      if (line == null) {
        missingMin = missingMin == null
            ? virtualRow
            : min(missingMin, virtualRow);
        missingMax = missingMax == null
            ? virtualRow
            : max(missingMax, virtualRow);
        // Subtle deterministic placeholder bar while FetchTerminalRows resolves.
        final pseudoCols = 14 + ((virtualRow * 17) % 34);
        final barW = min(size.width * 0.75, pseudoCols * _cellWidth);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              offset.dx + 2,
              rowTop + _cellHeight * 0.28,
              barW,
              _cellHeight * 0.42,
            ),
            const Radius.circular(3),
          ),
          skeletonPaint,
        );
        continue;
      }

      // 1. Merged non-default cell background runs.
      final maxStored = min(line.storedCols, gridCols);
      var runStart = -1;
      Color? runBg;
      for (var col = 0; col < maxStored; col++) {
        final cellBg = _effectiveCellBackground(
          line,
          col,
          defaultFg,
          defaultBg,
        );
        final nonDefault = cellBg != defaultBg;
        if (nonDefault) {
          if (runStart < 0) {
            runStart = col;
            runBg = cellBg;
          } else if (runBg != cellBg) {
            bgPaint.color = runBg!;
            canvas.drawRect(
              Rect.fromLTWH(
                offset.dx + runStart * _cellWidth,
                rowTop,
                (col - runStart) * _cellWidth,
                _cellHeight,
              ),
              bgPaint,
            );
            runStart = col;
            runBg = cellBg;
          }
        } else if (runStart >= 0) {
          bgPaint.color = runBg!;
          canvas.drawRect(
            Rect.fromLTWH(
              offset.dx + runStart * _cellWidth,
              rowTop,
              (col - runStart) * _cellWidth,
              _cellHeight,
            ),
            bgPaint,
          );
          runStart = -1;
          runBg = null;
        }
      }
      if (runStart >= 0 && runBg != null) {
        bgPaint.color = runBg;
        canvas.drawRect(
          Rect.fromLTWH(
            offset.dx + runStart * _cellWidth,
            rowTop,
            (maxStored - runStart) * _cellWidth,
            _cellHeight,
          ),
          bgPaint,
        );
      }

      // 2. Selection highlight on this row.
      if (sel != null) {
        final selCols = sel.selectedColsOnRow(_buffer, virtualRow);
        if (selCols != null) {
          canvas.drawRect(
            Rect.fromLTWH(
              offset.dx + selCols.$1 * _cellWidth,
              rowTop,
              (selCols.$2 - selCols.$1) * _cellWidth,
              _cellHeight,
            ),
            selPaint,
          );
        }
      }

      // 3. Foregrounds, box-drawing/block elements, and text decorations.
      for (var col = 0; col < maxStored; col++) {
        final cp = line.getCodePoint(col);
        final width = line.getWidth(col);
        if (cp == 0 && width == 0) {
          // Trailing half of a wide glyph.
          continue;
        }
        final attrs = line.getAttrs(col);
        if ((attrs & kAttrInvisible) != 0) {
          continue;
        }
        final fg = _effectiveCellForeground(line, col, defaultFg, defaultBg);
        final cellX = offset.dx + col * _cellWidth;
        final spanWidth = (width == 2 ? 2 : 1) * _cellWidth;

        final hasExtraCombining = line.getCombining(col)?.isNotEmpty ?? false;
        if (cp != 0 && (cp != 0x20 || hasExtraCombining)) {
          final paintedVector =
              !hasExtraCombining &&
              cp >= 0x2500 &&
              cp <= 0x259F &&
              _tryPaintBoxOrBlock(
                canvas,
                cp,
                Rect.fromLTWH(cellX, rowTop, spanWidth, _cellHeight),
                fg,
              );
          if (!paintedVector) {
            final glyph = line.cellGlyph(col);
            if (glyph.isNotEmpty) {
              final tp = _obtainGlyphPainter(glyph, fg, attrs);
              tp.paint(canvas, Offset(cellX, rowTop + _glyphBaselineOffset));
            }
          }
        }

        if ((attrs & (kAttrUnderline | kAttrStrikethrough | kAttrOverline)) !=
            0) {
          _paintCellDecorations(
            canvas,
            Rect.fromLTWH(cellX, rowTop, spanWidth, _cellHeight),
            fg,
            attrs,
          );
        }
      }
    }

    // 4. Detected URL underlines (passive + hovered).
    _paintLinks(
      canvas,
      offset,
      scrollY,
      firstRow,
      lastRowExclusive,
      gridCols,
      defaultFg,
      defaultBg,
    );

    // 5. Cursor rendering.
    if (_showCursor && _buffer.cursorVisible) {
      final cursorVirtualRow = _buffer.totalScrollbackRows + _buffer.cursorY;
      if (cursorVirtualRow >= firstRow && cursorVirtualRow < lastRowExclusive) {
        _paintCursor(
          canvas,
          offset,
          scrollY,
          cursorVirtualRow,
          defaultFg,
          defaultBg,
        );
      }
    }

    canvas.restore();

    if (missingMin != null &&
        missingMax != null &&
        onMissingRowsVisible != null) {
      _scheduleMissingRowsNotification(missingMin, missingMax);
    }
  }

  List<TerminalLink> _visibleLinks(int firstRow, int lastRowExclusive) {
    final rev = _buffer.revision;
    final cols = _buffer.viewWidth;
    if (!identical(_cachedLinksBuffer, _buffer) ||
        _cachedLinksRevision != rev ||
        _cachedLinksCols != cols ||
        _cachedLinksFirstRow != firstRow ||
        _cachedLinksLastRow != lastRowExclusive) {
      _cachedLinksBuffer = _buffer;
      _cachedLinksRevision = rev;
      _cachedLinksCols = cols;
      _cachedLinksFirstRow = firstRow;
      _cachedLinksLastRow = lastRowExclusive;
      _cachedLinks = detectLinksInRowRange(_buffer, firstRow, lastRowExclusive);
    }
    return _cachedLinks;
  }

  void _paintLinks(
    Canvas canvas,
    Offset offset,
    double scrollY,
    int firstRow,
    int lastRowExclusive,
    int gridCols,
    Color defaultFg,
    Color defaultBg,
  ) {
    final links = _visibleLinks(firstRow, lastRowExclusive);
    if (links.isEmpty) return;

    final linkPaint = Paint()..style = PaintingStyle.stroke;

    for (final link in links) {
      final isHovered = link == _hoveredLink;
      linkPaint.strokeWidth = isHovered ? 1.5 : 1.0;

      for (final seg in link.segments) {
        if (seg.virtualRow < firstRow || seg.virtualRow >= lastRowExclusive) {
          continue;
        }
        final line = _buffer.lineAtVirtualRow(seg.virtualRow);
        if (line == null) continue;
        final segStart = seg.startCol.clamp(0, gridCols);
        final segEnd = seg.endCol.clamp(segStart, gridCols);
        if (segEnd <= segStart) continue;

        final underlineY =
            offset.dy + (seg.virtualRow + 1) * _cellHeight - scrollY - 1.5;

        if (isHovered) {
          linkPaint.color = TriageTerminalPalette.cursor;
          canvas.drawLine(
            Offset(offset.dx + segStart * _cellWidth, underlineY),
            Offset(offset.dx + segEnd * _cellWidth, underlineY),
            linkPaint,
          );
          continue;
        }

        var runStart = -1;
        Color? runColor;
        for (var col = segStart; col < segEnd; col++) {
          final attrs = line.getAttrs(col);
          final skip = (attrs & (kAttrUnderline | kAttrInvisible)) != 0;
          if (skip) {
            if (runStart >= 0 && runColor != null) {
              linkPaint.color = runColor.withValues(alpha: 0.45);
              canvas.drawLine(
                Offset(offset.dx + runStart * _cellWidth, underlineY),
                Offset(offset.dx + col * _cellWidth, underlineY),
                linkPaint,
              );
              runStart = -1;
              runColor = null;
            }
            continue;
          }
          final fg = _effectiveCellForeground(line, col, defaultFg, defaultBg);
          if (runStart < 0) {
            runStart = col;
            runColor = fg;
          } else if (runColor != fg) {
            linkPaint.color = runColor!.withValues(alpha: 0.45);
            canvas.drawLine(
              Offset(offset.dx + runStart * _cellWidth, underlineY),
              Offset(offset.dx + col * _cellWidth, underlineY),
              linkPaint,
            );
            runStart = col;
            runColor = fg;
          }
        }
        if (runStart >= 0 && runColor != null) {
          linkPaint.color = runColor.withValues(alpha: 0.45);
          canvas.drawLine(
            Offset(offset.dx + runStart * _cellWidth, underlineY),
            Offset(offset.dx + segEnd * _cellWidth, underlineY),
            linkPaint,
          );
        }
      }
    }
  }

  void _scheduleMissingRowsNotification(int first, int last) {
    _pendingMissingFirst = _pendingMissingFirst < 0
        ? first
        : min(_pendingMissingFirst, first);
    _pendingMissingLast = max(_pendingMissingLast, last);
    if (_missingNotifyScheduled) return;
    _missingNotifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _missingNotifyScheduled = false;
      final f = _pendingMissingFirst;
      final l = _pendingMissingLast;
      _pendingMissingFirst = -1;
      _pendingMissingLast = -1;
      if (!attached) return;
      final maxScrollback = _buffer.totalScrollbackRows;
      if (maxScrollback <= 0) return;
      final clampedLast = min(l, maxScrollback - 1);
      if (f >= 0 && clampedLast >= f) {
        onMissingRowsVisible?.call(f, clampedLast);
      }
    });
  }

  Color _effectiveCellForeground(
    TerminalCellLine line,
    int col,
    Color defaultFg,
    Color defaultBg,
  ) {
    final attrs = line.getAttrs(col);
    final inverse = (attrs & kAttrInverse) != 0;
    final fgEnc = line.getFg(col);
    final bgEnc = line.getBg(col);

    Color resolved;
    if (inverse) {
      resolved = bgEnc == kColorNormal
          ? defaultBg
          : TriageTerminalPalette.resolveBackground(bgEnc);
    } else {
      resolved = fgEnc == kColorNormal
          ? defaultFg
          : TriageTerminalPalette.resolveForeground(fgEnc);
    }
    if ((attrs & kAttrFaint) != 0) {
      resolved = resolved.withValues(alpha: 0.62);
    }
    return resolved;
  }

  Color _effectiveCellBackground(
    TerminalCellLine line,
    int col,
    Color defaultFg,
    Color defaultBg,
  ) {
    final attrs = line.getAttrs(col);
    final inverse = (attrs & kAttrInverse) != 0;
    if (inverse) {
      final fgEnc = line.getFg(col);
      return fgEnc == kColorNormal
          ? defaultFg
          : TriageTerminalPalette.resolveForeground(fgEnc);
    }
    final bgEnc = line.getBg(col);
    return bgEnc == kColorNormal
        ? defaultBg
        : TriageTerminalPalette.resolveBackground(bgEnc);
  }

  TextPainter _obtainGlyphPainter(String glyph, Color fg, int attrs) {
    final styleMask =
        ((attrs & kAttrBold) != 0 ? 1 : 0) |
        ((attrs & kAttrItalic) != 0 ? 2 : 0);
    final key = _GlyphCacheKey(glyph, fg.toARGB32(), styleMask);
    final hit = _glyphCache.remove(key);
    if (hit != null) {
      _glyphCache[key] = hit;
      return hit;
    }

    while (_glyphCache.length >= _maxGlyphCacheEntries) {
      final oldestKey = _glyphCache.keys.first;
      _glyphCache.remove(oldestKey)?.dispose();
    }

    final tp = TextPainter(
      text: TextSpan(
        text: glyph,
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontFamilyFallback: kTerminalFontFallbacks,
          fontSize: _safeFontSize,
          height: _safeLineHeightScale,
          color: fg,
          fontWeight: (attrs & kAttrBold) != 0
              ? FontWeight.bold
              : FontWeight.normal,
          fontStyle: (attrs & kAttrItalic) != 0
              ? FontStyle.italic
              : FontStyle.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
    )..layout();
    _glyphCache[key] = tp;
    return tp;
  }

  void _paintCellDecorations(Canvas canvas, Rect rect, Color fg, int attrs) {
    final paint = Paint()
      ..color = fg
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    if ((attrs & kAttrOverline) != 0) {
      final y = rect.top + 0.5;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
    }
    if ((attrs & kAttrStrikethrough) != 0) {
      final y = rect.top + rect.height * 0.52;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
    }
    if ((attrs & kAttrUnderline) != 0) {
      final baseY = rect.bottom - 1.5;
      if ((attrs & kAttrDoubleUnderline) != 0) {
        canvas.drawLine(
          Offset(rect.left, baseY - 2.0),
          Offset(rect.right, baseY - 2.0),
          paint,
        );
        canvas.drawLine(
          Offset(rect.left, baseY),
          Offset(rect.right, baseY),
          paint,
        );
      } else if ((attrs & kAttrUndercurl) != 0) {
        final path = Path()..moveTo(rect.left, baseY);
        const steps = 6;
        final dx = rect.width / steps;
        for (var i = 1; i <= steps; i++) {
          final x = rect.left + dx * i;
          final y = baseY + sin((i / steps) * 2 * pi) * 1.3;
          path.lineTo(x, y);
        }
        canvas.drawPath(path, paint);
      } else if ((attrs & kAttrDottedUnderline) != 0) {
        var x = rect.left;
        while (x < rect.right) {
          canvas.drawLine(
            Offset(x, baseY),
            Offset(min(rect.right, x + 1.5), baseY),
            paint,
          );
          x += 3.0;
        }
      } else if ((attrs & kAttrDashedUnderline) != 0) {
        var x = rect.left;
        while (x < rect.right) {
          canvas.drawLine(
            Offset(x, baseY),
            Offset(min(rect.right, x + 3.5), baseY),
            paint,
          );
          x += 5.5;
        }
      } else {
        canvas.drawLine(
          Offset(rect.left, baseY),
          Offset(rect.right, baseY),
          paint,
        );
      }
    }
  }

  void _paintCursor(
    Canvas canvas,
    Offset offset,
    double scrollY,
    int cursorVirtualRow,
    Color defaultFg,
    Color defaultBg,
  ) {
    final col = _buffer.cursorX;
    final line = _buffer.lineAtVirtualRow(cursorVirtualRow);
    final cellWidthUnits = (line != null && line.getWidth(col) == 2) ? 2 : 1;
    final cursorRect = Rect.fromLTWH(
      offset.dx + col * _cellWidth,
      offset.dy + cursorVirtualRow * _cellHeight - scrollY,
      cellWidthUnits * _cellWidth,
      _cellHeight,
    );

    if (!_hasFocus) {
      final outlinePaint = Paint()
        ..color = TriageTerminalPalette.cursor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawRect(cursorRect.deflate(0.6), outlinePaint);
      return;
    }

    final fillPaint = Paint()
      ..color = TriageTerminalPalette.cursor
      ..style = PaintingStyle.fill;

    switch (_buffer.cursorShape) {
      case TerminalCursorShape.blinkingUnderline:
      case TerminalCursorShape.steadyUnderline:
        canvas.drawRect(
          Rect.fromLTWH(
            cursorRect.left,
            cursorRect.bottom - 2.0,
            cursorRect.width,
            2.0,
          ),
          fillPaint,
        );
      case TerminalCursorShape.blinkingBar:
      case TerminalCursorShape.steadyBar:
        canvas.drawRect(
          Rect.fromLTWH(
            cursorRect.left,
            cursorRect.top,
            2.0,
            cursorRect.height,
          ),
          fillPaint,
        );
      case TerminalCursorShape.defaultShape:
      case TerminalCursorShape.blinkingBlock:
      case TerminalCursorShape.steadyBlock:
        canvas.drawRect(cursorRect, fillPaint);
        if (line != null && col < line.storedCols) {
          final cellAttrs = line.getAttrs(col);
          final cp = line.getCodePoint(col);
          final hasExtraCombining = line.getCombining(col)?.isNotEmpty ?? false;
          if ((cellAttrs & kAttrInvisible) == 0 &&
              cp != 0 &&
              (cp != 0x20 || hasExtraCombining)) {
            final glyph = line.cellGlyph(col);
            if (glyph.isNotEmpty) {
              final tp = _obtainGlyphPainter(
                glyph,
                TriageTerminalPalette.background,
                cellAttrs,
              );
              tp.paint(
                canvas,
                Offset(cursorRect.left, cursorRect.top + _glyphBaselineOffset),
              );
            }
          }
        }
    }
  }

  /// Crisp vector rendering for common box-drawing (`U+2500..U+257F`) and block
  /// element (`U+2580..U+259F`) codepoints so TUI borders align edge-to-edge
  /// without font-metric seams. Returns `false` to fall back to font shaping
  /// for specialized mixed glyphs.
  bool _tryPaintBoxOrBlock(Canvas canvas, int cp, Rect rect, Color fg) {
    // Block elements U+2580..U+259F
    if (cp >= 0x2580 && cp <= 0x259F) {
      final fill = Paint()
        ..color = fg
        ..style = PaintingStyle.fill;
      switch (cp) {
        case 0x2580: // Upper half block ▀
          canvas.drawRect(
            Rect.fromLTWH(rect.left, rect.top, rect.width, rect.height * 0.5),
            fill,
          );
          return true;
        case 0x2581:
        case 0x2582:
        case 0x2583:
        case 0x2584:
        case 0x2585:
        case 0x2586:
        case 0x2587:
        case 0x2588: // Lower 1/8 .. Full block █
          final frac = (cp - 0x2580) / 8.0;
          final h = rect.height * frac;
          canvas.drawRect(
            Rect.fromLTWH(rect.left, rect.bottom - h, rect.width, h),
            fill,
          );
          return true;
        case 0x2589:
        case 0x258A:
        case 0x258B:
        case 0x258C:
        case 0x258D:
        case 0x258E:
        case 0x258F: // Left 7/8 .. Left 1/8 block
          final frac = (8 - (cp - 0x2588)) / 8.0;
          canvas.drawRect(
            Rect.fromLTWH(rect.left, rect.top, rect.width * frac, rect.height),
            fill,
          );
          return true;
        case 0x2590: // Right half block ▐
          canvas.drawRect(
            Rect.fromLTWH(
              rect.left + rect.width * 0.5,
              rect.top,
              rect.width * 0.5,
              rect.height,
            ),
            fill,
          );
          return true;
        case 0x2591: // Light shade ░
          fill.color = fg.withValues(alpha: 0.25 * fg.a);
          canvas.drawRect(rect, fill);
          return true;
        case 0x2592: // Medium shade ▒
          fill.color = fg.withValues(alpha: 0.50 * fg.a);
          canvas.drawRect(rect, fill);
          return true;
        case 0x2593: // Dark shade ▓
          fill.color = fg.withValues(alpha: 0.75 * fg.a);
          canvas.drawRect(rect, fill);
          return true;
        case 0x2594: // Upper 1/8 block ▔
          canvas.drawRect(
            Rect.fromLTWH(rect.left, rect.top, rect.width, rect.height / 8.0),
            fill,
          );
          return true;
        case 0x2595: // Right 1/8 block ▕
          final w = rect.width / 8.0;
          canvas.drawRect(
            Rect.fromLTWH(rect.right - w, rect.top, w, rect.height),
            fill,
          );
          return true;
        default:
          return false;
      }
    }

    // Core light / heavy / rounded box-drawing lines & corners
    final cx = rect.left + rect.width * 0.5;
    final cy = rect.top + rect.height * 0.5;
    // Bitmask: 1=left, 2=right, 4=up, 8=down; bit 4=heavy, bit 5=rounded
    final int? spec = switch (cp) {
      0x2500 => 1 | 2, // ─
      0x2501 => 1 | 2 | 16, // ━
      0x2502 => 4 | 8, // │
      0x2503 => 4 | 8 | 16, // ┃
      0x250C => 2 | 8, // ┌
      0x250F => 2 | 8 | 16, // ┏
      0x2510 => 1 | 8, // ┐
      0x2513 => 1 | 8 | 16, // ┓
      0x2514 => 2 | 4, // └
      0x2517 => 2 | 4 | 16, // ┗
      0x2518 => 1 | 4, // ┘
      0x251B => 1 | 4 | 16, // ┛
      0x251C => 4 | 8 | 2, // ├
      0x2523 => 4 | 8 | 2 | 16, // ┣
      0x2524 => 4 | 8 | 1, // ┤
      0x252B => 4 | 8 | 1 | 16, // ┫
      0x252C => 1 | 2 | 8, // ┬
      0x2533 => 1 | 2 | 8 | 16, // ┳
      0x2534 => 1 | 2 | 4, // ┴
      0x253B => 1 | 2 | 4 | 16, // ┻
      0x253C => 1 | 2 | 4 | 8, // ┼
      0x254B => 1 | 2 | 4 | 8 | 16, // ╋
      0x256D => 2 | 8 | 32, // ╭
      0x256E => 1 | 8 | 32, // ╮
      0x256F => 1 | 4 | 32, // ╯
      0x2570 => 2 | 4 | 32, // ╰
      0x2574 => 1, // ╴
      0x2575 => 4, // ╵
      0x2576 => 2, // ╶
      0x2577 => 8, // ╷
      0x2578 => 1 | 16, // ╸
      0x2579 => 4 | 16, // ╹
      0x257A => 2 | 16, //╺
      0x257B => 8 | 16, // ╻
      _ => null,
    };
    if (spec == null) return false;

    final heavy = (spec & 16) != 0;
    final rounded = (spec & 32) != 0;
    final stroke = Paint()
      ..color = fg
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square
      ..strokeWidth = heavy ? 2.0 : 1.0;

    if (rounded) {
      final path = Path();
      if ((spec & (2 | 8)) == (2 | 8)) {
        // ╭
        path
          ..moveTo(rect.right, cy)
          ..quadraticBezierTo(cx, cy, cx, rect.bottom);
      } else if ((spec & (1 | 8)) == (1 | 8)) {
        // ╮
        path
          ..moveTo(rect.left, cy)
          ..quadraticBezierTo(cx, cy, cx, rect.bottom);
      } else if ((spec & (1 | 4)) == (1 | 4)) {
        // ╯
        path
          ..moveTo(rect.left, cy)
          ..quadraticBezierTo(cx, cy, cx, rect.top);
      } else if ((spec & (2 | 4)) == (2 | 4)) {
        // ╰
        path
          ..moveTo(rect.right, cy)
          ..quadraticBezierTo(cx, cy, cx, rect.top);
      }
      canvas.drawPath(path, stroke);
      return true;
    }

    if ((spec & 1) != 0) {
      canvas.drawLine(Offset(rect.left, cy), Offset(cx, cy), stroke);
    }
    if ((spec & 2) != 0) {
      canvas.drawLine(Offset(cx, cy), Offset(rect.right, cy), stroke);
    }
    if ((spec & 4) != 0) {
      canvas.drawLine(Offset(cx, rect.top), Offset(cx, cy), stroke);
    }
    if ((spec & 8) != 0) {
      canvas.drawLine(Offset(cx, cy), Offset(cx, rect.bottom), stroke);
    }
    return true;
  }
}
