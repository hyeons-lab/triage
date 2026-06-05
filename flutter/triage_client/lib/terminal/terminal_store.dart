import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'terminal_intent.dart';
import 'terminal_sink.dart';
import 'terminal_state.dart';

/// Smallest grid we will apply; below this we ignore resize noise.
const int kMinTerminalCols = 2;
const int kMinTerminalRows = 1;

/// Upper bound on the pre-size / await-history live buffer. A session whose view
/// never lays out (a backgrounded tab) would otherwise queue live output without
/// limit; when it is finally selected it refetches a fresh snapshot anyway, so
/// dropping the oldest queued chunks past this cap only ever discards output the
/// new snapshot supersedes.
const int kPendingLiveByteCap = 1024 * 1024;

/// How long emulator-emitted bytes stay suppressed after a history replay. The
/// program's own terminal queries (DSR/cursor reports) are replayed into the
/// emulator, which auto-answers them; those answers must not be forwarded to the
/// host as fake user input. xterm.dart answers synchronously inside `write`,
/// xterm.js a tick later — this window covers both.
const Duration kHistoryInputSuppression = Duration(milliseconds: 50);

// Hoisted out of the per-chunk hot path (`_writeDecoded` runs on every live
// `Output`): a trailing not-yet-terminated `CSI > …` and a complete
// `CSI > … m` private sequence. (Newline normalization deliberately avoids a
// regex — see `_normalizeNewlines`.)
final RegExp _partialPrivateCsi = RegExp(r'\x1b\[>[0-9;]*$');
final RegExp _completePrivateCsi = RegExp(r'\x1b\[>[0-9;]*m');

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

  // Live chunks received before we are sized / while awaiting history, plus a
  // running byte total so the buffer can be bounded (see [kPendingLiveByteCap]).
  final List<_QueuedLive> _pendingLive = <_QueuedLive>[];
  int _pendingLiveBytes = 0;

  // Highest live `output_seq` already applied. Combined with the history
  // high-water, this is the single de-duplication baseline — it also drops a
  // live chunk re-delivered out of order over a flaky connection.
  int? _appliedLiveSeq;

  // True while we are programmatically resizing the sink, so its onResize echo
  // does not loop back through the reducer.
  bool _applyingResize = false;

  // True for a brief window after a history replay; while set, emulator output
  // (the program's own query auto-answers) is not forwarded to the host.
  bool _suppressHostInput = false;
  Timer? _suppressTimer;

  /// True while emulator-emitted bytes must not reach the host as user input
  /// (during and just after a history replay). The view's input forwarding
  /// consults this so replayed cursor/device reports are not echoed back.
  bool get isSuppressingHostInput => _suppressHostInput;

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
        // Start of a fresh attach lifecycle: drop any carries and any live
        // chunks buffered against a prior attach so they cannot leak into this
        // session once HistoryBytes arrives.
        _resetCarries();
        _clearPendingLive();
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
        // Hard reset: also drop queued pre-size/await-history live so it cannot
        // later re-populate the cleared terminal.
        _sink.clear();
        _resetCarries();
        _clearPendingLive();
        return s.copyWith(scrollbackReady: false);

      case Resize(:final cols, :final rows):
        return _reduceResize(s, cols, rows);

      case UserInput(:final data):
        if (!s.exited && !_suppressHostInput) {
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
    // `sizeChanged` already covers the not-yet-sized case (`|| !s.sized`), so a
    // change always re-applies the size and marks it sized — no separate branch.
    final sizeChanged = cols != s.cols || rows != s.rows || !s.sized;
    if (sizeChanged) {
      _applyResizeToSink(cols, rows);
      next = next.copyWith(cols: cols, rows: rows, sized: true);
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
    // Replay at the client's target grid size ([cols] x [rows], the current
    // emulator/view size chosen by the caller — not the host capture size). A
    // later viewport [Resize] reflows and the live repaint self-heals.
    var next = s;
    if (cols >= kMinTerminalCols && rows >= kMinTerminalRows) {
      _applyResizeToSink(cols, rows);
      next = next.copyWith(cols: cols, rows: rows, sized: true);
    }

    _sink.clear();
    // Reset carries so history starts a fresh decode stream; history then
    // decodes through the same streaming path as live, so a UTF-8 rune, CRLF
    // pair, or `CSI > … m` sequence split across the history→live boundary (the
    // snapshot tail can end mid-sequence) carries into the first live chunk.
    _resetCarries();
    // Replaying the raw tail re-feeds the program's own terminal queries to the
    // emulator, which auto-answers them; suppress those answers so they are not
    // echoed to the host as user input.
    _beginHostInputSuppression();
    _writeDecoded(bytes);

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
      _enqueuePendingLive(_QueuedLive(bytes, outputSeq));
      return s;
    }
    _applyLive(bytes, outputSeq);
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

  /// Queue a live chunk received before we can write it, bounding the buffer so
  /// a never-fitted (backgrounded) session cannot grow it without limit.
  void _enqueuePendingLive(_QueuedLive q) {
    _pendingLive.add(q);
    _pendingLiveBytes += q.bytes.length;
    if (_pendingLiveBytes <= kPendingLiveByteCap) return;
    var dropped = 0;
    while (_pendingLive.length > 1 && _pendingLiveBytes > kPendingLiveByteCap) {
      final old = _pendingLive.removeAt(0);
      _pendingLiveBytes -= old.bytes.length;
      dropped += old.bytes.length;
    }
    if (dropped > 0) {
      debugPrint(
        'TerminalStore: dropped $dropped buffered live bytes '
        '(pre-size buffer exceeded ${kPendingLiveByteCap}B)',
      );
    }
  }

  void _clearPendingLive() {
    _pendingLive.clear();
    _pendingLiveBytes = 0;
  }

  void _flushPendingLive(int? highWaterSeq) {
    if (_pendingLive.isEmpty) return;
    final queued = List<_QueuedLive>.from(_pendingLive);
    _clearPendingLive();
    for (final q in queued) {
      if (_isDuplicate(q.outputSeq, highWaterSeq)) {
        continue;
      }
      _applyLive(q.bytes, q.outputSeq);
    }
  }

  /// Write a live chunk through the decode path and advance the applied-seq
  /// high-water so a later re-delivery of the same chunk is dropped.
  void _applyLive(List<int> bytes, int? outputSeq) {
    _writeDecoded(bytes);
    if (outputSeq != null) {
      _appliedLiveSeq = _appliedLiveSeq == null
          ? outputSeq
          : max(_appliedLiveSeq!, outputSeq);
    }
  }

  /// A live chunk is a duplicate when its `output_seq` is at or below either the
  /// history high-water (already covered by the replayed tail) or the highest
  /// live seq we have already applied (a re-delivery).
  bool _isDuplicate(int? outputSeq, int? highWaterSeq) {
    if (outputSeq == null) return false;
    if (highWaterSeq != null && outputSeq <= highWaterSeq) return true;
    if (_appliedLiveSeq != null && outputSeq <= _appliedLiveSeq!) return true;
    return false;
  }

  void _beginHostInputSuppression() {
    _suppressHostInput = true;
    _suppressTimer?.cancel();
    _suppressTimer = Timer(kHistoryInputSuppression, () {
      _suppressHostInput = false;
    });
  }

  /// Decode raw bytes to text and write them through the sink. A single
  /// streaming path for both history and live: trailing incomplete UTF-8, a
  /// dangling CR, and an unterminated `CSI > …` are held in carries and joined
  /// with the next bytes, so a sequence split across chunks — or across the
  /// history→live boundary — is decoded correctly. [Attach]/[Clear]/history
  /// reset the carries to start a fresh stream.
  void _writeDecoded(List<int> bytes) {
    var toDecode = _utf8Carry.isEmpty
        ? List<int>.from(bytes)
        : <int>[..._utf8Carry, ...bytes];
    _utf8Carry.clear();
    final trailing = _trailingIncompleteUtf8ByteCount(toDecode);
    if (trailing > 0) {
      _utf8Carry.addAll(toDecode.sublist(toDecode.length - trailing));
      toDecode = toDecode.sublist(0, toDecode.length - trailing);
    }
    if (toDecode.isEmpty) return;
    final sanitized = _stripUnsupportedPrivateCsi(
      utf8.decode(toDecode, allowMalformed: true),
    );
    final text = _normalizeNewlines(sanitized);
    if (text.isNotEmpty) {
      _sink.write(text);
    }
  }

  /// Strips `CSI > … m` private sequences (XTMODKEYS / modifyOtherKeys, which
  /// Claude Code emits at startup). xterm.dart ignores the `>` private marker
  /// and misparses them as plain SGR — e.g. `CSI > 4 ; 2 m` becomes SGR 4
  /// (underline), which poisons every subsequent cell and erase with a spurious
  /// underline. The emulator does not support these sequences anyway. A
  /// trailing, not-yet-terminated `CSI > …` is held back so a sequence split
  /// across chunks (or the history→live boundary) is still caught.
  String _stripUnsupportedPrivateCsi(String input) {
    var s = input;
    if (_privateCsiCarry.isNotEmpty) {
      s = _privateCsiCarry + s;
      _privateCsiCarry = '';
    }
    // Fast path: no ESC (and no carry, which always begins with ESC) -> nothing
    // to strip, so skip the partial scan and the full-string regex replace.
    if (!s.contains('\x1b')) {
      return s;
    }
    final partial = _partialPrivateCsi.firstMatch(s);
    // Only hold a bounded partial; otherwise let it flush to avoid unbounded
    // growth on a stream that never completes the sequence.
    if (partial != null && (s.length - partial.start) <= 24) {
      _privateCsiCarry = s.substring(partial.start);
      s = s.substring(0, partial.start);
    }
    return s.replaceAll(_completePrivateCsi, '');
  }

  /// Normalize bare LF to CRLF (leaving existing CRLF intact) so the emulator
  /// does not stair-step. A trailing '\r' is held back so a CRLF split across
  /// chunks (or the history→live boundary) is not doubled.
  String _normalizeNewlines(String input) {
    var s = input;
    if (_pendingCarriageReturn) {
      s = '\r$s';
      _pendingCarriageReturn = false;
    }
    if (s.endsWith('\r')) {
      _pendingCarriageReturn = true;
      s = s.substring(0, s.length - 1);
    }
    // Fast path: no LF means nothing to normalize.
    if (!s.contains('\n')) {
      return s;
    }
    // Promote every bare LF to CRLF while leaving existing CRLF intact. Done by
    // collapsing CRLF to LF then expanding all LF to CRLF — equivalent to a
    // `(?<!\r)\n` lookbehind but lookbehind-free, since older Safari/iOS WebKit
    // (Flutter Web targets) lack regex lookbehind and throw on it at runtime.
    return s.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
  }

  void _resetCarries() {
    _utf8Carry.clear();
    _pendingCarriageReturn = false;
    _privateCsiCarry = '';
    _appliedLiveSeq = null;
  }

  @override
  void dispose() {
    _suppressTimer?.cancel();
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
