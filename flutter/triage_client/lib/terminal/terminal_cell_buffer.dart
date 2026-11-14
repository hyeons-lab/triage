import 'dart:collection';
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';

const int kScrollbackPageSize = 128;
const int kMaxResidentScrollbackPages = 64;
const int kDaemonReflowWindowRows = 3600;

final Uint32List _emptyCellWords = Uint32List(0);

/// One logical row of terminal cells decoded from `TCG1`.
class TerminalCellLine {
  const TerminalCellLine({
    required this.storedCols,
    required this.logicalCols,
    required this.flags,
    required this.cellWords,
    this.combining,
  });

  factory TerminalCellLine.blank(int cols) {
    return TerminalCellLine(
      storedCols: 0,
      logicalCols: max(1, cols),
      flags: 0,
      cellWords: _emptyCellWords,
    );
  }

  factory TerminalCellLine.fromDecoded(
    DecodedTcg1Row row, {
    int? fallbackCols,
  }) {
    final cols = row.logicalCols > 0
        ? row.logicalCols
        : max(1, fallbackCols ?? max(1, row.storedCols));
    return TerminalCellLine(
      storedCols: row.storedCols,
      logicalCols: max(cols, row.storedCols),
      flags: row.flags,
      cellWords: row.cellWords,
      combining: row.combining,
    );
  }

  /// Builds a cell line from a compact test specification where `null`
  /// represents an unwritten cursor-skip blank (`codePoint == 0`) or the
  /// trailing cell after a wide (`width == 2`) glyph.
  factory TerminalCellLine.fromSpec(
    List<String?> cells, {
    int? width,
    bool wrapsNext = false,
  }) {
    final logicalCols = max(1, width ?? max(1, cells.length));
    final words = Uint32List(cells.length * kCellWords);
    Map<int, List<int>>? combining;
    var storedCols = 0;

    for (var i = 0; i < cells.length; i++) {
      final cell = cells[i];
      final base = i * kCellWords;
      if (cell == null) {
        final prevIsWide =
            i > 0 &&
            ((words[(i - 1) * kCellWords + 3] >>> kContentWidthShift) & 0x3) ==
                2;
        words[base + 3] = prevIsWide ? 0 : (1 << kContentWidthShift);
        continue;
      }
      final runes = cell.runes.toList();
      if (runes.isEmpty) {
        words[base + 3] = 1 << kContentWidthShift;
        continue;
      }
      final first = sanitizeTerminalCodePoint(runes.first);
      final w = (_isWideCodePoint(first) && i + 1 < cells.length) ? 2 : 1;
      words[base + 3] =
          (first & kContentCodepointMask) | (w << kContentWidthShift);
      if (runes.length > 1) {
        combining ??= <int, List<int>>{};
        combining[i] = <int>[
          for (final r in runes.sublist(1))
            sanitizeTerminalCodePoint(r == 0 ? 0xFFFD : r),
        ];
      }
      storedCols = i + w;
    }
    storedCols = min(storedCols, cells.length);
    var flags = wrapsNext ? kLineFlagWrapsNext : 0;
    if (combining != null && combining.isNotEmpty) {
      flags |= kLineFlagHasCombining;
    }
    return TerminalCellLine(
      storedCols: storedCols,
      logicalCols: max(logicalCols, storedCols),
      flags: flags,
      cellWords: storedCols == cells.length
          ? words
          : Uint32List.sublistView(words, 0, storedCols * kCellWords),
      combining: combining,
    );
  }

  final int storedCols;
  final int logicalCols;
  final int flags;
  final Uint32List cellWords;
  final Map<int, List<int>>? combining;

  int get length => logicalCols;

  /// True when this row soft-wrapped onto `row + 1` (no hard newline).
  bool get wrapsNext => (flags & kLineFlagWrapsNext) != 0;

  int getFg(int col) {
    if (col < 0 || col >= storedCols) return kColorNormal;
    return cellWords[col * kCellWords];
  }

  int getBg(int col) {
    if (col < 0 || col >= storedCols) return kColorNormal;
    return cellWords[col * kCellWords + 1];
  }

  int getAttrs(int col) {
    if (col < 0 || col >= storedCols) return 0;
    return cellWords[col * kCellWords + 2];
  }

  int getContent(int col) {
    if (col < 0 || col >= storedCols) return 0;
    return cellWords[col * kCellWords + 3];
  }

  int getCodePoint(int col) {
    if (col < 0 || col >= storedCols) return 0;
    return sanitizeTerminalCodePoint(
      cellWords[col * kCellWords + 3] & kContentCodepointMask,
    );
  }

  int getWidth(int col) {
    if (col < 0 || col >= storedCols) return 1;
    return (cellWords[col * kCellWords + 3] >>> kContentWidthShift) & 0x3;
  }

  List<int>? getCombining(int col) => combining?[col];

  String cellGlyph(int col) {
    final cp = getCodePoint(col);
    if (cp == 0) return '';
    final extra = combining?[col];
    if (extra == null || extra.isEmpty) {
      return String.fromCharCode(cp);
    }
    return String.fromCharCodes(<int>[
      cp,
      for (final c in extra) sanitizeTerminalCodePoint(c == 0 ? 0xFFFD : c),
    ]);
  }

  String toPlainText() {
    if (storedCols <= 0) return '';
    var lastGlyph = wrapsNext ? storedCols - 1 : -1;
    if (!wrapsNext) {
      for (var i = 0; i < storedCols; i++) {
        final cp = getCodePoint(i);
        if (cp != 0 && cp != 0x20) {
          lastGlyph = i;
        } else if (cp == 0x20 &&
            (getFg(i) != kColorNormal ||
                getBg(i) != kColorNormal ||
                getAttrs(i) != 0 ||
                (combining?[i]?.isNotEmpty ?? false))) {
          lastGlyph = i;
        }
      }
    }
    if (lastGlyph < 0) return '';
    final out = StringBuffer();
    for (var i = 0; i <= lastGlyph; i++) {
      final cp = getCodePoint(i);
      if (cp != 0) {
        out.writeCharCode(cp);
        final extra = combining?[i];
        if (extra != null) {
          for (final c in extra) {
            out.writeCharCode(sanitizeTerminalCodePoint(c == 0 ? 0xFFFD : c));
          }
        }
      } else {
        final isWideTrailer = i > 0 && getWidth(i - 1) == 2;
        if (!isWideTrailer) {
          out.write(' ');
        }
      }
    }
    return out.toString();
  }

