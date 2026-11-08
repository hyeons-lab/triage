import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Directory, File, Platform;
import 'dart:math' show max;

import 'package:xterm2/xterm.dart' as xt;

const int _kModeAltScreen = 1 << 0;
const int _kModeCursorVisible = 1 << 1;
const int _kModeBracketedPaste = 1 << 2;
const int _kModeAppCursorKeys = 1 << 3;
const int _kModeAppKeypad = 1 << 4;
const int _kModeOrigin = 1 << 5;
const int _kModeAutoWrap = 1 << 6;
const int _kModeReportFocus = 1 << 7;
const int _kModeSawEraseScrollback = 1 << 8;
const int _kModeSawEraseDisplay = 1 << 9;
const int _kModeBellRang = 1 << 10;
const int _kModeTitleChanged = 1 << 11;

final class _TriageTermEngineOpaque extends ffi.Opaque {}

final class _TriageTermSyncHeader extends ffi.Struct {
  @ffi.Uint32()
  external int totalLines;

  @ffi.Uint32()
  external int physicalRows;

  @ffi.Uint32()
  external int physicalCols;

  @ffi.Uint32()
  external int cursorX;

  @ffi.Uint32()
  external int cursorY;

  @ffi.Uint32()
  external int cursorStyle;

  @ffi.Uint32()
  external int modeFlags;

  @ffi.Uint32()
  external int mouseMode;

  @ffi.Uint32()
  external int mouseReportMode;

  @ffi.Uint32()
  external int explicitTrimmedTop;

  @ffi.Uint32()
  external int pushedBottom;

  @ffi.Uint32()
  external int dirtyLineCount;

  @ffi.Uint32()
  external int cellWordsLen;

  @ffi.Uint32()
  external int combiningCount;

  @ffi.Uint32()
  external int titleUtf8Len;
}

typedef _TermNewNative =
    ffi.Pointer<_TriageTermEngineOpaque> Function(
      ffi.Uint32 cols,
      ffi.Uint32 rows,
      ffi.Uint32 maxLines,
    );
typedef _TermNewDart =
    ffi.Pointer<_TriageTermEngineOpaque> Function(
      int cols,
      int rows,
      int maxLines,
    );

typedef _TermFreeNative =
    ffi.Void Function(ffi.Pointer<_TriageTermEngineOpaque> engine);
typedef _TermFreeDart =
    void Function(ffi.Pointer<_TriageTermEngineOpaque> engine);

typedef _TermWriteNative =
    ffi.Void Function(
      ffi.Pointer<_TriageTermEngineOpaque> engine,
      ffi.Pointer<ffi.Uint8> data,
      ffi.Size len,
    );
typedef _TermWriteDart =
    void Function(
      ffi.Pointer<_TriageTermEngineOpaque> engine,
      ffi.Pointer<ffi.Uint8> data,
      int len,
    );

typedef _TermResizeNative =
    ffi.Void Function(
      ffi.Pointer<_TriageTermEngineOpaque> engine,
      ffi.Uint32 cols,
      ffi.Uint32 rows,
      ffi.Uint32 pixelWidth,
      ffi.Uint32 pixelHeight,
    );
typedef _TermResizeDart =
    void Function(
      ffi.Pointer<_TriageTermEngineOpaque> engine,
      int cols,
      int rows,
      int pixelWidth,
      int pixelHeight,
    );

typedef _TermClearNative =
    ffi.Void Function(ffi.Pointer<_TriageTermEngineOpaque> engine);
typedef _TermClearDart =
    void Function(ffi.Pointer<_TriageTermEngineOpaque> engine);

typedef _TermSyncNative =
    ffi.Pointer<_TriageTermSyncHeader> Function(
      ffi.Pointer<_TriageTermEngineOpaque> engine,
    );
typedef _TermSyncDart =
    ffi.Pointer<_TriageTermSyncHeader> Function(
      ffi.Pointer<_TriageTermEngineOpaque> engine,
    );

typedef _TermU32PtrNative =
    ffi.Pointer<ffi.Uint32> Function(
      ffi.Pointer<_TriageTermEngineOpaque> engine,
    );
