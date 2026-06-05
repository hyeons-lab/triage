import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'terminal_intent.dart';
import 'terminal_sink.dart';
import 'terminal_state.dart';

/// Smallest grid we will apply; below this we ignore resize noise.
const int kMinTerminalCols = 2;
const int kMinTerminalRows = 1;

/// The single reducer for the terminal pipeline.
///
/// All terminal mutations arrive as [TerminalIntent]s via [dispatch], are
/// reduced **in arrival order** through **one** write path into a single
/// [TerminalSink], and produce a new immutable [TerminalState] (emitted via
/// [ChangeNotifier]). The store owns the only UTF-8 carry, the only CRLF
/// normalization, and the only pre-size/await-history buffer — so there is
/// exactly one place where bytes become screen.
class TerminalStore extends ChangeNotifier {
  TerminalStore(this._sink) {
    _sink.onOutput = _handleSinkOutput;
    _sink.onResize = _handleSinkResize;
  }

  final TerminalSink _sink;

  TerminalState _state = const TerminalState();
  TerminalState get state => _state;

  /// Emulator -> host. Set by the wiring; the store forwards user input and
  /// distinct viewport sizes here.
  void Function(String data)? onHostInput;
  void Function(int cols, int rows)? onHostResize;

  // Live-stream byte carries (history is decoded as a self-contained unit).
  final List<int> _utf8Carry = <int>[];
  bool _pendingCarriageReturn = false;
  // Holds a trailing, not-yet-terminated `CSI > …` so a private-mode sequence
  // split across live chunks is still stripped before reaching the emulator.
  String _privateCsiCarry = '';

  // Live chunks received before we are sized / while awaiting history.
  final List<_QueuedLive> _pendingLive = <_QueuedLive>[];

  // True while we are programmatically resizing the sink, so its onResize echo
  // does not loop back through the reducer.
  bool _applyingResize = false;

  // ---- Public API -----------------------------------------------------------

  void dispatch(TerminalIntent intent) {
    final next = _reduce(_state, intent);
    if (next != _state) {
      _state = next;
      notifyListeners();
    }
  }

  // ---- Reducer --------------------------------------------------------------

  TerminalState _reduce(TerminalState s, TerminalIntent intent) {
    switch (intent) {
      case Attach():
        _resetCarries();
        return s.copyWith(
          phase: AttachPhase.awaitingHistory,
          exited: false,
          scrollbackReady: false,
        );

      case Detach():
        return s.copyWith(phase: AttachPhase.detached);

      case Exited():
        return s.copyWith(exited: true);

      case Clear():
        _sink.clear();
        _resetCarries();
        return s.copyWith(scrollbackReady: false);

      case Resize(:final cols, :final rows):
        return _reduceResize(s, cols, rows);

      case UserInput(:final data):
        if (!s.exited) {
          onHostInput?.call(data);
        }
        return s;

      case HistoryBytes(
          :final bytes,
          :final cols,
          :final rows,
          :final throughOutputSeq,
        ):
        return _reduceHistory(s, bytes, cols, rows, throughOutputSeq);

      case LiveBytes(:final bytes, :final outputSeq):
        return _reduceLive(s, bytes, outputSeq);
    }
  }

  TerminalState _reduceResize(TerminalState s, int cols, int rows) {
    if (cols < kMinTerminalCols || rows < kMinTerminalRows) {
      return s;
    }

    var next = s;
    final sizeChanged = cols != s.cols || rows != s.rows || !s.sized;
    if (sizeChanged) {
      _applyResizeToSink(cols, rows);
      next = next.copyWith(cols: cols, rows: rows, sized: true);
    } else if (!s.sized) {
      next = next.copyWith(sized: true);
    }

    // Now that we have a size, drain anything we buffered (only once live).
    if (next.sized && next.phase == AttachPhase.live) {
      _flushPendingLive(next.historyHighWaterSeq);
    }

    // Forward distinct sizes to the host exactly once.
    if (cols != s.lastSentCols || rows != s.lastSentRows) {
      onHostResize?.call(cols, rows);
      next = next.copyWith(lastSentCols: cols, lastSentRows: rows);
    }
    return next;
  }