  StyledRow toStyledRow() {
    if (storedCols <= 0) {
      return const StyledRow(spans: <StyledSpan>[]);
    }
    final spans = <StyledSpan>[];
    final buf = StringBuffer();
    TerminalStyle? currentStyle;

    void flush() {
      if (buf.isNotEmpty && currentStyle != null) {
        spans.add(StyledSpan(text: buf.toString(), style: currentStyle));
        buf.clear();
      }
    }

    for (var col = 0; col < storedCols; col++) {
      final cp = getCodePoint(col);
      final width = getWidth(col);
      if (cp == 0 && width == 0 && col > 0 && getWidth(col - 1) == 2) {
        // Wide glyph trailing half.
        continue;
      }
      final style = _cellStyleAt(col);
      if (currentStyle == null || !_sameStyle(currentStyle, style)) {
        flush();
        currentStyle = style;
      }
      if (cp == 0) {
        buf.write(' ');
      } else {
        buf.writeCharCode(cp);
        final extra = combining?[col];
        if (extra != null) {
          for (final c in extra) {
            buf.writeCharCode(sanitizeTerminalCodePoint(c == 0 ? 0xFFFD : c));
          }
        }
      }
    }
    flush();
    return StyledRow(spans: spans);
  }

  TerminalStyle _cellStyleAt(int col) {
    final fgEnc = getFg(col);
    final bgEnc = getBg(col);
    final attrs = getAttrs(col);

    TerminalColor? fgColor;
    if (fgEnc != kColorNormal) {
      final c = TriageTerminalPalette.resolveForeground(fgEnc);
      fgColor = TerminalColor(
        red: (c.r * 255.0).round().clamp(0, 255),
        green: (c.g * 255.0).round().clamp(0, 255),
        blue: (c.b * 255.0).round().clamp(0, 255),
      );
    }
    TerminalColor? bgColor;
    if (bgEnc != kColorNormal) {
      final c = TriageTerminalPalette.resolveBackground(bgEnc);
      bgColor = TerminalColor(
        red: (c.r * 255.0).round().clamp(0, 255),
        green: (c.g * 255.0).round().clamp(0, 255),
        blue: (c.b * 255.0).round().clamp(0, 255),
      );
    }
    return TerminalStyle(
      foreground: fgColor,
      background: bgColor,
      bold: (attrs & kAttrBold) != 0,
      dim: (attrs & kAttrFaint) != 0,
      italic: (attrs & kAttrItalic) != 0,
      underline: (attrs & kAttrUnderline) != 0,
      reverse: (attrs & kAttrInverse) != 0,
    );
  }

  static bool _sameStyle(TerminalStyle a, TerminalStyle b) {
    return a.bold == b.bold &&
        a.dim == b.dim &&
        a.italic == b.italic &&
        a.underline == b.underline &&
        a.reverse == b.reverse &&
        _sameColor(a.foreground, b.foreground) &&
        _sameColor(a.background, b.background);
  }

  static bool _sameColor(TerminalColor? a, TerminalColor? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.red == b.red && a.green == b.green && a.blue == b.blue;
  }

  static bool _isWideCodePoint(int rune) {
    return rune >= 0x1100 &&
        (rune <= 0x115F ||
            rune == 0x2329 ||
            rune == 0x232A ||
            (rune >= 0x2E80 && rune <= 0xA4CF && rune != 0x303F) ||
            (rune >= 0xAC00 && rune <= 0xD7A3) ||
            (rune >= 0xF900 && rune <= 0xFAFF) ||
            (rune >= 0xFE10 && rune <= 0xFE19) ||
            (rune >= 0xFE30 && rune <= 0xFE6F) ||
            (rune >= 0xFF00 && rune <= 0xFF60) ||
            (rune >= 0xFFE0 && rune <= 0xFFE6) ||
            (rune >= 0x1F300 && rune <= 0x1F9FF) ||
            (rune >= 0x20000 && rune <= 0x3FFFD));
  }
}

/// Client-side mirror of a daemon terminal's visible cell grid, terminal modes,
/// and sparse virtual scrollback cache.
///
/// Contains zero VT escape-sequence parsing: every state transition is driven
/// by authoritative `TerminalSyncFrameData` and `TerminalRowsPageData` payloads
/// computed by `triaged`.
class TerminalCellBuffer extends ChangeNotifier {
  TerminalCellBuffer({
    int cols = 80,
    int rows = 24,
    this.onBell,
    this.onTitleChanged,
    this.onOutput,
    this.onResize,
  }) : _viewWidth = cols.clamp(1, kMaxEncodedCols),
       _viewHeight = rows.clamp(1, kMaxViewportRows),
       _viewportLines = List<TerminalCellLine>.generate(
         rows.clamp(1, kMaxViewportRows),
         (_) => TerminalCellLine.blank(cols.clamp(1, kMaxEncodedCols)),
       );

  int _viewWidth;
  int _viewHeight;
  List<TerminalCellLine> _viewportLines;

  int _primaryScrollbackRows = 0;
  int _primaryTrimmedTopRows = 0;
  int _primaryCols = 0;
  int _lastSyncedCols = 0;
  bool _sawAltColResize = false;
  int? _expandedReflowFloorAbs;
  int _reflowGen = 0;
  int _eraseScrollbackGen = 0;
  int? _daemonEraseScrollbackGen;
  bool _scrollbackClearedLocally = false;
  int _lastFrameSeq = 0;
  int _revision = 0;