typedef _TermU32PtrDart =
    ffi.Pointer<ffi.Uint32> Function(
      ffi.Pointer<_TriageTermEngineOpaque> engine,
    );

typedef _TermU8PtrNative =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<_TriageTermEngineOpaque> engine,
    );
typedef _TermU8PtrDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<_TriageTermEngineOpaque> engine,
    );

typedef _PosixMallocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size size);
typedef _PosixMallocDart = ffi.Pointer<ffi.Uint8> Function(int size);
typedef _PosixFreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8> ptr);
typedef _PosixFreeDart = void Function(ffi.Pointer<ffi.Uint8> ptr);

class _TriageTermBindings {
  _TriageTermBindings(ffi.DynamicLibrary lib)
    : termNew = lib.lookupFunction<_TermNewNative, _TermNewDart>(
        'triage_term_new',
      ),
      termFree = lib.lookupFunction<_TermFreeNative, _TermFreeDart>(
        'triage_term_free',
      ),
      termWrite = lib.lookupFunction<_TermWriteNative, _TermWriteDart>(
        'triage_term_write',
      ),
      termResize = lib.lookupFunction<_TermResizeNative, _TermResizeDart>(
        'triage_term_resize',
      ),
      termClear = lib.lookupFunction<_TermClearNative, _TermClearDart>(
        'triage_term_clear',
      ),
      termSync = lib.lookupFunction<_TermSyncNative, _TermSyncDart>(
        'triage_term_sync',
      ),
      dirtyLineMetaPtr = lib.lookupFunction<_TermU32PtrNative, _TermU32PtrDart>(
        'triage_term_dirty_line_meta_ptr',
      ),
      cellWordsPtr = lib.lookupFunction<_TermU32PtrNative, _TermU32PtrDart>(
        'triage_term_cell_words_ptr',
      ),
      combiningMetaPtr = lib.lookupFunction<_TermU32PtrNative, _TermU32PtrDart>(
        'triage_term_combining_meta_ptr',
      ),
      titleUtf8Ptr = lib.lookupFunction<_TermU8PtrNative, _TermU8PtrDart>(
        'triage_term_title_utf8_ptr',
      );

  final _TermNewDart termNew;
  final _TermFreeDart termFree;
  final _TermWriteDart termWrite;
  final _TermResizeDart termResize;
  final _TermClearDart termClear;
  final _TermSyncDart termSync;
  final _TermU32PtrDart dirtyLineMetaPtr;
  final _TermU32PtrDart cellWordsPtr;
  final _TermU32PtrDart combiningMetaPtr;
  final _TermU8PtrDart titleUtf8Ptr;

  static final ffi.DynamicLibrary _stdlib = Platform.isWindows
      ? ffi.DynamicLibrary.open('msvcrt.dll')
      : ffi.DynamicLibrary.process();
  static final _PosixMallocDart _malloc = _stdlib
      .lookupFunction<_PosixMallocNative, _PosixMallocDart>('malloc');
  static final _PosixFreeDart _free = _stdlib
      .lookupFunction<_PosixFreeNative, _PosixFreeDart>('free');

  ffi.Pointer<ffi.Uint8> _scratchPtr = ffi.nullptr;
  int _scratchCap = 0;

  void writeString(ffi.Pointer<_TriageTermEngineOpaque> engine, String data) {
    final encoded = utf8.encode(data);
    final len = encoded.length;
    if (len == 0) return;
    if (len > _scratchCap) {
      if (_scratchPtr != ffi.nullptr) {
        _free(_scratchPtr);
      }
      var nextCap = _scratchCap == 0 ? 65536 : _scratchCap;
      while (nextCap < len) {
        nextCap *= 2;
      }
      _scratchPtr = _malloc(nextCap);
      _scratchCap = nextCap;
    }
    _scratchPtr.asTypedList(len).setAll(0, encoded);
    termWrite(engine, _scratchPtr, len);
  }
}

_TriageTermBindings? _cachedBindings;
bool _bindingsProbed = false;