  TerminalState _reduceHistory(
    TerminalState s,
    List<int> bytes,
    int cols,
    int rows,
    int? throughOutputSeq,
  ) {
    // Replay at the size the bytes were generated for, so cursor-addressed TUI
    // frames reconstruct without wrap fragmentation. A later viewport [Resize]
    // reflows and the live repaint self-heals.
    var next = s;
    if (cols >= kMinTerminalCols && rows >= kMinTerminalRows) {
      _applyResizeToSink(cols, rows);
      next = next.copyWith(cols: cols, rows: rows, sized: true);
    }

    _sink.clear();
    _resetCarries();
    _writeDecoded(bytes, isHistory: true);

    next = next.copyWith(
      phase: AttachPhase.live,
      scrollbackReady: true,
      historyHighWaterSeq: throughOutputSeq,
    );

    if (next.sized) {
      _flushPendingLive(throughOutputSeq);
    }
    return next;
  }

  TerminalState _reduceLive(TerminalState s, List<int> bytes, int? outputSeq) {
    if (s.phase == AttachPhase.detached) {
      return s;
    }
    if (_isDuplicate(outputSeq, s.historyHighWaterSeq)) {
      return s;
    }
    if (!s.sized || s.phase == AttachPhase.awaitingHistory) {
      _pendingLive.add(_QueuedLive(bytes, outputSeq));
      return s;
    }
    _writeDecoded(bytes, isHistory: false);
    return s;
  }

  // ---- Sink-driven events ---------------------------------------------------

  void _handleSinkOutput(String data) {
    dispatch(UserInput(data));
  }

  void _handleSinkResize(int cols, int rows) {
    if (_applyingResize) {
      return; // our own resize echoing back; ignore.
    }
    dispatch(Resize(cols, rows));
  }

  void _applyResizeToSink(int cols, int rows) {
    _applyingResize = true;
    try {
      _sink.resize(cols, rows);
    } finally {
      _applyingResize = false;
    }
  }

  // ---- Byte plumbing (the one decode path) ----------------------------------

  void _flushPendingLive(int? highWaterSeq) {
    if (_pendingLive.isEmpty) return;
    final queued = List<_QueuedLive>.from(_pendingLive);
    _pendingLive.clear();
    for (final q in queued) {
      if (_isDuplicate(q.outputSeq, highWaterSeq)) {
        continue;
      }
      _writeDecoded(q.bytes, isHistory: false);
    }
  }

  bool _isDuplicate(int? outputSeq, int? highWaterSeq) {
    return outputSeq != null &&
        highWaterSeq != null &&
        outputSeq <= highWaterSeq;
  }

  /// Decode raw bytes to text and write them through the sink. History is a
  /// self-contained range (no carry across calls); live persists the UTF-8 and
  /// trailing-CR carries across chunks.
  void _writeDecoded(List<int> bytes, {required bool isHistory}) {
    List<int> toDecode;
    if (isHistory) {
      toDecode = bytes;
    } else {
      toDecode = _utf8Carry.isEmpty
          ? List<int>.from(bytes)
          : <int>[..._utf8Carry, ...bytes];
      _utf8Carry.clear();
      final trailing = _trailingIncompleteUtf8ByteCount(toDecode);
      if (trailing > 0) {
        _utf8Carry.addAll(toDecode.sublist(toDecode.length - trailing));
        toDecode = toDecode.sublist(0, toDecode.length - trailing);
      }
    }
    if (toDecode.isEmpty) return;
    final sanitized = _stripUnsupportedPrivateCsi(
      utf8.decode(toDecode, allowMalformed: true),
      live: !isHistory,
    );
    final text = _normalizeNewlines(sanitized, live: !isHistory);
    if (text.isNotEmpty) {
      _sink.write(text);
    }
  }