  int _cursorX = 0;
  int _cursorY = 0;
  TerminalCursorShape _cursorShape = TerminalCursorShape.defaultShape;
  bool _cursorVisible = true;

  bool _isAltScreen = false;
  bool _bracketedPasteMode = false;
  bool _appCursorKeys = false;
  bool _appKeypad = false;
  bool _originMode = false;
  bool _autoWrap = true;
  bool _reportFocus = false;
  bool _reverseVideo = false;
  int _mouseMode = 0;
  int _mouseReportMode = 0;
  int _kittyKeyboardFlags = 0;
  String _title = '';

  /// Optional callbacks invoked on transient frame signals and pane I/O.
  VoidCallback? onBell;
  ValueChanged<String>? onTitleChanged;
  ValueChanged<String>? onOutput;
  void Function(int cols, int rows, int pixelWidth, int pixelHeight)? onResize;

  /// Sparse LRU cache of historical scrollback pages keyed by
  /// `absPageIdx = (trimmedTopRows + virtualRow) ~/ kScrollbackPageSize`.
  /// Using `absoluteRow = trimmedTopRows + virtualRow` keeps cached pages
  /// alignment-invariant when retention trims oldest rows at the top.
  final LinkedHashMap<int, List<TerminalCellLine?>> _absScrollbackPages =
      LinkedHashMap<int, List<TerminalCellLine?>>();

  int get viewWidth => _viewWidth;
  int get viewHeight => _viewHeight;

  int get totalScrollbackRows => _isAltScreen ? 0 : _primaryScrollbackRows;
  int get trimmedTopRows => _isAltScreen ? 0 : _primaryTrimmedTopRows;
  int get totalLines => totalScrollbackRows + _viewHeight;
  int get reflowGen => _reflowGen;
  int get eraseScrollbackGen => _eraseScrollbackGen;
  int get lastFrameSeq => _lastFrameSeq;

  /// Monotonic counter incremented on every buffer mutation.
  int get revision => _revision;

  @override
  void notifyListeners() {
    _revision += 1;
    super.notifyListeners();
  }

  int get cursorX => _cursorX;
  int get cursorY => _cursorY;
  TerminalCursorShape get cursorShape => _cursorShape;
  bool get cursorVisible => _cursorVisible;

  bool get isUsingAltBuffer => _isAltScreen;
  bool get bracketedPasteMode => _bracketedPasteMode;
  bool get appCursorKeys => _appCursorKeys;
  bool get appKeypad => _appKeypad;
  bool get originMode => _originMode;
  bool get autoWrap => _autoWrap;
  bool get reportFocus => _reportFocus;
  bool get reverseVideo => _reverseVideo;
  int get mouseMode => _mouseMode;
  int get mouseReportMode => _mouseReportMode;
  int get kittyKeyboardFlags => _kittyKeyboardFlags;
  String get title => _title;

  int get residentScrollbackPageCount => _absScrollbackPages.length;

  void setBracketedPasteMode(bool enabled) {
    if (_bracketedPasteMode == enabled) return;
    _bracketedPasteMode = enabled;
    notifyListeners();
  }

  void setCursorVisible(bool visible) {
    if (_cursorVisible == visible) return;
    _cursorVisible = visible;
    notifyListeners();
  }

  void clear() {
    _viewportLines = List<TerminalCellLine>.generate(
      _viewHeight,
      (_) => TerminalCellLine.blank(_viewWidth),
    );
    _primaryScrollbackRows = 0;
    _primaryTrimmedTopRows = 0;
    _expandedReflowFloorAbs = null;
    _sawAltColResize = false;
    _eraseScrollbackGen += 1;
    _reflowGen += 1;
    _daemonEraseScrollbackGen = null;
    _scrollbackClearedLocally = true;
    _absScrollbackPages.clear();
    _cursorX = 0;
    _cursorY = 0;
    notifyListeners();
  }

  /// Updates the local viewport dimensions ahead of the daemon's next
  /// `TerminalSync` frame and notifies [onResize] (with [viewWidth] and
  /// [viewHeight] still holding their pre-resize values during the callback,
  /// matching the `TerminalPane` resize hook contract).
  void resize(int cols, int rows, [int pixelWidth = 0, int pixelHeight = 0]) {
    final nextCols = cols.clamp(1, kMaxEncodedCols);
    final nextRows = rows.clamp(1, kMaxViewportRows);
    onResize?.call(nextCols, nextRows, pixelWidth, pixelHeight);
    if (nextCols == _viewWidth && nextRows == _viewHeight) {
      return;
    }
    _viewWidth = nextCols;
    _viewHeight = nextRows;
    _viewportLines = List<TerminalCellLine>.generate(
      _viewHeight,
      (i) => i < _viewportLines.length
          ? _viewportLines[i]
          : TerminalCellLine.blank(_viewWidth),
    );
    _cursorX = _cursorX.clamp(0, max(0, _viewWidth - 1));
    _cursorY = _cursorY.clamp(0, max(0, _viewHeight - 1));
    notifyListeners();
  }