_TriageTermBindings? _loadBindings() {
  if (_bindingsProbed) return _cachedBindings;
  _bindingsProbed = true;

  final candidates = <String>[];
  if (Platform.isAndroid || Platform.isLinux) {
    candidates.add('libtriage_term.so');
    if (Platform.isLinux) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add('$exeDir/lib/libtriage_term.so');
    }
    final cwd = Directory.current.path;
    candidates.add('$cwd/../../target/release/libtriage_term.so');
    candidates.add('$cwd/../../target/debug/libtriage_term.so');
    candidates.add('$cwd/target/release/libtriage_term.so');
    candidates.add('$cwd/target/debug/libtriage_term.so');
  } else if (Platform.isMacOS) {
    final exeDir = File(Platform.resolvedExecutable).parent.parent.path;
    candidates.add('$exeDir/Frameworks/libtriage_term.dylib');
    final cwd = Directory.current.path;
    candidates.add('$cwd/macos/Frameworks/libtriage_term.dylib');
    candidates.add('$cwd/../../target/release/libtriage_term.dylib');
    candidates.add('$cwd/../../target/debug/libtriage_term.dylib');
    candidates.add('$cwd/target/release/libtriage_term.dylib');
    candidates.add('$cwd/target/debug/libtriage_term.dylib');
    candidates.add('libtriage_term.dylib');
  } else if (Platform.isWindows) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.add('$exeDir/triage_term.dll');
    final cwd = Directory.current.path;
    candidates.add('$cwd/../../target/release/triage_term.dll');
    candidates.add('$cwd/../../target/debug/triage_term.dll');
    candidates.add('triage_term.dll');
  }

  for (final path in candidates) {
    try {
      if (path.startsWith('/') && !File(path).existsSync()) {
        continue;
      }
      final lib = ffi.DynamicLibrary.open(path);
      _cachedBindings = _TriageTermBindings(lib);
      return _cachedBindings;
    } catch (_) {}
  }

  try {
    final proc = ffi.DynamicLibrary.process();
    _cachedBindings = _TriageTermBindings(proc);
    return _cachedBindings;
  } catch (_) {}

  return null;
}

/// Returns whether the native Rust `triage-term` FFI library is available.
bool get isTriageRustTerminalAvailable => _loadBindings() != null;

/// Creates a [TriageRustTerminal] backed by `crates/triage-term` (`wezterm-term`)
/// when the native library is available, or falls back to `xt.Terminal`.
xt.Terminal createTriageTerminal({
  int maxLines = 1000,
  void Function()? onBell,
  void Function(String title)? onTitleChange,
  void Function(String icon)? onIconChange,
  void Function(String data)? onOutput,
  void Function(int width, int height, int pixelWidth, int pixelHeight)?
  onResize,
  xt.TerminalTargetPlatform platform = xt.TerminalTargetPlatform.unknown,
  bool reflowEnabled = true,
  bool reflowWithHiddenCursor = true,
  Set<int>? wordSeparators,
}) {
  final bindings = _loadBindings();
  if (bindings != null) {
    return TriageRustTerminal._(
      bindings: bindings,
      maxLines: maxLines,
      onBell: onBell,
      onTitleChange: onTitleChange,
      onIconChange: onIconChange,
      onOutput: onOutput,
      onResize: onResize,
      platform: platform,
      reflowEnabled: reflowEnabled,
      reflowWithHiddenCursor: reflowWithHiddenCursor,
      wordSeparators: wordSeparators,
    );
  }
  return _TriageFallbackTerminal(
    maxLines: maxLines,
    onBell: onBell,
    onTitleChange: onTitleChange,
    onIconChange: onIconChange,
    onOutput: onOutput,
    onResize: onResize,
    platform: platform,
    reflowEnabled: reflowEnabled,
    reflowWithHiddenCursor: reflowWithHiddenCursor,
    wordSeparators: wordSeparators,
  );
}

