import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'emulator_query_response.dart';
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
const Duration kSyncOutputWatchdogTimeout = Duration(milliseconds: 50);

const String _kSyncPrefix = '\x1b[?2026';
const String _kSyncStart = '\x1b[?2026h';
const String _kSyncEnd = '\x1b[?2026l';
const int _kSyncBufferCap = 1024 * 1024; // 1 MiB

const int _kSyncMarkerLength = 8; // length of '\x1b[?2026h' and '\x1b[?2026l'

const int _kMaxCarryEscapeLength = 32;

// Hoisted out of the per-chunk hot path (`_writeDecoded` runs on every live
// `Output`): a trailing not-yet-terminated `CSI > …` / `CSI ? 2026 …` and a complete
// `CSI > … m` private sequence.
final RegExp _partialEscapeSequence = RegExp(r'\x1b(?:\[(?:[>?]?[0-9;]*)?)?$');
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
  // Holds a trailing, not-yet-terminated escape prefix (e.g. `CSI > …` or
  // `CSI ? 2026 …`) so a sequence split across live chunks is joined.
  String _escapeCarry = '';

  // Synchronized Output (DEC Mode 2026): buffers redraws between `\x1b[?2026h`
  // and `\x1b[?2026l` so multi-line frames, spinner updates, and cursor moves
  // are delivered atomically in one `write` call without intermediate cursor jitter.
  final StringBuffer _syncBuffer = StringBuffer();
  bool _inSynchronizedOutput = false;
  Timer? _syncTimer;

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

  // True while we are writing to the sink, so synchronous emulator auto-responses
  // (DSR/DA/Kitty queries) are not forwarded back to the host as fake user input.
  bool _isWritingSink = false;

  // True if the previous chunk ended with '\r' so a split '\r\n' is not doubled.
  bool _pendingCarriageReturn = false;

  // True for a brief window after a history replay; while set, emulator output
  // (the program's own query auto-answers) is not forwarded to the host.
  bool _suppressHostInput = false;
  Timer? _suppressTimer;

  /// True while emulator-emitted bytes must not reach the host as user input
  /// (during and just after a history replay). The view's input forwarding
  /// consults this so replayed cursor/device reports are not echoed back.
  bool get isSuppressingHostInput => _suppressHostInput;

  /// True while writing to the sink (i.e. decoding host bytes). Synchronous
  /// query responses produced by the emulator must not reach the host.
  bool get isWritingSink => _isWritingSink;

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
        if (!s.exited &&
            !_suppressHostInput &&
            !isEmulatorQueryResponse(data)) {
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
    if (_isWritingSink || isEmulatorQueryResponse(data)) {
      return;
    }
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
    if (sanitized.isNotEmpty) {
      _processSynchronizedOutput(sanitized);
    }
  }

  /// Processes Synchronized Output (DEC Mode 2026, `\x1b[?2026h` / `\x1b[?2026l`).
  ///
  /// CLI tools (such as `agy`) wrap animated redraws in Mode 2026 so all intermediate
  /// cursor repositions and status updates are delivered in one atomic frame rather
  /// than jittering across multiple network chunks.
  void _processSynchronizedOutput(String input) {
    if (!_inSynchronizedOutput && !input.contains(_kSyncPrefix)) {
      _writeDirect(input);
      return;
    }
    var cursor = 0;
    while (cursor < input.length) {
      if (_inSynchronizedOutput) {
        final endIdx = input.indexOf(_kSyncEnd, cursor);
        if (endIdx != -1) {
          final chunkEnd = endIdx + _kSyncMarkerLength;
          _syncBuffer.write(input.substring(cursor, chunkEnd));
          cursor = chunkEnd;
          _inSynchronizedOutput = false;
          _syncTimer?.cancel();
          _syncTimer = null;
          _flushSyncBuffer();
        } else {
          _syncBuffer.write(input.substring(cursor));
          cursor = input.length;
          if (_syncBuffer.length >= _kSyncBufferCap) {
            debugPrint(
              'TerminalStore: synchronized output buffer exceeded $_kSyncBufferCap bytes; force-flushing',
            );
            _inSynchronizedOutput = false;
            _syncTimer?.cancel();
            _syncTimer = null;
            _flushSyncBuffer();
          } else {
            _rearmSyncWatchdog();
          }
        }
      } else {
        final startIdx = input.indexOf(_kSyncStart, cursor);
        if (startIdx != -1) {
          if (startIdx > cursor) {
            _writeDirect(input.substring(cursor, startIdx));
          }
          _inSynchronizedOutput = true;
          _syncBuffer.write(_kSyncStart);
          cursor = startIdx + _kSyncMarkerLength;
          _rearmSyncWatchdog();
        } else {
          final text = cursor == 0 ? input : input.substring(cursor);
          _writeDirect(text);
          cursor = input.length;
        }
      }
    }
  }

  void _rearmSyncWatchdog() {
    _syncTimer?.cancel();
    _syncTimer = Timer(kSyncOutputWatchdogTimeout, () {
      if (_escapeCarry.isNotEmpty) {
        final carried = _escapeCarry;
        _escapeCarry = '';
        _processSynchronizedOutput(carried);
      }
      if (_inSynchronizedOutput || _syncBuffer.isNotEmpty) {
        _inSynchronizedOutput = false;
        _syncTimer?.cancel();
        _syncTimer = null;
        _flushSyncBuffer();
      }
    });
  }

  void _flushSyncBuffer() {
    if (_syncBuffer.isEmpty) return;
    final toFlush = _syncBuffer.toString();
    _syncBuffer.clear();
    _writeDirect(toFlush);
  }

  void _writeDirect(String text) {
    if (text.isEmpty) return;
    final wasWriting = _isWritingSink;
    _isWritingSink = true;
    try {
      if (_inSynchronizedOutput || text.contains(_kSyncPrefix)) {
        _pendingCarriageReturn = text.endsWith('\r');
        _sink.write(text);
      } else {
        _sink.write(_translateNewlines(text));
      }
    } finally {
      _isWritingSink = wasWriting;
    }
  }

  static bool _isFollowedByRelativeCursorMovement(
    String text,
    int indexAfterLf,
  ) {
    if (indexAfterLf + 2 >= text.length) return false;
    if (text.codeUnitAt(indexAfterLf) != 0x1b ||
        text.codeUnitAt(indexAfterLf + 1) != 0x5b) {
      return false;
    }
    final firstUnit = text.codeUnitAt(indexAfterLf + 2);
    // Reject private/experimental CSI parameter bytes: ?, >, <, =
    if (firstUnit == 0x3f ||
        firstUnit == 0x3e ||
        firstUnit == 0x3c ||
        firstUnit == 0x3d) {
      return false;
    }
    var i = indexAfterLf + 2;
    while (i < text.length &&
        ((text.codeUnitAt(i) >= 48 && text.codeUnitAt(i) <= 57) ||
            text.codeUnitAt(i) == 59)) {
      i++;
    }
    if (i < text.length) {
      final finalUnit = text.codeUnitAt(i);
      if (finalUnit == 0x44 || finalUnit == 0x43) {
        // 'D' or 'C'
        return true;
      }
    }
    return false;
  }

  String _translateNewlines(String input) {
    if (input.isEmpty) return input;

    var needsTranslation = false;
    for (var i = 0; i < input.length; i++) {
      final isLf = input[i] == '\n';
      final precededByCr =
          (i > 0 && input[i - 1] == '\r') || (i == 0 && _pendingCarriageReturn);
      if (isLf && !precededByCr) {
        if (!_isFollowedByRelativeCursorMovement(input, i + 1)) {
          needsTranslation = true;
          break;
        }
      }
    }

    final endsWithCr = input.endsWith('\r');
    if (!needsTranslation) {
      _pendingCarriageReturn = endsWithCr;
      return input;
    }

    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final isLf = input[i] == '\n';
      final precededByCr =
          (i > 0 && input[i - 1] == '\r') || (i == 0 && _pendingCarriageReturn);
      if (isLf && !precededByCr) {
        if (!_isFollowedByRelativeCursorMovement(input, i + 1)) {
          buffer.write('\r');
        }
      }
      buffer.write(input[i]);
    }
    _pendingCarriageReturn = endsWithCr;
    return buffer.toString();
  }

  /// Strips `CSI > … m` private sequences (XTMODKEYS / modifyOtherKeys, which
  /// Claude Code emits at startup). xterm.dart ignores the `>` private marker
  /// and misparses them as plain SGR — e.g. `CSI > 4 ; 2 m` becomes SGR 4
  /// (underline), which poisons every subsequent cell and erase with a spurious
  /// underline. The emulator does not support these sequences anyway. A
  /// trailing, not-yet-terminated escape sequence (e.g. `CSI > …` or `CSI ? 2026 …`)
  /// is held back so a sequence split across chunks (or the history→live boundary)
  /// is still caught.
  String _stripUnsupportedPrivateCsi(String input) {
    var s = input;
    if (_escapeCarry.isNotEmpty) {
      s = _escapeCarry + s;
      _escapeCarry = '';
    }
    // Fast path: no ESC (and no carry, which always begins with ESC) -> nothing
    // to strip or carry, so skip the partial scan and the regex replace.
    if (!s.contains('\x1b')) {
      return s;
    }
    final scanTail = s.length > _kMaxCarryEscapeLength
        ? s.substring(s.length - _kMaxCarryEscapeLength)
        : s;
    final partial = _partialEscapeSequence.firstMatch(scanTail);
    // Only hold a bounded partial; otherwise let it flush to avoid unbounded
    // growth on a stream that never completes the sequence.
    if (partial != null) {
      var carryStart = (s.length - scanTail.length) + partial.start;
      // If the partial escape sequence is immediately preceded by a bare LF,
      // include the LF in the carry so newline translation isn't prematurely
      // evaluated without its following escape sequence across chunk boundaries.
      if (carryStart > 0 && s[carryStart - 1] == '\n') {
        final precededByCr =
            (carryStart > 1 && s[carryStart - 2] == '\r') ||
            (carryStart == 1 && _pendingCarriageReturn);
        if (!precededByCr) {
          carryStart -= 1;
        }
      }
      _escapeCarry = s.substring(carryStart);
      s = s.substring(0, carryStart);
      _rearmSyncWatchdog();
    }
    return s.replaceAll(_completePrivateCsi, '');
  }

  void _resetCarries() {
    _utf8Carry.clear();
    _escapeCarry = '';
    _pendingCarriageReturn = false;
    _syncTimer?.cancel();
    _syncTimer = null;
    _inSynchronizedOutput = false;
    _syncBuffer.clear();
    _appliedLiveSeq = null;
  }

  @override
  void dispose() {
    _suppressTimer?.cancel();
    _syncTimer?.cancel();
    _syncBuffer.clear();
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