  /// Resets all grid and scrollback state (e.g. before a fresh session load).
  void reset({int cols = 80, int rows = 24}) {
    _viewWidth = cols.clamp(1, kMaxEncodedCols);
    _viewHeight = rows.clamp(1, kMaxViewportRows);
    _viewportLines = List<TerminalCellLine>.generate(
      _viewHeight,
      (_) => TerminalCellLine.blank(_viewWidth),
    );
    _primaryScrollbackRows = 0;
    _primaryTrimmedTopRows = 0;
    _primaryCols = 0;
    _lastSyncedCols = 0;
    _sawAltColResize = false;
    _expandedReflowFloorAbs = null;
    _reflowGen += 1;
    _eraseScrollbackGen += 1;
    _daemonEraseScrollbackGen = null;
    _scrollbackClearedLocally = true;
    _lastFrameSeq = 0;
    _cursorX = 0;
    _cursorY = 0;
    _cursorShape = TerminalCursorShape.defaultShape;
    _cursorVisible = true;
    _isAltScreen = false;
    _bracketedPasteMode = false;
    _appCursorKeys = false;
    _appKeypad = false;
    _originMode = false;
    _autoWrap = true;
    _reportFocus = false;
    _reverseVideo = false;
    _mouseMode = 0;
    _mouseReportMode = 0;
    _kittyKeyboardFlags = 0;
    _title = '';
    _absScrollbackPages.clear();
    notifyListeners();
  }