class _TriageFallbackTerminal extends xt.Terminal {
  _TriageFallbackTerminal({
    super.maxLines = 1000,
    super.onBell,
    super.onTitleChange,
    super.onIconChange,
    super.onOutput,
    super.onResize,
    super.platform = xt.TerminalTargetPlatform.unknown,
    super.reflowEnabled = true,
    super.reflowWithHiddenCursor = true,
    super.wordSeparators,
  });

  bool _batchingUpdates = false;
  bool _pendingNotify = false;

  @override
  void setSynchronizedUpdateMode(bool enabled) {
    _batchingUpdates = enabled;
    if (!enabled && _pendingNotify) {
      _pendingNotify = false;
      super.notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (_batchingUpdates) {
      _pendingNotify = true;
      return;
    }
    super.notifyListeners();
  }
}

/// A [xt.Terminal] whose VT parser, escape sequence state machine, scrollback,
/// and width-reflow engine run in Rust (`crates/triage-term` wrapping
/// `tattoy-wezterm-term`), syncing only dirty rows into [mainBuffer] and
/// [altBuffer] for Flutter's `TerminalView` `CustomPainter`.
class TriageRustTerminal extends xt.Terminal {
  TriageRustTerminal._({
    required _TriageTermBindings bindings,
    super.maxLines = 1000,
    super.onBell,
    super.onTitleChange,
    super.onIconChange,
    super.onOutput,
    super.onResize,
    super.platform = xt.TerminalTargetPlatform.unknown,
    super.reflowEnabled = true,
    super.reflowWithHiddenCursor = true,
    super.wordSeparators,
  }) : _bindings = bindings {
    _engine = _bindings.termNew(_rustViewWidth, _rustViewHeight, maxLines);
    _syncFromRust(notify: false);
  }

  final _TriageTermBindings _bindings;
  ffi.Pointer<_TriageTermEngineOpaque> _engine = ffi.nullptr;
  int _rustViewWidth = 80;
  int _rustViewHeight = 24;
  int _rustCellPixelWidth = 0;
  int _rustCellPixelHeight = 0;
  bool _batchingUpdates = false;
  bool _needsRustSync = false;
  bool _disposed = false;

  void _flushPendingRustSync() {
    if (_needsRustSync && !_disposed && _engine != ffi.nullptr) {
      _needsRustSync = false;
      _syncFromRust(notify: false);
    }
  }

  @override
  int get viewWidth => _rustViewWidth;

  @override
  int get viewHeight => _rustViewHeight;

  @override
  xt.Buffer get buffer {
    _flushPendingRustSync();
    return super.buffer;
  }

  @override
  xt.Buffer get mainBuffer {
    _flushPendingRustSync();
    return super.mainBuffer;
  }

  @override
  xt.Buffer get altBuffer {
    _flushPendingRustSync();
    return super.altBuffer;
  }

  @override
  bool get isUsingAltBuffer {
    _flushPendingRustSync();
    return super.isUsingAltBuffer;
  }

  @override
  void setSynchronizedUpdateMode(bool enabled) {
    _batchingUpdates = enabled;
    if (!enabled && _needsRustSync && !_disposed && _engine != ffi.nullptr) {
      _needsRustSync = false;
      _syncFromRust(notify: true);
    }
  }

  @override
  void write(String data) {
    if (_disposed || data.isEmpty || _engine == ffi.nullptr) return;
    _bindings.writeString(_engine, data);
    if (_batchingUpdates) {
      _needsRustSync = true;
      return;
    }
    _syncFromRust(notify: true);
  }