  /// Strips `CSI > … m` private sequences (XTMODKEYS / modifyOtherKeys, which
  /// Claude Code emits at startup). xterm.dart ignores the `>` private marker
  /// and misparses them as plain SGR — e.g. `CSI > 4 ; 2 m` becomes SGR 4
  /// (underline), which poisons every subsequent cell and erase with a spurious
  /// underline. The emulator does not support these sequences anyway. For the
  /// live stream a trailing, not-yet-terminated `CSI > …` is held back so a
  /// sequence split across chunks is still caught.
  String _stripUnsupportedPrivateCsi(String input, {required bool live}) {
    var s = input;
    if (live && _privateCsiCarry.isNotEmpty) {
      s = _privateCsiCarry + s;
      _privateCsiCarry = '';
    }
    if (live) {
      final partial = RegExp(r'\x1b\[>[0-9;]*$').firstMatch(s);
      // Only hold a bounded partial; otherwise let it flush to avoid unbounded
      // growth on a stream that never completes the sequence.
      if (partial != null && (s.length - partial.start) <= 24) {
        _privateCsiCarry = s.substring(partial.start);
        s = s.substring(0, partial.start);
      }
    }
    return s.replaceAll(RegExp(r'\x1b\[>[0-9;]*m'), '');
  }

  /// Normalize bare LF to CRLF (leaving existing CRLF intact) so the emulator
  /// does not stair-step. For the live stream a trailing '\r' is held back so a
  /// CRLF split across chunks is not doubled.
  String _normalizeNewlines(String input, {required bool live}) {
    var s = input;
    if (live && _pendingCarriageReturn) {
      s = '\r$s';
      _pendingCarriageReturn = false;
    }
    if (live && s.endsWith('\r')) {
      _pendingCarriageReturn = true;
      s = s.substring(0, s.length - 1);
    }
    // Any LF not already preceded by CR becomes CRLF.
    return s.replaceAll(RegExp(r'(?<!\r)\n'), '\r\n');
  }

  void _resetCarries() {
    _utf8Carry.clear();
    _pendingCarriageReturn = false;
    _privateCsiCarry = '';
  }

  @override
  void dispose() {
    _sink.onOutput = null;
    _sink.onResize = null;
    _sink.dispose();
    super.dispose();
  }
}

class _QueuedLive {
  _QueuedLive(this.bytes, this.outputSeq);
  final List<int> bytes;
  final int? outputSeq;
}

/// Number of trailing bytes that form an incomplete UTF-8 sequence (0 if the
/// buffer ends on a complete boundary). Mirrors the host's chunking contract:
/// a multi-byte rune may straddle two live chunks.
int _trailingIncompleteUtf8ByteCount(List<int> bytes) {
  if (bytes.isEmpty) return 0;
  final startLimit = max(0, bytes.length - 4);
  for (var start = bytes.length - 1; start >= startLimit; start--) {
    final expectedLength = _utf8SequenceLength(bytes[start]);
    if (expectedLength == 0) {
      continue; // continuation byte; keep walking back to the lead byte.
    }
    final available = bytes.length - start;
    if (available >= expectedLength) {
      return 0; // complete sequence at the tail.
    }
    for (var i = start + 1; i < bytes.length; i++) {
      if (!_isUtf8ContinuationByte(bytes[i])) {
        return 0; // malformed; let the decoder handle it now.
      }
    }
    return available; // lead byte + some continuations, still short.
  }
  return 0;
}

int _utf8SequenceLength(int byte) {
  if (byte < 0x80) return 1;
  if (byte >= 0xC2 && byte <= 0xDF) return 2;
  if (byte >= 0xE0 && byte <= 0xEF) return 3;
  if (byte >= 0xF0 && byte <= 0xF4) return 4;
  return 0;
}

bool _isUtf8ContinuationByte(int byte) => byte >= 0x80 && byte <= 0xBF;