  /// Applies an authoritative `TerminalSyncFrame` from `SyncTerminal` or
  /// `SessionEvent::TerminalSync`.
  void applySyncFrame(TerminalSyncFrameData frame) {
    final nextRows = frame.rows.clamp(1, kMaxViewportRows);
    final nextCols = frame.cols.clamp(1, kMaxEncodedCols);
    final wasAlt = _isAltScreen;
    final nextAlt = frame.isAltScreen;
    final clampedTotalSb = frame.totalScrollbackRows.clamp(
      0,
      kMaxScrollbackRows,
    );
    final clampedTrimmedTop = frame.trimmedTopRows.clamp(0, kMaxTrimmedTopRows);

    if (!nextAlt && frame.pushedScrollbackRowCount > 0) {
      if (frame.pushedScrollbackStartRow < 0 ||
          frame.pushedScrollbackRowCount > clampedTotalSb ||
          frame.pushedScrollbackStartRow >
              clampedTotalSb - frame.pushedScrollbackRowCount) {
        return;
      }
    } else if (!nextAlt && frame.pushedScrollbackRowCount < 0) {
      return;
    }

    // Decode payloads before mutating state so malformed frames cannot leave
    // the buffer partially updated or blanked.
    final List<DecodedTcg1Row> pushed =
        (!nextAlt &&
            frame.pushedScrollbackPayload.isNotEmpty &&
            frame.pushedScrollbackRowCount > 0)
        ? decodeTcg1Batch(
            frame.pushedScrollbackCompression,
            frame.pushedScrollbackPayload,
          )
        : const <DecodedTcg1Row>[];
    final List<DecodedTcg1Row> decodedRows = frame.viewportPayload.isNotEmpty
        ? decodeTcg1Batch(frame.viewportCompression, frame.viewportPayload)
        : const <DecodedTcg1Row>[];

    final daemonGen = max(0, frame.eraseScrollbackGen);
    final trimmedRegressedOnFull =
        !nextAlt &&
        frame.fullViewport &&
        clampedTrimmedTop < _primaryTrimmedTopRows;
    if (_scrollbackClearedLocally) {
      _scrollbackClearedLocally = false;
      _daemonEraseScrollbackGen = daemonGen;
      if (frame.sawEraseScrollback) {
        _eraseScrollbackGen = max(_eraseScrollbackGen + 1, daemonGen);
        _reflowGen += 1;
        _primaryScrollbackRows = 0;
        _primaryTrimmedTopRows = 0;
        _sawAltColResize = false;
        _expandedReflowFloorAbs = null;
        _absScrollbackPages.clear();
      } else {
        _eraseScrollbackGen = max(_eraseScrollbackGen, daemonGen);
      }
    } else if (_daemonEraseScrollbackGen == null) {
      _daemonEraseScrollbackGen = daemonGen;
      final hadResidentPrimary =
          _primaryScrollbackRows > 0 ||
          _primaryTrimmedTopRows > 0 ||
          _absScrollbackPages.isNotEmpty;
      if (frame.sawEraseScrollback ||
          trimmedRegressedOnFull ||
          (hadResidentPrimary && daemonGen != _eraseScrollbackGen)) {
        _eraseScrollbackGen = max(_eraseScrollbackGen + 1, daemonGen);
        _reflowGen += 1;
        _primaryScrollbackRows = 0;
        _primaryTrimmedTopRows = 0;
        _sawAltColResize = false;
        _expandedReflowFloorAbs = null;
        _absScrollbackPages.clear();
      } else {
        _eraseScrollbackGen = max(_eraseScrollbackGen, daemonGen);
      }
    } else if (daemonGen != _daemonEraseScrollbackGen ||
        frame.sawEraseScrollback ||
        trimmedRegressedOnFull) {
      _daemonEraseScrollbackGen = daemonGen;
      _eraseScrollbackGen = max(_eraseScrollbackGen + 1, daemonGen);
      _reflowGen += 1;
      _primaryScrollbackRows = 0;
      _primaryTrimmedTopRows = 0;
      _sawAltColResize = false;
      _expandedReflowFloorAbs = null;
      _absScrollbackPages.clear();
    }

    if (nextAlt) {
      if (_primaryCols != 0 &&
          (nextCols != _primaryCols ||
              (_lastSyncedCols != 0 && nextCols != _lastSyncedCols))) {
        _reflowGen += 1;
        _sawAltColResize = true;
        final preReflowStartAbs =
            _primaryTrimmedTopRows +
            max<int>(0, _primaryScrollbackRows - kDaemonReflowWindowRows);
        _expandedReflowFloorAbs = _expandedReflowFloorAbs == null
            ? preReflowStartAbs
            : min<int>(_expandedReflowFloorAbs!, preReflowStartAbs);
        final minPage = _expandedReflowFloorAbs! ~/ kScrollbackPageSize;
        _absScrollbackPages.removeWhere((pageIdx, _) => pageIdx >= minPage);
      }
    } else {
      final nextScrollbackRows = clampedTotalSb;
      final nextTrimmedTopRows = frame.fullViewport
          ? clampedTrimmedTop
          : max(_primaryTrimmedTopRows, clampedTrimmedTop);
      final prevAbsEnd = _primaryTrimmedTopRows + _primaryScrollbackRows;
      final nextAbsEnd = nextTrimmedTopRows + nextScrollbackRows;
      final colsChanged =
          (_primaryCols != 0 && _primaryCols != nextCols) || _sawAltColResize;
      if (colsChanged) {
        _reflowGen += 1;
        _sawAltColResize = false;
        final preReflowStartAbs =
            _primaryTrimmedTopRows +
            max<int>(0, _primaryScrollbackRows - kDaemonReflowWindowRows);
        final postReflowStartAbs =
            nextTrimmedTopRows +
            max<int>(0, nextScrollbackRows - kDaemonReflowWindowRows);
        final candidateFloor = min<int>(preReflowStartAbs, postReflowStartAbs);
        final effectiveFloor = _expandedReflowFloorAbs == null
            ? candidateFloor
            : min<int>(_expandedReflowFloorAbs!, candidateFloor);
        if (_primaryCols != 0 && nextCols < _primaryCols ||
            nextScrollbackRows > kDaemonReflowWindowRows) {
          _expandedReflowFloorAbs = effectiveFloor;
        } else if (nextScrollbackRows <= 3500) {
          _expandedReflowFloorAbs = null;
        }
        final minPage = effectiveFloor ~/ kScrollbackPageSize;
        _absScrollbackPages.removeWhere((pageIdx, _) => pageIdx >= minPage);
      } else if (_expandedReflowFloorAbs != null &&
          (nextScrollbackRows < _primaryScrollbackRows ||
              nextAbsEnd < prevAbsEnd)) {
        // Post-narrow primary scroll drained excess physical rows from the
        // expanded in-memory reflow ring without changing columns.
        _reflowGen += 1;
        final minPage = _expandedReflowFloorAbs! ~/ kScrollbackPageSize;
        _absScrollbackPages.removeWhere((pageIdx, _) => pageIdx >= minPage);
        if (nextScrollbackRows <= 3500) {
          _expandedReflowFloorAbs = null;
        }
      } else if (nextAbsEnd < prevAbsEnd) {
        _reflowGen += 1;
      }
      _primaryCols = nextCols;
      _primaryScrollbackRows = nextScrollbackRows;
      _primaryTrimmedTopRows = nextTrimmedTopRows;
      _pruneTrimmedScrollbackPages(_primaryTrimmedTopRows);
      if (nextAbsEnd < prevAbsEnd) {
        _pruneTailScrollbackPages(nextAbsEnd);
      }

      for (final row in pushed) {
        if (row.rowIndex < 0 ||
            row.rowIndex >= frame.pushedScrollbackRowCount) {
          continue;
        }
        final virtualRow = frame.pushedScrollbackStartRow + row.rowIndex;
        if (virtualRow >= 0 && virtualRow < _primaryScrollbackRows) {
          _putScrollbackRow(
            _primaryTrimmedTopRows + virtualRow,
            TerminalCellLine.fromDecoded(row, fallbackCols: nextCols),
          );
        }
      }
    }
    _lastSyncedCols = nextCols;

    final fullViewport = frame.fullViewport || (wasAlt != nextAlt);
    _viewWidth = nextCols;
    _viewHeight = nextRows;
    if (fullViewport) {
      _viewportLines = List<TerminalCellLine>.generate(
        _viewHeight,
        (_) => TerminalCellLine.blank(_viewWidth),
      );
    } else if (_viewportLines.length != _viewHeight) {
      final resized = List<TerminalCellLine>.generate(
        _viewHeight,
        (i) => i < _viewportLines.length
            ? _viewportLines[i]
            : TerminalCellLine.blank(_viewWidth),
      );
      _viewportLines = resized;
    }

    for (final row in decodedRows) {
      if (row.rowIndex >= 0 && row.rowIndex < _viewHeight) {
        _viewportLines[row.rowIndex] = TerminalCellLine.fromDecoded(
          row,
          fallbackCols: _viewWidth,
        );
      }
    }

    _isAltScreen = nextAlt;
    _cursorX = frame.cursorX.clamp(0, max(0, _viewWidth - 1));
    _cursorY = frame.cursorY.clamp(0, max(0, _viewHeight - 1));
    _cursorShape = TerminalCursorShape.fromCode(frame.cursorStyle);
    _cursorVisible = frame.cursorVisible;
    _bracketedPasteMode = frame.bracketedPaste;
    _appCursorKeys = frame.appCursorKeys;
    _appKeypad = frame.appKeypad;
    _originMode = frame.originMode;
    _autoWrap = frame.autoWrap;
    _reportFocus = frame.reportFocus;
    _reverseVideo = frame.reverseVideo;
    _mouseMode = frame.mouseMode;
    _mouseReportMode = frame.mouseReportMode;
    _kittyKeyboardFlags = frame.kittyKeyboardFlags;
    if (frame.frameSeq > 0) {
      _lastFrameSeq = frame.frameSeq;
    }

    if (frame.titleChanged) {
      final nextTitle = frame.title ?? '';
      if (nextTitle != _title) {
        _title = nextTitle;
        onTitleChanged?.call(_title);
      }
    } else if (frame.title != null && _title.isEmpty) {
      _title = frame.title!;
    }

    if (frame.bellRang) {
      onBell?.call();
    }

    _evictExcessScrollbackPages();
    notifyListeners();
  }