  @override
  void resize(
    int newWidth,
    int newHeight, [
    int? pixelWidth,
    int? pixelHeight,
  ]) {
    if (_disposed || _engine == ffi.nullptr) return;
    newWidth = max(newWidth, 1);
    newHeight = max(newHeight, 1);

    final nextCellPixelWidth = pixelWidth ?? _rustCellPixelWidth;
    final nextCellPixelHeight = pixelHeight ?? _rustCellPixelHeight;

    if (newWidth == _rustViewWidth &&
        newHeight == _rustViewHeight &&
        nextCellPixelWidth == _rustCellPixelWidth &&
        nextCellPixelHeight == _rustCellPixelHeight) {
      return;
    }

    // Fire `onResize` BEFORE updating `_rustViewWidth` / `_rustViewHeight` so
    // callbacks inspecting `terminal.viewWidth` see the previous width.
    onResize?.call(newWidth, newHeight, pixelWidth ?? 0, pixelHeight ?? 0);

    if (pixelWidth != null) {
      _rustCellPixelWidth = pixelWidth;
    }
    if (pixelHeight != null) {
      _rustCellPixelHeight = pixelHeight;
    }

    _rustViewWidth = newWidth;
    _rustViewHeight = newHeight;

    if (newHeight > super.mainBuffer.lines.maxLength) {
      super.mainBuffer.lines.maxLength = newHeight;
    }
    if (newHeight > super.altBuffer.lines.maxLength) {
      super.altBuffer.lines.maxLength = newHeight;
    }

    super.mainBuffer.resetVerticalMargins();
    super.mainBuffer.resetHorizontalMargins();
    super.altBuffer.resetVerticalMargins();
    super.altBuffer.resetHorizontalMargins();

    _bindings.termResize(
      _engine,
      newWidth,
      newHeight,
      _rustCellPixelWidth,
      _rustCellPixelHeight,
    );
    if (_batchingUpdates) {
      _needsRustSync = true;
      return;
    }
    _needsRustSync = false;
    _syncFromRust(notify: false);
  }

  @override
  void clear() {
    if (_disposed || _engine == ffi.nullptr) return;
    _bindings.termClear(_engine);
    useMainBuffer();
    super.mainBuffer.clear();
    super.altBuffer.clear();
    if (_batchingUpdates) {
      _needsRustSync = true;
      return;
    }
    _needsRustSync = false;
    _syncFromRust(notify: true);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _batchingUpdates = false;
    _needsRustSync = false;
    if (_engine != ffi.nullptr) {
      _bindings.termFree(_engine);
      _engine = ffi.nullptr;
    }
    super.dispose();
  }