  /// Applies a demand-paged scrollback batch from `FetchTerminalRows`.
  /// Discards stale responses from before a `CSI 3J` scrollback clear or
  /// column reflow.
  bool applyFetchedRows(
    TerminalRowsPageData page, {
    int? expectedReflowGen,
    int? protectFirstVirtualRow,
    int? protectLastVirtualRow,
  }) {
    if (_scrollbackClearedLocally) {
      return false;
    }
    final expectedEraseGen = _daemonEraseScrollbackGen ?? _eraseScrollbackGen;
    if (page.eraseScrollbackGen != expectedEraseGen) {
      return false;
    }
    if (expectedReflowGen != null && expectedReflowGen != _reflowGen) {
      return false;
    }
    if (page.startRow < 0 ||
        page.totalScrollbackRows < 0 ||
        page.trimmedTopRows < _primaryTrimmedTopRows) {
      return false;
    }

    final pageTotal = page.totalScrollbackRows.clamp(0, kMaxScrollbackRows);
    final pageTrimmed = page.trimmedTopRows.clamp(0, kMaxTrimmedTopRows);

    if (page.payload.isEmpty || page.rowCount <= 0) {
      if (_advanceScrollbackMetadataFromPage(page) && !_isAltScreen) {
        notifyListeners();
      }
      return false;
    }

    final decoded = decodeTcg1Batch(page.compression, page.payload);
    if (decoded.isEmpty) {
      if (_advanceScrollbackMetadataFromPage(page) && !_isAltScreen) {
        notifyListeners();
      }
      return false;
    }

    if (_primaryCols > 0) {
      final expectedCols = min(_primaryCols, kMaxEncodedCols);
      final maxAbsEnd = max(
        _primaryTrimmedTopRows + _primaryScrollbackRows,
        pageTrimmed + pageTotal,
      );
      final baseFloor = max(0, maxAbsEnd - kDaemonReflowWindowRows);
      final reflowFloorAbs = _expandedReflowFloorAbs == null
          ? baseFloor
          : min(_expandedReflowFloorAbs!, baseFloor);
      for (final row in decoded) {
        final absRow = pageTrimmed + page.startRow + row.rowIndex;
        if (absRow >= reflowFloorAbs && row.logicalCols > 0) {
          // Archived SGR journal records do not reflow on narrow and encode
          // `logicalCols == max(expectedCols, storedCols)`, so `storedCols ==
          // logicalCols > expectedCols` is valid for current-generation pages.
          final widthMismatch =
              row.logicalCols < expectedCols ||
              (row.logicalCols > expectedCols &&
                  row.storedCols < row.logicalCols);
          if (widthMismatch) {
            return false;
          }
        }
      }
    }

    final metadataChanged = _advanceScrollbackMetadataFromPage(page);

    var wroteAny = false;
    final maxAbsExclusive = _primaryTrimmedTopRows + _primaryScrollbackRows;
    for (final row in decoded) {
      if (row.rowIndex < 0 || row.rowIndex >= page.rowCount) {
        continue;
      }
      final virtRow = page.startRow + row.rowIndex;
      if (virtRow < 0 || virtRow >= pageTotal) {
        continue;
      }
      final absRow = pageTrimmed + virtRow;
      if (absRow >= _primaryTrimmedTopRows && absRow < maxAbsExclusive) {
        _putScrollbackRow(
          absRow,
          TerminalCellLine.fromDecoded(
            row,
            fallbackCols: _primaryCols > 0 ? _primaryCols : _viewWidth,
          ),
        );
        wroteAny = true;
      }
    }
    if (!wroteAny) {
      if (metadataChanged && !_isAltScreen) {
        notifyListeners();
      }
      return false;
    }

    _evictExcessScrollbackPages(
      protectFirstVirtualRow: protectFirstVirtualRow,
      protectLastVirtualRow: protectLastVirtualRow,
    );
    notifyListeners();
    return true;
  }

  /// Returns the line at [virtualRow] (`0 .. totalLines - 1`), or `null` when
  /// [virtualRow] falls inside an unloaded scrollback page.
  TerminalCellLine? lineAtVirtualRow(
    int virtualRow, {
    bool touchCache = false,
  }) {
    final sbRows = totalScrollbackRows;
    if (virtualRow < 0 || virtualRow >= sbRows + _viewHeight) {
      return null;
    }
    if (virtualRow >= sbRows) {
      return _viewportLines[virtualRow - sbRows];
    }
    final absRow = trimmedTopRows + virtualRow;
    final pageIdx = absRow ~/ kScrollbackPageSize;
    final slot = absRow % kScrollbackPageSize;
    final page = touchCache
        ? _touchScrollbackPage(pageIdx)
        : _absScrollbackPages[pageIdx];
    return page?[slot];
  }

  /// True when `virtualRow - 1` soft-wrapped onto [virtualRow] (meaning no hard
  /// newline separates the two rows).
  bool isWrappedContinuation(int virtualRow) {
    if (virtualRow <= 0) return false;
    final prev = lineAtVirtualRow(virtualRow - 1);
    return prev?.wrapsNext ?? false;
  }

  bool isScrollbackRowLoaded(int virtualRow) {
    final sbRows = totalScrollbackRows;
    if (virtualRow < 0 || virtualRow >= sbRows) {
      return virtualRow >= sbRows && virtualRow < sbRows + _viewHeight;
    }
    final absRow = trimmedTopRows + virtualRow;
    final page = _absScrollbackPages[absRow ~/ kScrollbackPageSize];
    return page != null && page[absRow % kScrollbackPageSize] != null;
  }

  /// Computes coalesced `kScrollbackPageSize`-aligned `(startRow, rowCount)`
  /// ranges in `[0 .. totalScrollbackRows)` that have at least one missing row
  /// within `[firstVirtualRow .. lastVirtualRow]`.
  List<(int startRow, int rowCount)> missingScrollbackRanges(
    int firstVirtualRow,
    int lastVirtualRow,
  ) {
    final sbRows = totalScrollbackRows;
    if (sbRows <= 0 || _isAltScreen) {
      return const <(int, int)>[];
    }
    final clampedFirst = firstVirtualRow.clamp(0, sbRows - 1);
    final clampedLast = lastVirtualRow.clamp(0, sbRows - 1);
    if (clampedLast < clampedFirst) {
      return const <(int, int)>[];
    }

    final trimmedTop = trimmedTopRows;
    final firstAbsPage = (trimmedTop + clampedFirst) ~/ kScrollbackPageSize;
    final lastAbsPage = (trimmedTop + clampedLast) ~/ kScrollbackPageSize;

    final ranges = <(int, int)>[];
    int? openStart;
    int openEnd = 0;

    for (var absPage = firstAbsPage; absPage <= lastAbsPage; absPage++) {
      final bucket = max(0, absPage * kScrollbackPageSize - trimmedTop);
      final bucketEnd = min(
        sbRows,
        (absPage + 1) * kScrollbackPageSize - trimmedTop,
      );
      if (bucketEnd <= bucket) continue;
      final checkStart = max(bucket, clampedFirst);
      final checkEnd = min(bucketEnd, clampedLast + 1);
      var hasMissing = false;
      for (var r = checkStart; r < checkEnd; r++) {
        if (!isScrollbackRowLoaded(r)) {
          hasMissing = true;
          break;
        }
      }
      if (hasMissing) {
        if (openStart != null &&
            bucket == openEnd &&
            (bucketEnd - openStart) <= kScrollbackPageSize * 2) {
          openEnd = bucketEnd;
        } else {
          if (openStart != null) {
            ranges.add((openStart, openEnd - openStart));
          }
          openStart = bucket;
          openEnd = bucketEnd;
        }
      } else if (openStart != null) {
        ranges.add((openStart, openEnd - openStart));
        openStart = null;
      }
    }
    if (openStart != null) {
      ranges.add((openStart, openEnd - openStart));
    }
    return ranges;
  }

  /// Converts the current viewport grid into `List<StyledRow>` for the
  /// `FLUTTER_TEST` fallback view and snapshot consumers.
  List<StyledRow> viewportStyledRows({bool trimTrailingBlankRows = true}) {
    var end = _viewportLines.length;
    if (trimTrailingBlankRows) {
      final minEnd = min(_viewportLines.length, _cursorY + 1);
      while (end > minEnd && _viewportLines[end - 1].storedCols == 0) {
        end--;
      }
    }
    return <StyledRow>[
      for (var i = 0; i < end; i++) _viewportLines[i].toStyledRow(),
    ];
  }

  /// Direct test helper for seeding scrollback + viewport lines without a
  /// daemon socket.
  @visibleForTesting
  void seedLinesForTest({
    required int cols,
    required int rows,
    List<TerminalCellLine> scrollback = const <TerminalCellLine>[],
    List<TerminalCellLine> viewport = const <TerminalCellLine>[],
    int trimmedTop = 0,
    int eraseGen = 0,
    bool altScreen = false,
    bool bracketedPaste = false,
    int cursorX = 0,
    int cursorY = 0,
  }) {
    _viewWidth = cols.clamp(1, kMaxEncodedCols);
    _viewHeight = rows.clamp(1, kMaxViewportRows);
    _primaryCols = _viewWidth;
    _lastSyncedCols = _viewWidth;
    _sawAltColResize = false;
    _expandedReflowFloorAbs = null;
    _isAltScreen = altScreen;
    _bracketedPasteMode = bracketedPaste;
    _eraseScrollbackGen = eraseGen;
    _daemonEraseScrollbackGen = eraseGen;
    _scrollbackClearedLocally = false;
    _primaryTrimmedTopRows = trimmedTop.clamp(0, kMaxTrimmedTopRows);
    _primaryScrollbackRows = altScreen ? 0 : scrollback.length;
    _absScrollbackPages.clear();
    if (!altScreen) {
      for (var i = 0; i < scrollback.length; i++) {
        _putScrollbackRow(_primaryTrimmedTopRows + i, scrollback[i]);
      }
    }
    _viewportLines = List<TerminalCellLine>.generate(
      _viewHeight,
      (i) => i < viewport.length
          ? viewport[i]
          : TerminalCellLine.blank(_viewWidth),
    );
    _cursorX = cursorX.clamp(0, max(0, _viewWidth - 1));
    _cursorY = cursorY.clamp(0, max(0, _viewHeight - 1));
    notifyListeners();
  }

  /// Direct test helper that appends a new line at the bottom of the viewport,
  /// scrolling the top viewport line into scrollback and enforcing [maxLines]
  /// total buffer capacity by incrementing `trimmedTopRows`.
  @visibleForTesting
  void appendOutputLineForTest(TerminalCellLine line, {int? maxTotalLines}) {
    if (!_isAltScreen) {
      final evictedTop = _viewportLines.first;
      final newVirtualIdx = _primaryScrollbackRows;
      _putScrollbackRow(_primaryTrimmedTopRows + newVirtualIdx, evictedTop);
      _primaryScrollbackRows += 1;

      if (maxTotalLines != null) {
        final maxScrollback = max(0, maxTotalLines - _viewHeight);
        if (_primaryScrollbackRows > maxScrollback) {
          final trimDelta = _primaryScrollbackRows - maxScrollback;
          _primaryScrollbackRows = maxScrollback;
          _primaryTrimmedTopRows += trimDelta;
          _pruneTrimmedScrollbackPages(_primaryTrimmedTopRows);
        }
      }
    }
    for (var i = 0; i < _viewHeight - 1; i++) {
      _viewportLines[i] = _viewportLines[i + 1];
    }
    _viewportLines[_viewHeight - 1] = line;
    notifyListeners();
  }

  @visibleForTesting
  void setViewportLineForTest(int viewportRow, TerminalCellLine line) {
    if (viewportRow >= 0 && viewportRow < _viewHeight) {
      _viewportLines[viewportRow] = line;
      notifyListeners();
    }
  }