  void _syncFromRust({required bool notify}) {
    if (_engine == ffi.nullptr) return;
    final headerPtr = _bindings.termSync(_engine);
    if (headerPtr == ffi.nullptr) return;
    final h = headerPtr.ref;

    final isAlt = (h.modeFlags & _kModeAltScreen) != 0;
    if (isAlt != super.isUsingAltBuffer) {
      if (isAlt) {
        useAltBuffer();
      } else {
        useMainBuffer();
      }
    }

    setCursorVisibleMode((h.modeFlags & _kModeCursorVisible) != 0);
    setBracketedPasteMode((h.modeFlags & _kModeBracketedPaste) != 0);
    setCursorKeysMode((h.modeFlags & _kModeAppCursorKeys) != 0);
    setAppKeypadMode((h.modeFlags & _kModeAppKeypad) != 0);
    setAutoWrapMode((h.modeFlags & _kModeAutoWrap) != 0);
    setReportFocusMode((h.modeFlags & _kModeReportFocus) != 0);
    setCursorShape(h.cursorStyle);

    setMouseMode(switch (h.mouseMode) {
      1 => xt.MouseMode.clickOnly,
      2 => xt.MouseMode.upDownScroll,
      3 => xt.MouseMode.upDownScrollDrag,
      4 => xt.MouseMode.upDownScrollMove,
      _ => xt.MouseMode.none,
    });
    setMouseReportMode(switch (h.mouseReportMode) {
      1 => xt.MouseReportMode.utf,
      2 => xt.MouseReportMode.sgr,
      3 => xt.MouseReportMode.urxvt,
      4 => xt.MouseReportMode.sgrPixels,
      _ => xt.MouseReportMode.normal,
    });

    final nextOrigin = (h.modeFlags & _kModeOrigin) != 0;
    if (nextOrigin != originMode) {
      setOriginMode(nextOrigin);
    }

    final buf = isAlt ? super.altBuffer : super.mainBuffer;
    final totalLines = h.totalLines;
    final physicalCols = h.physicalCols;
    final sawEraseScrollback = (h.modeFlags & _kModeSawEraseScrollback) != 0;
    final sawEraseDisplay = (h.modeFlags & _kModeSawEraseDisplay) != 0;

    final minCap = max(totalLines, buf.viewHeight);
    if (minCap > buf.lines.maxLength) {
      buf.lines.maxLength = minCap;
    }

    if (!isAlt) {
      final explicitTrim = h.explicitTrimmedTop;
      if (explicitTrim > 0) {
        if (sawEraseScrollback &&
            buf.height > buf.viewHeight &&
            explicitTrim >= buf.scrollBack) {
          final oldScrollBack = buf.scrollBack;
          buf.clearScrollback();
          if (explicitTrim > oldScrollBack) {
            buf.lines.trimStart(explicitTrim - oldScrollBack);
          }
        } else {
          buf.lines.trimStart(explicitTrim);
        }
      }
      if (sawEraseDisplay) {
        while (buf.lines.length < buf.viewHeight) {
          buf.lines.push(xt.BufferLine(physicalCols));
        }
        buf.eraseDisplay();
      }
      final pushed = h.pushedBottom;
      for (var i = 0; i < pushed; i++) {
        buf.lines.push(xt.BufferLine(physicalCols));
      }
    }

    while (buf.lines.length < totalLines) {
      buf.lines.push(xt.BufferLine(physicalCols));
    }
    while (buf.lines.length > totalLines) {
      buf.lines.pop();
    }

    final dirtyCount = h.dirtyLineCount;
    if (dirtyCount > 0) {
      final metaList = _bindings
          .dirtyLineMetaPtr(_engine)
          .asTypedList(dirtyCount * 2);
      final wordsPerLine = physicalCols * 4;
      final cellWordsList = _bindings
          .cellWordsPtr(_engine)
          .asTypedList(h.cellWordsLen);

      for (var d = 0; d < dirtyCount; d++) {
        final rowIdx = metaList[d * 2];
        final flags = metaList[d * 2 + 1];
        if (rowIdx >= buf.lines.length) continue;
        final line = buf.lines[rowIdx];
        if (line.length != physicalCols || line.data.length < wordsPerLine) {
          line.resize(physicalCols);
        }
        if (line.hasCombiningCharacters) {
          line.eraseRange(0, line.length, cursor);
        }
        line.isWrapped = (flags & 1) != 0;
        final srcOffset = d * wordsPerLine;
        line.data.setRange(0, wordsPerLine, cellWordsList, srcOffset);
      }

      final combiningCount = h.combiningCount;
      if (combiningCount > 0) {
        final combList = _bindings
            .combiningMetaPtr(_engine)
            .asTypedList(combiningCount * 3);
        for (var c = 0; c < combiningCount; c++) {
          final d = combList[c * 3];
          final col = combList[c * 3 + 1];
          final cp = combList[c * 3 + 2];
          final rowIdx = metaList[d * 2];
          if (rowIdx < buf.lines.length) {
            buf.lines[rowIdx].addCombiningCharacter(col, cp);
          }
        }
      }
    }

    buf.setCursorX(h.cursorX);
    buf.setCursorY(h.cursorY);
    final absCursorY = buf.absoluteCursorY;
    if (absCursorY >= 0 && absCursorY < buf.lines.length) {
      final cursorLine = buf.lines[absCursorY];
      if (cursorLine.length < physicalCols ||
          cursorLine.data.length < physicalCols * 4) {
        cursorLine.resize(physicalCols);
      }
    }

    if ((h.modeFlags & _kModeBellRang) != 0) {
      onBell?.call();
    }
    if ((h.modeFlags & _kModeTitleChanged) != 0 && h.titleUtf8Len > 0) {
      final titleBytes = _bindings
          .titleUtf8Ptr(_engine)
          .asTypedList(h.titleUtf8Len);
      onTitleChange?.call(utf8.decode(titleBytes, allowMalformed: true));
    }

    if (notify) {
      notifyListeners();
    }
  }
}