  @visibleForTesting
  void clearScrollbackForTest() {
    _eraseScrollbackGen += 1;
    _reflowGen += 1;
    _daemonEraseScrollbackGen = _eraseScrollbackGen;
    _scrollbackClearedLocally = false;
    _primaryScrollbackRows = 0;
    _primaryTrimmedTopRows = 0;
    _sawAltColResize = false;
    _expandedReflowFloorAbs = null;
    _absScrollbackPages.clear();
    notifyListeners();
  }

  @visibleForTesting
  void setModesForTest({
    bool? altScreen,
    bool? bracketedPaste,
    bool? appCursorKeys,
    bool? appKeypad,
    bool? originMode,
    bool? autoWrap,
    bool? reportFocus,
    bool? reverseVideo,
    int? mouseMode,
    int? mouseReportMode,
    int? kittyKeyboardFlags,
    bool? cursorVisible,
    TerminalCursorShape? cursorShape,
  }) {
    if (altScreen != null) _isAltScreen = altScreen;
    if (bracketedPaste != null) _bracketedPasteMode = bracketedPaste;
    if (appCursorKeys != null) _appCursorKeys = appCursorKeys;
    if (appKeypad != null) _appKeypad = appKeypad;
    if (originMode != null) _originMode = originMode;
    if (autoWrap != null) _autoWrap = autoWrap;
    if (reportFocus != null) _reportFocus = reportFocus;
    if (reverseVideo != null) _reverseVideo = reverseVideo;
    if (mouseMode != null) _mouseMode = mouseMode;
    if (mouseReportMode != null) _mouseReportMode = mouseReportMode;
    if (kittyKeyboardFlags != null) _kittyKeyboardFlags = kittyKeyboardFlags;
    if (cursorVisible != null) _cursorVisible = cursorVisible;
    if (cursorShape != null) _cursorShape = cursorShape;
    notifyListeners();
  }

  void _putScrollbackRow(int absRow, TerminalCellLine line) {
    if (absRow < 0) return;
    final pageIdx = absRow ~/ kScrollbackPageSize;
    final slot = absRow % kScrollbackPageSize;
    final page =
        _touchScrollbackPage(pageIdx) ??
        (_absScrollbackPages[pageIdx] = List<TerminalCellLine?>.filled(
          kScrollbackPageSize,
          null,
        ));
    page[slot] = line;
  }

  List<TerminalCellLine?>? _touchScrollbackPage(int pageIdx) {
    final existing = _absScrollbackPages.remove(pageIdx);
    if (existing != null) {
      _absScrollbackPages[pageIdx] = existing;
    }
    return existing;
  }

  bool _advanceScrollbackMetadataFromPage(TerminalRowsPageData page) {
    var changed = false;
    final nextTrimmed = page.trimmedTopRows.clamp(0, kMaxTrimmedTopRows);
    final nextTotal = page.totalScrollbackRows.clamp(0, kMaxScrollbackRows);
    if (nextTrimmed > _primaryTrimmedTopRows) {
      final trimDelta = nextTrimmed - _primaryTrimmedTopRows;
      _primaryTrimmedTopRows = nextTrimmed;
      _primaryScrollbackRows = max(0, _primaryScrollbackRows - trimDelta);
      _pruneTrimmedScrollbackPages(_primaryTrimmedTopRows);
      changed = true;
    }
    if (nextTotal > _primaryScrollbackRows) {
      _primaryScrollbackRows = nextTotal;
      changed = true;
    }
    return changed;
  }

  void _pruneTrimmedScrollbackPages(int minAbsRow) {
    if (_absScrollbackPages.isEmpty || minAbsRow <= 0) return;
    final minKeepPage = minAbsRow ~/ kScrollbackPageSize;
    _absScrollbackPages.removeWhere((pageIdx, _) => pageIdx < minKeepPage);
    final boundaryPage = _absScrollbackPages[minKeepPage];
    if (boundaryPage != null) {
      final minSlot = minAbsRow % kScrollbackPageSize;
      for (var s = 0; s < minSlot; s++) {
        boundaryPage[s] = null;
      }
    }
  }

  void _pruneTailScrollbackPages(int maxAbsRowExclusive) {
    if (_absScrollbackPages.isEmpty) return;
    if (maxAbsRowExclusive <= 0) {
      _absScrollbackPages.clear();
      return;
    }
    final lastValidAbs = maxAbsRowExclusive - 1;
    final maxKeepPage = lastValidAbs ~/ kScrollbackPageSize;
    _absScrollbackPages.removeWhere((pageIdx, _) => pageIdx > maxKeepPage);
    final boundaryPage = _absScrollbackPages[maxKeepPage];
    if (boundaryPage != null) {
      final clearFromSlot = (lastValidAbs % kScrollbackPageSize) + 1;
      for (var s = clearFromSlot; s < kScrollbackPageSize; s++) {
        boundaryPage[s] = null;
      }
    }
  }

  void _evictExcessScrollbackPages({
    int? protectFirstVirtualRow,
    int? protectLastVirtualRow,
  }) {
    if (_absScrollbackPages.length <= kMaxResidentScrollbackPages) {
      return;
    }
    final int? protectMinPage = protectFirstVirtualRow == null
        ? null
        : (_primaryTrimmedTopRows + max(0, protectFirstVirtualRow)) ~/
              kScrollbackPageSize;
    final int? protectMaxPage = protectLastVirtualRow == null
        ? null
        : (_primaryTrimmedTopRows + max(0, protectLastVirtualRow)) ~/
              kScrollbackPageSize;

    final keys = _absScrollbackPages.keys.toList(growable: false);
    for (final key in keys) {
      if (_absScrollbackPages.length <= kMaxResidentScrollbackPages) {
        break;
      }
      if (protectMinPage != null &&
          protectMaxPage != null &&
          key >= protectMinPage &&
          key <= protectMaxPage) {
        continue;
      }
      _absScrollbackPages.remove(key);
    }
  }
}
