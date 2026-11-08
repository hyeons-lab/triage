import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'debug_log.dart';
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

/// Viewport-first replay budget: a full history replay keeps the newest
/// [kHistoryReplayMaxLines] complete lines and at most [kHistoryReplayMaxBytes]
/// bytes. Re-emulating a megabyte tail stalls first paint for seconds (worse
/// over a high-latency link, where the transfer itself lags); the newest lines
/// are the viewport plus scrollback the user actually sees, and live output
/// keeps accumulating past them. Older scrollback stays in the daemon log for
/// a future scroll-up paging pass to fetch on demand.
const int kHistoryReplayMaxLines = 1000;
const int kHistoryReplayMaxBytes = 256 * 1024;

/// Web replay budget: xterm.js parses `write` payloads incrementally without
/// blocking paint, so the web client replays the full 1 MiB tail the daemon
/// serves (~16k-24k lines). Native targets keep the smaller budget above
/// because package:xterm parses synchronously on the UI thread.
const int kHistoryReplayWebMaxLines = 50000;
const int kHistoryReplayWebMaxBytes = 1024 * 1024;

/// First history window requested on attach: enough for the viewport plus
/// instant scrollback, small enough that first paint never waits on a
/// megabyte tail. Scrolling near the top re-attaches with a doubling
/// window (see [nextHistoryWindowBytes]) up to the platform replay
/// budget above.
const int kHistoryFirstWindowBytes = 64 * 1024;

/// History window requested by attaches that discard the snapshot (input
/// lease acquisition): just enough to keep the protocol's empty-tail
/// shape without shipping a megabyte to throw away.
const int kHistoryLeaseProbeBytes = 1024;

/// Next history window after [current] when paging older scrollback:
/// doubling keeps the cumulative transfer near 2x the final depth,
/// capped at [max] (the platform replay budget: the trim drops
/// anything older anyway).
int nextHistoryWindowBytes({required int current, required int max}) {
  if (current <= 0) {
    return max <= 0 ? 0 : kHistoryFirstWindowBytes.clamp(1, max);
  }
  final doubled = current * 2;
  return doubled >= max ? max : doubled;
}

/// Both emulators' scrollback capacity in lines (xterm.dart `maxLines` and
/// the xterm.js `scrollback` option): the backstop the scaled line budget
/// below can never exceed.
const int kEmulatorMaxScrollbackLines = 50000;

/// Replay-trim budgets for a served history window, in
/// ([maxLines], [maxBytes]) kept newest-first by [trimHistoryTail].
///
/// The line budget scales with the window on native targets so each
/// deeper page emulates strictly more than the last: trimming every page
/// to the first-page budget replays the same suffix of the same log end
/// over and over and the buffer never grows. (On web the platform line
/// budget already equals the emulator backstop, so every window replays
/// the same line count and only the byte budget grows.) The byte budget
/// is the window itself, so a page never parses more than it asked for.
/// A null window (local seeds
/// and other replays that were never windowed) keeps the platform
/// budgets, exactly as before.
({int maxLines, int maxBytes}) historyTrimBudgetsForWindow(
  int? windowBytes, {
  required bool web,
}) {
  final platformLines = web
      ? kHistoryReplayWebMaxLines
      : kHistoryReplayMaxLines;
  final platformBytes = web
      ? kHistoryReplayWebMaxBytes
      : kHistoryReplayMaxBytes;
  if (windowBytes == null || windowBytes <= 0) {
    return (maxLines: platformLines, maxBytes: platformBytes);
  }
  final scaledLines = platformLines * windowBytes ~/ kHistoryFirstWindowBytes;
  return (
    maxLines: scaledLines.clamp(platformLines, kEmulatorMaxScrollbackLines),
    maxBytes: min(windowBytes, platformBytes),
  );
}

bool _isCursorPositioningNewline(List<int> bytes, int index, int end) {
  var k = index + 1;
  final maxLookahead = min(end, index + 32);
  while (k < maxLookahead && (bytes[k] == 0x0a || bytes[k] == 0x0d)) {
    k++;
  }
  if (k + 2 >= end || bytes[k] != 0x1b || bytes[k + 1] != 0x5b) {
    return false;
  }
  var p = k + 2;
  var hasDigits = false;
  while (p < end && bytes[p] >= 0x30 && bytes[p] <= 0x39) {
    hasDigits = true;
    p++;
  }
  if (!hasDigits || p >= end) {
    return false;
  }
  final finalByte = bytes[p];
  // Relative horizontal cursor move (`CSI Ps C` / `CSI Ps D`) immediately
  // after linefeeds, as in `\r\x1b[3A...\n\n\n\x1b[19D` spinner frames.
  return finalByte == 0x43 || finalByte == 0x44;
}

List<int> _collectGenuineNewlineIndices(List<int> bytes, int start, int end) {
  final indices = <int>[];
  var cursorUpDebt = 0;
  for (var i = start; i < end; i++) {
    final b = bytes[i];
    if (b == 0x1b && i + 1 < end && bytes[i + 1] == 0x5b) {
      var p = i + 2;
      var privateMarker = 0;
      if (p < end && bytes[p] >= 0x3c && bytes[p] <= 0x3f) {
        privateMarker = bytes[p];
        p++;
      }
      var firstParam = 0;
      var hasFirstParam = false;
      var seenSeparator = false;
      while (p < end && bytes[p] >= 0x30 && bytes[p] <= 0x3b) {
        final c = bytes[p];
        if (c == 0x3a || c == 0x3b) {
          seenSeparator = true;
        } else if (!seenSeparator) {
          hasFirstParam = true;
          firstParam = firstParam * 10 + (c - 0x30);
          if (firstParam > 1000) firstParam = 1000;
        }
        p++;
      }
      while (p < end && bytes[p] >= 0x20 && bytes[p] <= 0x2f) {
        p++;
      }
      if (p < end && bytes[p] >= 0x40 && bytes[p] <= 0x7e) {
        final finalByte = bytes[p];
        if (privateMarker == 0) {
          if (finalByte == 0x41) {
            final step = (!hasFirstParam || firstParam <= 0) ? 1 : firstParam;
            cursorUpDebt = min(500, cursorUpDebt + min(500, step));
          } else if (finalByte == 0x48 ||
              finalByte == 0x66 ||
              finalByte == 0x4a) {
            cursorUpDebt = 0;
          }
        }
        i = p;
        continue;
      }
    } else if (b == 0x0a) {
      if (cursorUpDebt > 0) {
        cursorUpDebt--;
      } else if (!_isCursorPositioningNewline(bytes, i, end)) {
        indices.add(i);
      }
    }
  }
  return indices;
}

/// Trims a full-replay history payload to its newest complete lines and
/// reports how many leading raw bytes were dropped (`droppedBytes`).
///
/// xterm is append-only, so a replay must still arrive oldest-first; this keeps
/// the last [maxLines] lines (a trailing newline terminates the last line
/// rather than starting an empty one) and at most [maxBytes] bytes, so first
/// paint waits on the viewport instead of the whole tail. A trimmed payload is
/// prefixed with an SGR reset so rendition state set before the cut cannot
/// bleed into it; an untrimmed payload (including empty, which the caller
/// treats as a no-op) is returned untouched.
///
/// `droppedBytes` measures the exact cut offset in the caller's input [bytes]
/// so `rawStart + droppedBytes` is the true log offset of the oldest retained
/// byte, while the log end offset stays `rawStart + original.length`.
({List<int> bytes, int droppedBytes}) trimHistoryTailWithOffset(
  List<int> bytes, {
  required int maxLines,
  required int maxBytes,
}) {
  if (bytes.isEmpty || maxLines <= 0 || maxBytes <= 0) {
    return (
      bytes: bytes.isEmpty ? bytes : const <int>[],
      droppedBytes: bytes.length,
    );
  }
  var end = bytes.length;
  if (bytes[end - 1] == 0x0a) end--;
  final newlineIndices = _collectGenuineNewlineIndices(bytes, 0, end);
  var start = newlineIndices.length >= maxLines
      ? newlineIndices[newlineIndices.length - maxLines] + 1
      : 0;
  final byteFloor = bytes.length - maxBytes;
  if (byteFloor > start) {
    // The byte cap binds. byteFloor > start >= 0, so byteFloor - 1 below
    // is a valid index.
    if (bytes[byteFloor - 1] == 0x0a) {
      start = byteFloor;
    } else {
      // Mid-line cut: advance to the next complete line boundary instead of
      // slicing an older row (and possibly a rune) in two. When no newline
      // follows (one line exceeds maxBytes), at least skip UTF-8
      // continuation bytes so decoding starts on a rune boundary.
      var lineStart = -1;
      for (var i = byteFloor; i < end; i++) {
        if (bytes[i] == 0x0a) {
          lineStart = i + 1;
          break;
        }
      }
      if (lineStart != -1) {
        start = lineStart;
      } else {
        start = byteFloor;
        while (start < bytes.length && (bytes[start] & 0xC0) == 0x80) {
          start++;
        }
      }
    }
  }
  if (start <= 0) {
    return (bytes: bytes, droppedBytes: 0);
  }
  const reset = <int>[0x1b, 0x5b, 0x30, 0x6d]; // ESC [ 0 m
  return (bytes: [...reset, ...bytes.sublist(start)], droppedBytes: start);
}

({
  List<int> prefixBytes,
  List<int> rawBytes,
  int retainedPrefixBytes,
  int droppedRawBytes,
})
trimHistoryReplay({
  required List<int> rawOutputPrefix,
  required List<int> rawOutput,
  required int maxLines,
  required int maxBytes,
}) {
  if (rawOutputPrefix.isEmpty) {
    final trimmed = trimHistoryTailWithOffset(
      rawOutput,
      maxLines: maxLines,
      maxBytes: maxBytes,
    );
    return (
      prefixBytes: const <int>[],
      rawBytes: trimmed.bytes,
      retainedPrefixBytes: 0,
      droppedRawBytes: trimmed.droppedBytes,
    );
  }
  if (rawOutput.isEmpty) {
    final trimmed = trimHistoryTailWithOffset(
      rawOutputPrefix,
      maxLines: maxLines,
      maxBytes: maxBytes,
    );
    final retained = rawOutputPrefix.length > trimmed.droppedBytes
        ? rawOutputPrefix.length - trimmed.droppedBytes
        : 0;
    return (
      prefixBytes: trimmed.bytes,
      rawBytes: const <int>[],
      retainedPrefixBytes: retained,
      droppedRawBytes: 0,
    );
  }
  if (maxLines <= 0 || maxBytes <= 0) {
    return (
      prefixBytes: const <int>[],
      rawBytes: const <int>[],
      retainedPrefixBytes: 0,
      droppedRawBytes: rawOutput.length,
    );
  }

  final prefixNewlines = _collectGenuineNewlineIndices(
    rawOutputPrefix,
    0,
    rawOutputPrefix.length,
  ).length;
  final prefixByteReserve = min(rawOutputPrefix.length, maxBytes ~/ 2);
  final prefixLineReserve = min(prefixNewlines, maxLines ~/ 2);
  final rawByteBudget = max(1, maxBytes - prefixByteReserve);
  final rawLineBudget = max(1, maxLines - prefixLineReserve);

  final trimmedRaw = trimHistoryTailWithOffset(
    rawOutput,
    maxLines: rawLineBudget,
    maxBytes: rawByteBudget,
  );
  final retainedRawBytes = rawOutput.length - trimmedRaw.droppedBytes;
  final retainedRawNewlines = _collectGenuineNewlineIndices(
    rawOutput,
    trimmedRaw.droppedBytes,
    rawOutput.length,
  ).length;

  final remainingBytes = max(0, maxBytes - retainedRawBytes);
  final remainingLines = max(0, maxLines - retainedRawNewlines);
  final trimmedPrefix = trimHistoryTailWithOffset(
    rawOutputPrefix,
    maxLines: remainingLines,
    maxBytes: remainingBytes,
  );
  final retainedPrefix = rawOutputPrefix.length > trimmedPrefix.droppedBytes
      ? rawOutputPrefix.length - trimmedPrefix.droppedBytes
      : 0;

  return (
    prefixBytes: trimmedPrefix.bytes,
    rawBytes: trimmedRaw.bytes,
    retainedPrefixBytes: retainedPrefix,
    droppedRawBytes: trimmedRaw.droppedBytes,
  );
}

final RegExp _leadingTornCsi = RegExp(
  r'^(?:\[[?>]?[0-9;]*[mHfABCDEFGJKhlr]|[?>][0-9;]+[hlm]|;[0-9;]*[mHfABCDEFGJKhlr]|[0-9]+;[0-9;]*[mHfABCDEFGJKhlr]|0m)',
);

List<int> _sanitizeRawTailStart(List<int> bytes) {
  if (bytes.isEmpty) return bytes;
  var start = 0;
  while (start < bytes.length && (bytes[start] & 0xC0) == 0x80) {
    start++;
  }
  final scanEnd = min(bytes.length, start + 32);
  final asciiBuf = StringBuffer();
  for (var i = start; i < scanEnd; i++) {
    final b = bytes[i];
    if (b < 0x20 || b > 0x7e) break;
    asciiBuf.writeCharCode(b);
  }
  final match = _leadingTornCsi.firstMatch(asciiBuf.toString());
  if (match != null) {
    start += match.end;
  }
  if (start <= 0) return bytes;
  return bytes.sublist(start);
}

List<int> trimHistoryTail(
  List<int> bytes, {
  required int maxLines,
  required int maxBytes,
}) => trimHistoryTailWithOffset(
  bytes,
  maxLines: maxLines,
  maxBytes: maxBytes,
).bytes;

/// How far below the dedup baseline an `output_seq` may fall and still be a
/// re-delivery rather than a fresh numbering epoch.
///
/// `output_seq` counts events within one daemon *instance*: a cold restore or a
/// session revive restarts it at 0 while the byte log continues unbroken (the
/// same session observed either side of a restart reports one `bytes_logged`
/// under two very different `output_seq`; a handover, by contrast, preserves
/// both counters). A client that kept the pre-restart high-water would score
/// every renumbered chunk as a duplicate and go permanently deaf: history
/// frozen on screen, cursor still blinking, typing still reaching the PTY
/// with nothing it produces ever drawn.
///
/// The daemon replays at most `EVENT_REPLAY_BUFFER` (1024) events to a lagging
/// subscriber and sends `ResyncRequired` beyond that, so no genuine re-delivery
/// can regress further than this. Anything below it is a new epoch.
const int kSeqEpochResetWindow = 1024;

/// How long emulator-emitted bytes stay suppressed after a history replay. The
/// program's own terminal queries (DSR/cursor reports) are replayed into the
/// emulator, which auto-answers them; those answers must not be forwarded to the
/// host as fake user input. xterm.dart answers synchronously inside `write`,
/// xterm.js a tick later — this window covers both.
const Duration kHistoryInputSuppression = Duration(milliseconds: 50);
const Duration kSyncOutputWatchdogTimeout = Duration(milliseconds: 50);

/// Upper bound on how long synchronized output stays invisible while its
/// block is still open. Tools like `agy` wrap an entire streaming response in
/// a single Mode 2026 block; every chunk re-arms the idle watchdog, so
/// without this the screen would freeze for the whole generation and only
/// paint at the closing marker. Flushing periodically keeps the stream live
/// while small back-to-back frames (which complete well inside this interval)
/// still land atomically.
const Duration kSyncOutputLiveFlushInterval = Duration(milliseconds: 100);

/// How long a Mode 2026 frame may stay open on the wire with no bytes at all
/// before it is treated as abandoned.
///
/// A frame legitimately spans a whole `agy` generation, minutes at a time, so
/// this cannot be an elapsed-time bound. It is an *idle* bound instead: a live
/// generation is always emitting (tokens, spinner frames, status redraws),
/// while an application killed mid-frame goes silent forever. The clock is
/// reset when frame bytes reach the sink, which for a held block means on each
/// live flush rather than on each chunk's arrival. Without it a
/// frame that never receives its closing marker would leave newline
/// translation disabled for the rest of the session, which turns ordinary
/// shell output into a staircase.
const Duration kSyncFrameAbandonTimeout = Duration(seconds: 30);

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
final RegExp _completePrivateCsi = RegExp(r'\x1b\[(?:>[0-9;]*m|3J)');

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
  // Periodic flush while a synchronized block stays open (see
  // [kSyncOutputLiveFlushInterval]). Rearmed on every tick until the block
  // closes; cancelled by _closeSyncBlockAndFlush (the end marker, the capacity
  // cap and the idle watchdog all route through it), by _resetCarries, and by
  // dispose.
  Timer? _syncLiveFlushTimer;
  // Guards against a frame that never receives its closing marker (see
  // [kSyncFrameAbandonTimeout]). Rearmed whenever frame bytes reach the sink.
  Timer? _frameAbandonTimer;
  // Set once dispose() runs. A flush writes to the sink synchronously, so a
  // listener reacting to that write can dispose us part-way through a tick or
  // through _processSynchronizedOutput's loop; both would otherwise carry on
  // and arm timers that fire against a disposed sink.
  bool _disposed = false;
  // Whether the application has opened a Mode 2026 frame and not yet closed it.
  // Distinct from _inSynchronizedOutput, which only tracks whether we are still
  // *holding* one: the watchdog and the capacity cap both stop holding a block
  // that is still open on the wire, and everything up to the real closing
  // marker is still frame content that must not be newline-translated.
  bool _frameOpenOnWire = false;

  // Live chunks received before we are sized / while awaiting history, plus a
  // running byte total so the buffer can be bounded (see [kPendingLiveByteCap]).
  final List<_QueuedLive> _pendingLive = <_QueuedLive>[];
  int _pendingLiveBytes = 0;

  // Highest live `output_seq` already applied. Combined with the history
  // high-water, this is the single de-duplication baseline, it also drops a
  // live chunk re-delivered out of order over a flaky connection.
  int? _appliedLiveSeq;

  // Total cumulative bytes from the host output log applied to the sink.
  // Initialized from rawOutputStart + history.length on history replay, and
  // incremented on each applied live chunk. Used for gapless delta-merging of
  // subsequent history snapshots without clearing the terminal.
  int? _appliedLogBytes;

  // Absolute log byte offset where the last full history replay started.
  // Preserved across delta merges and ignored empty snapshots so scroll-up
  // paging knows the true start of the buffer held in the terminal.
  int? _appliedHistoryStart;

  // Number of journaled prefix bytes retained by the last full history replay.
  int _appliedHistoryPrefixBytes = 0;

  // Retained raw tail bytes `[appliedHistoryStart..appliedLogBytes]` so HTTP
  // backward range pages (`before_byte = appliedHistoryStart`) can prepend only
  // the older slice without re-downloading the already-held tail.
  final BytesBuilder _retainedRawBytes = BytesBuilder(copy: false);
  int? _retainedRawStart;
  int? _retainedRawSeq;

  /// Absolute log byte offset where the retained raw tail begins, if available.
  int? get retainedRawStart => _retainedRawStart;

  /// Splices an older raw byte slice `[rawOutputStart..rawOutputEnd]` ahead of
  /// the retained raw tail when `rawOutputEnd == _retainedRawStart`.
  ({Uint8List bytes, int? throughOutputSeq})? spliceBackwardHistoryPage(
    List<int> olderBytes, {
    required int rawOutputStart,
    required int rawOutputEnd,
  }) {
    final retainedStart = _retainedRawStart;
    if (retainedStart == null || rawOutputEnd != retainedStart) {
      return null;
    }
    final retained = _retainedRawBytes.toBytes();
    final combined = Uint8List(olderBytes.length + retained.length);
    combined.setRange(0, olderBytes.length, olderBytes);
    combined.setRange(olderBytes.length, combined.length, retained);
    return (bytes: combined, throughOutputSeq: _retainedRawSeq);
  }

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

  /// Highest applied live output sequence number.
  int? get appliedLiveSeq => _appliedLiveSeq;

  /// Total cumulative bytes from the host output log applied to the sink.
  int? get appliedLogBytes => _appliedLogBytes;

  /// Absolute log byte offset where the last full history replay started.
  int? get appliedHistoryStart => _appliedHistoryStart;

  /// Number of journaled prefix bytes retained by the last full history replay.
  int get appliedHistoryPrefixBytes => _appliedHistoryPrefixBytes;

  bool _pagingHistory = false;

  /// True while a backward history page RPC is in flight and live chunks are
  /// being shadow-buffered in `_pendingLive`.
  bool get isPagingHistory => _pagingHistory;

  /// Arms shadow-buffering of live chunks while a backward history page RPC is
  /// in flight so chunks arriving after the daemon snapshot are replayed after
  /// the wider history tail.
  void beginHistoryPaging() {
    _pagingHistory = true;
  }

  /// Disarms shadow-buffering once the backward history page RPC finishes and
  /// folds any shadow-queued chunks into [_retainedRawBytes] before clearing
  /// [_pendingLive] when the page bails out while live.
  void endHistoryPaging() {
    final wasPaging = _pagingHistory;
    _pagingHistory = false;
    if (_state.phase == AttachPhase.live && _state.sized) {
      if (wasPaging && _pendingLive.isNotEmpty) {
        for (final q in _pendingLive) {
          _appendRetainedRaw(q.bytes, q.outputSeq);
        }
      }
      _clearPendingLive();
    }
  }

  // ---- Public API -----------------------------------------------------------

  void dispatch(TerminalIntent intent) {
    if (_disposed) return;
    final next = _reduce(_state, intent);
    // A sink listener reacting to a mid-reduce write can dispose us before we
    // get here; notifying a disposed ChangeNotifier would throw.
    if (_disposed) return;
    if (next != _state) {
      _state = next;
      notifyListeners();
    }
  }

  // ---- Reducer --------------------------------------------------------------

  TerminalState _reduce(TerminalState s, TerminalIntent intent) {
    switch (intent) {
      case Attach(:final preservePendingLive):
        // Start of a fresh attach lifecycle: drop any carries and (unless
        // preserving in-flight page live chunks) any live chunks buffered
        // against a prior attach so they cannot leak into this session once
        // HistoryBytes arrives.
        _resetCarries();
        if (!preservePendingLive) {
          _pagingHistory = false;
          _clearPendingLive();
        }
        _appliedLiveSeq = null;
        _appliedLogBytes = null;
        _appliedHistoryStart = null;
        _appliedHistoryPrefixBytes = 0;
        _retainedRawBytes.clear();
        _retainedRawStart = null;
        _retainedRawSeq = null;
        return s.copyWith(
          phase: AttachPhase.awaitingHistory,
          exited: false,
          scrollbackReady: false,
          // The other two dedup inputs are reset just above; leaving the
          // baseline behind let a stale one outlive the attach it came from.
          // The [HistoryBytes] that ends this attach re-establishes it.
          resetHistoryHighWaterSeq: true,
        );

      case Detach():
        endHistoryPaging();
        _closeFrameOnWire();
        return s.copyWith(phase: AttachPhase.detached);

      case Exited():
        // Whatever the process was drawing, it is not going to close it. Flush
        // first: retiring the frame while a block is still held would let the
        // watchdog re-derive it from the buffered start marker and re-arm the
        // abandon timer, so newline translation would stay off for 30s.
        _closeSyncBlockAndFlush();
        _closeFrameOnWire();
        return s.copyWith(exited: true);

      case Clear():
        // Hard reset: also drop queued pre-size/await-history live so it cannot
        // later re-populate the cleared terminal.
        _pagingHistory = false;
        _sink.clear();
        _resetCarries();
        _clearPendingLive();
        _appliedLiveSeq = null;
        _appliedLogBytes = null;
        _appliedHistoryStart = null;
        _retainedRawBytes.clear();
        _retainedRawStart = null;
        _retainedRawSeq = null;
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
        :final rawOutputStart,
        :final windowBytes,
        :final rawOutputPrefix,
      ):
        return _reduceHistory(
          s,
          bytes,
          cols,
          rows,
          throughOutputSeq,
          rawOutputStart: rawOutputStart,
          windowBytes: windowBytes,
          rawOutputPrefix: rawOutputPrefix,
        );

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
    // change always re-applies the size and marks it sized, no separate branch.
    final sizeChanged = cols != s.cols || rows != s.rows || !s.sized;
    if (sizeChanged) {
      _applyResizeToSink(cols, rows);
      next = next.copyWith(cols: cols, rows: rows, sized: true);
    }

    // Now that we have a size, drain anything we buffered (only once live and
    // not shadow-buffering an in-flight history page).
    if (next.sized && next.phase == AttachPhase.live && !_pagingHistory) {
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
    int? throughOutputSeq, {
    int? rawOutputStart,
    int? windowBytes,
    List<int> rawOutputPrefix = const [],
  }) {
    // Replay at the client's target grid size ([cols] x [rows], the current
    // emulator/view size chosen by the caller, not the host capture size). A
    // later viewport [Resize] reflows and the live repaint self-heals.
    var next = s;
    if (cols >= kMinTerminalCols && rows >= kMinTerminalRows) {
      final sizeChanged = cols != s.cols || rows != s.rows || !s.sized;
      if (sizeChanged) {
        _applyResizeToSink(cols, rows);
        next = next.copyWith(cols: cols, rows: rows, sized: true);
      }
    }

    // Empty payloads carry no paintable information: never clear, re-anchor,
    // or advance baselines on them. A history-less resync snapshot (old host,
    // resize-shaped response) must not wipe a live terminal, and advancing
    // the seq baseline past in-flight live would drop the replayed bytes as
    // duplicates. First history and exited sessions still fall through to the
    // full replay below; a genuinely truncated log replays on its first
    // non-empty tail, which still carries the regression evidence. The
    // journaled prefix counts as payload: a prefix-only snapshot still paints.
    if (bytes.isEmpty &&
        rawOutputPrefix.isEmpty &&
        s.scrollbackReady &&
        !s.exited) {
      endHistoryPaging();
      if (next.sized) {
        _flushPendingLive(next.historyHighWaterSeq);
      }
      return next.copyWith(
        phase: AttachPhase.live,
        scrollbackReady: true,
        exited: false,
      );
    }

    // Sanitize before the byte arithmetic below; unknowns take the seq
    // fallback or a full replay (see [_sanitizeCounter]).
    final throughSeq = _sanitizeCounter(throughOutputSeq);
    final rawStart = _sanitizeCounter(rawOutputStart);

    final currentSeq = _appliedLiveSeq ?? s.historyHighWaterSeq;
    final currentLogBytes = _appliedLogBytes;
    final lastSnapshotSeq = s.historyHighWaterSeq;

    // A snapshot sequence regression occurs when:
    // 1. The new snapshot's sequence drops below the previous snapshot's sequence.
    // 2. The sequence drops far below the live baseline (an epoch reset).
    // 3. rawStart is null, the previous snapshot is at sequence 0, the new
    //    snapshot restarts at 0/1, and the live stream has already advanced
    //    (_appliedLiveSeq > 0), indicating a daemon counter restart.
    final isSnapshotSeqRegressed =
        throughSeq != null &&
        ((lastSnapshotSeq != null && throughSeq < lastSnapshotSeq) ||
            _isSeqEpochReset(throughSeq, _appliedLiveSeq) ||
            (rawStart == null &&
                lastSnapshotSeq == 0 &&
                (throughSeq == 0 || throughSeq == 1) &&
                _appliedLiveSeq != null &&
                _appliedLiveSeq! > 0));

    // A log byte regression occurs when:
    // 1. There is a forward gap: the client has only seen up to currentLogBytes,
    //    but the new tail starts at rawStart > currentLogBytes.
    // 2. The log end moved backward under a fresh sequence: the daemon rebases
    //    `bytes_logged` when it trims while `output_seq` stays monotonic, so a
    //    trim presents as an advanced (or unchanged) sequence with fewer bytes.
    //    A stale snapshot also ends behind the live head, but a sequence
    //    that trails the live baseline without regressing below the snapshot
    //    high-water stays a no-op below.
    //    An unknown sequence fails toward replay, as before.
    final snapshotEndBytes = rawStart != null ? rawStart + bytes.length : null;
    final hasLogByteGap =
        rawStart != null &&
        currentLogBytes != null &&
        currentLogBytes < rawStart;
    final isSeqFresh =
        throughSeq != null &&
        (lastSnapshotSeq == null || throughSeq >= lastSnapshotSeq) &&
        (_appliedLiveSeq == null || throughSeq >= _appliedLiveSeq!);
    final isLogShrunk =
        currentLogBytes != null &&
        snapshotEndBytes != null &&
        snapshotEndBytes < currentLogBytes &&
        (throughSeq == null || isSeqFresh);

    final isRegressed = isSnapshotSeqRegressed || hasLogByteGap || isLogShrunk;

    final needsInitialPrefixReplay =
        rawOutputPrefix.isNotEmpty &&
        (bytes.isEmpty || _appliedHistoryPrefixBytes == 0);

    // Delta merge: if the store already has scrollback content, is not exited,
    // and is not regressed, check whether the new snapshot overlaps with what
    // we already applied.
    // Delta paths intentionally skip onHistoryReplayed: nothing was cleared,
    // so the viewport stays and both panes follow the tail on live writes.
    if (!s.exited &&
        !isRegressed &&
        !needsInitialPrefixReplay &&
        s.scrollbackReady &&
        (currentSeq != null || currentLogBytes != null)) {
      if (rawStart != null &&
          currentLogBytes != null &&
          snapshotEndBytes != null) {
        if (currentLogBytes >= snapshotEndBytes) {
          endHistoryPaging();
          final resolvedSeq = throughSeq != null
              ? max(next.historyHighWaterSeq ?? 0, throughSeq)
              : next.historyHighWaterSeq;
          if (throughSeq != null) {
            _appliedLiveSeq = _appliedLiveSeq == null
                ? throughSeq
                : max(_appliedLiveSeq!, throughSeq);
            _retainedRawSeq = _retainedRawSeq == null
                ? throughSeq
                : max(_retainedRawSeq!, throughSeq);
          }
          if (next.sized) {
            _flushPendingLive(resolvedSeq);
          }
          return next.copyWith(
            phase: AttachPhase.live,
            scrollbackReady: true,
            historyHighWaterSeq: resolvedSeq,
            exited: false,
          );
        }

        if (currentLogBytes >= rawStart) {
          final deltaOffset = currentLogBytes - rawStart;
          if (deltaOffset >= 0 && deltaOffset < bytes.length) {
            endHistoryPaging();
            final deltaBytes = bytes is Uint8List
                ? Uint8List.sublistView(bytes, deltaOffset)
                : bytes.sublist(deltaOffset);
            // As in the full-replay path below: suppress the emulator's
            // answers to the re-fed queries so they never reach the host.
            _beginHostInputSuppression();
            _applyLive(deltaBytes, throughSeq);
            final resolvedSeq = throughSeq != null
                ? max(next.historyHighWaterSeq ?? 0, throughSeq)
                : next.historyHighWaterSeq;
            if (next.sized) {
              _flushPendingLive(resolvedSeq);
            }
            // Paint any buffered Mode 2026 frame content without closing the
            // block: a snapshot can land mid-frame during streaming, and
            // closing here would break atomic frame semantics. The end marker,
            // capacity cap, and idle watchdog still close it.
            _flushSyncBuffer();
            return next.copyWith(
              phase: AttachPhase.live,
              scrollbackReady: true,
              historyHighWaterSeq: resolvedSeq,
              exited: false,
            );
          }
        }
      } else if (throughSeq != null &&
          currentSeq != null &&
          currentSeq >= throughSeq) {
        endHistoryPaging();
        final resolvedSeq = max(next.historyHighWaterSeq ?? 0, throughSeq);
        _appliedLiveSeq = _appliedLiveSeq == null
            ? throughSeq
            : max(_appliedLiveSeq!, throughSeq);
        _retainedRawSeq = _retainedRawSeq == null
            ? throughSeq
            : max(_retainedRawSeq!, throughSeq);
        if (next.sized) {
          _flushPendingLive(resolvedSeq);
        }
        return next.copyWith(
          phase: AttachPhase.live,
          scrollbackReady: true,
          historyHighWaterSeq: resolvedSeq,
          exited: false,
        );
      }
    }

    final wasPagingInLive =
        _pagingHistory && s.phase == AttachPhase.live && s.sized;
    _pagingHistory = false;
    if (isSnapshotSeqRegressed || (wasPagingInLive && throughSeq == null)) {
      _clearPendingLive();
    }

    tdbg(
      'store.history',
      'FULL REPLAY ${bytes.length}B+${rawOutputPrefix.length}P at ${cols}x$rows '
          'throughSeq=$throughSeq rawStart=$rawStart windowBytes=$windowBytes',
    );
    _sink.clear();
    // Reset carries so history starts a fresh decode stream; history then
    // decodes through the same streaming path as live, so a UTF-8 rune, CRLF
    // pair, or `CSI > … m` sequence split across the history to live boundary
    // (the snapshot tail can end mid-sequence) carries into the first live chunk.
    _resetCarries();
    // Replaying the raw tail re-feeds the program's own terminal queries to the
    // emulator, which auto-answers them; suppress those answers so they are not
    // echoed to the host as user input.
    _beginHostInputSuppression();
    // Viewport-first: replay only the newest lines so a megabyte tail doesn't
    // stall first paint; the baseline below still uses the original end offset
    // (trimming drops a prefix) so delta merges stay anchored. The budgets
    // scale with the served window so each deeper page emulates more than
    // the last instead of replaying the same trimmed suffix.
    // `kIsWeb` selects the xterm.js sink exactly: every other target parses
    // through package:xterm on the UI thread.
    //
    // The journaled prefix replays ahead of the raw tail (it holds the
    // scrolled lines the raw window can no longer reach). It joins the
    // replay stream only: every byte coordinate above and below stays in
    // raw-log space, so delta merges keep ignoring the prefix. Trimming
    // the combined stream keeps the newest bytes, so an over-budget
    // prefix sheds its oldest lines first; windowed replays then still
    // fit the raw tail, while unwindowed ones trim it as before.
    final budgets = historyTrimBudgetsForWindow(windowBytes, web: kIsWeb);
    final trimmed = trimHistoryReplay(
      rawOutputPrefix: rawOutputPrefix,
      rawOutput: bytes,
      maxLines: budgets.maxLines,
      maxBytes: budgets.maxBytes,
    );
    if (trimmed.prefixBytes.isNotEmpty) {
      _writeDecoded(trimmed.prefixBytes);
      if (trimmed.rawBytes.isNotEmpty) {
        final trailingNewline = trimmed.prefixBytes.last == 0x0a ? '' : '\r\n';
        final pushScrollback = rows > 1 ? '\r\n' * (rows - 1) : '';
        _writeDecoded(
          utf8.encode('$trailingNewline$pushScrollback\x1b[H\x1b[0m'),
        );
      } else if (trimmed.prefixBytes.last != 0x0a) {
        _writeDecoded(const <int>[0x0d, 0x0a]);
      }
    }
    if (trimmed.rawBytes.isNotEmpty) {
      final rawToWrite = (rawStart ?? 0) > 0 && trimmed.droppedRawBytes == 0
          ? _sanitizeRawTailStart(trimmed.rawBytes)
          : trimmed.rawBytes;
      _writeDecoded(rawToWrite);
    }

    _appliedHistoryPrefixBytes = trimmed.retainedPrefixBytes;
    _appliedHistoryStart = rawStart != null
        ? rawStart + trimmed.droppedRawBytes
        : null;
    if (rawStart != null) {
      _appliedLogBytes = rawStart + bytes.length;
    } else {
      _appliedLogBytes = bytes.length;
    }
    _retainedRawBytes.clear();
    _retainedRawStart = _appliedHistoryStart;
    _retainedRawSeq = throughSeq;
    if (_retainedRawStart != null && bytes.length > trimmed.droppedRawBytes) {
      _retainedRawBytes.add(bytes.sublist(trimmed.droppedRawBytes));
    }

    next = next.copyWith(
      phase: AttachPhase.live,
      scrollbackReady: true,
      historyHighWaterSeq: throughSeq,
      exited: false,
    );

    if (next.sized) {
      _flushPendingLive(throughSeq);
    }
    // #162's contract is that every decoded byte has reached the sink by the
    // time this fires, and its web bottom-restore depends on it. A replay
    // ending mid-frame would otherwise still be sitting in _syncBuffer.
    _closeSyncBlockAndFlush();
    if (!_disposed) _sink.onHistoryReplayed();
    return next;
  }

  TerminalState _reduceLive(TerminalState s, List<int> bytes, int? outputSeq) {
    if (s.phase == AttachPhase.detached) {
      return s;
    }
    // As in _reduceHistory: a negative is corrupt, so null keeps it off
    // the baselines instead of epoch-resetting onto it.
    final seq = _sanitizeCounter(outputSeq);
    var next = s;
    if (_isSeqEpochReset(seq, s.historyHighWaterSeq)) {
      // The counter this baseline described no longer exists. Drop it and
      // rebase on the new epoch; `_appliedLogBytes` is deliberately kept,
      // because log byte offsets (unlike `output_seq`) survive a restart
      // and still anchor the next history delta-merge.
      _appliedLiveSeq = null;
      _retainedRawSeq = null;
      for (var i = 0; i < _pendingLive.length; i++) {
        final q = _pendingLive[i];
        if (q.outputSeq != null) {
          _pendingLive[i] = _QueuedLive(q.bytes, null);
        }
      }
      next = s.copyWith(resetHistoryHighWaterSeq: true);
    }
    if (_isDuplicate(seq, next.historyHighWaterSeq)) {
      return next;
    }
    if (!next.sized || next.phase == AttachPhase.awaitingHistory) {
      tdbg(
        'store.live',
        'QUEUED seq=$seq ${bytes.length}B '
            '(sized=${next.sized} phase=${next.phase})',
      );
      _enqueuePendingLive(_QueuedLive(bytes, seq));
      return next;
    }
    tdbg('store.live', 'APPLY seq=$seq ${bytes.length}B');
    if (_pagingHistory) {
      _enqueuePendingLive(_QueuedLive(bytes, seq));
    }
    _applyLive(bytes, seq);
    return next;
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
      if (_pagingHistory && _state.phase == AttachPhase.live && _state.sized) {
        _appendRetainedRaw(old.bytes, old.outputSeq);
      }
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
    if (_appliedLogBytes != null) {
      _appliedLogBytes = _appliedLogBytes! + bytes.length;
    }
    if (outputSeq != null) {
      _appliedLiveSeq = _appliedLiveSeq == null
          ? outputSeq
          : max(_appliedLiveSeq!, outputSeq);
    }
    if (!_pagingHistory) {
      _appendRetainedRaw(bytes, outputSeq);
    }
  }

  void _appendRetainedRaw(List<int> bytes, int? outputSeq) {
    if (_retainedRawStart != null && bytes.isNotEmpty) {
      _retainedRawBytes.add(bytes);
      final maxRetainedBytes = kIsWeb
          ? kHistoryReplayWebMaxBytes
          : kHistoryReplayMaxBytes;
      final total = _retainedRawBytes.length;
      if (total > maxRetainedBytes) {
        final drop = total - maxRetainedBytes;
        final current = _retainedRawBytes.takeBytes();
        _retainedRawBytes.add(Uint8List.sublistView(current, drop));
        _retainedRawStart = _retainedRawStart! + drop;
        if (_appliedHistoryStart != null &&
            _retainedRawStart! > _appliedHistoryStart!) {
          _appliedHistoryStart = _retainedRawStart;
        }
      }
    }
    if (outputSeq != null) {
      _retainedRawSeq = _retainedRawSeq == null
          ? outputSeq
          : max(_retainedRawSeq!, outputSeq);
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

  /// A live chunk starts a new numbering epoch when its `output_seq` falls
  /// further below the dedup baseline than the daemon could ever replay — the
  /// signature of the daemon restarting its counter (a cold restore or a
  /// session revive resets it to 0 while `bytes_logged` is re-derived from
  /// the log; a handover preserves both). See [kSeqEpochResetWindow]; the
  /// history path makes the same call via `isSnapshotSeqRegressed`. A fresh
  /// session whose baseline never reached the window still resets to 0/1
  /// after a restart, so a regression to the start of a new epoch counts
  /// regardless of the window once the baseline is past single digits
  /// (guarding startup redeliveries of seq 0/1 against reset).
  bool _isSeqEpochReset(int? outputSeq, int? highWaterSeq) {
    if (outputSeq == null) return false;
    final baseline = max(highWaterSeq ?? 0, _appliedLiveSeq ?? 0);
    if (baseline == 0) return false;
    return outputSeq < baseline - kSeqEpochResetWindow ||
        ((outputSeq == 0 || outputSeq == 1) && baseline > 10);
  }

  void _beginHostInputSuppression() {
    if (_disposed) return;
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
    // `toDecode` is only ever read (decode) or replaced (sublist copies), so
    // aliasing the input when there is no carry is safe and keeps the common
    // case zero-copy.
    var toDecode = _utf8Carry.isEmpty ? bytes : <int>[..._utf8Carry, ...bytes];
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
  /// than jittering across multiple network chunks. Because a block can also
  /// span an entire streaming response, an open block additionally flushes
  /// periodically ([kSyncOutputLiveFlushInterval]) so the screen stays live
  /// instead of freezing until the closing marker.
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
          // The flushed buffer ends with the closing marker, so _writeVerbatim
          // derives the frame state from it; this path needs no second writer.
          _closeSyncBlockAndFlush();
        } else {
          _syncBuffer.write(input.substring(cursor));
          cursor = input.length;
          if (_syncBuffer.length >= _kSyncBufferCap) {
            debugPrint(
              'TerminalStore: synchronized output buffer exceeded $_kSyncBufferCap bytes; force-flushing',
            );
            _closeSyncBlockAndFlush();
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
          _frameOpenOnWire = true;
          _syncBuffer.write(_kSyncStart);
          cursor = startIdx + _kSyncMarkerLength;
          _armSyncLiveFlush();
          _rearmSyncWatchdog();
        } else {
          final text = cursor == 0 ? input : input.substring(cursor);
          _writeDirect(text);
          cursor = input.length;
        }
      }
    }
  }

  /// Closes an open synchronized block and paints what it accumulated.
  ///
  /// Every exit from a block runs through here (end marker, capacity cap, and
  /// the idle watchdog) so none of them can drift apart on the timers they
  /// each have to retire. The close cancels the watchdog, so re-arm it while
  /// a trailing partial escape is still held: the carry cannot flush eagerly
  /// (a split sequence may yet complete), and without this it strands whenever
  /// the close is the last event (a replay or exit with no live following, or
  /// an end marker landing in the chunk that armed the watchdog).
  void _closeSyncBlockAndFlush() {
    _inSynchronizedOutput = false;
    _syncTimer?.cancel();
    _syncTimer = null;
    _cancelSyncLiveFlush();
    _flushSyncBuffer();
    if (_escapeCarry.isNotEmpty) {
      _rearmSyncWatchdog();
    }
  }

  void _rearmSyncWatchdog() {
    if (_disposed) return;
    _syncTimer?.cancel();
    _syncTimer = Timer(kSyncOutputWatchdogTimeout, () {
      if (_escapeCarry.isNotEmpty) {
        final carried = _escapeCarry;
        _escapeCarry = '';
        _processSynchronizedOutput(carried);
      }
      if (_inSynchronizedOutput || _syncBuffer.isNotEmpty) {
        _closeSyncBlockAndFlush();
      }
    });
  }

  /// Arms the periodic live flush for an open synchronized block, unless one
  /// is already pending. The tick flushes whatever has accumulated but leaves
  /// the block open, so a sustained stream paints at least every
  /// [kSyncOutputLiveFlushInterval] instead of freezing until its end marker.
  void _armSyncLiveFlush() {
    if (_disposed) return;
    _syncLiveFlushTimer ??= Timer(
      kSyncOutputLiveFlushInterval,
      _onSyncLiveFlushTick,
    );
  }

  void _onSyncLiveFlushTick() {
    _syncLiveFlushTimer = null;
    if (_disposed || !_inSynchronizedOutput) return;
    _flushSyncBuffer();
    if (_inSynchronizedOutput) {
      _armSyncLiveFlush();
    }
  }

  void _cancelSyncLiveFlush() {
    _syncLiveFlushTimer?.cancel();
    _syncLiveFlushTimer = null;
  }

  void _flushSyncBuffer() {
    if (_syncBuffer.isEmpty) return;
    final toFlush = _syncBuffer.toString();
    _syncBuffer.clear();
    // Always verbatim: inside a block the application owns cursor and column
    // placement, so newline translation must not run. _writeDirect used to
    // infer this from the buffer still carrying the opening \x1b[?2026h, but a
    // live flush now consumes that marker, and the block's own flag is already
    // cleared by the time _closeSyncBlockAndFlush flushes the tail. Without
    // this the same bytes would render differently depending on whether a
    // 100ms boundary happened to fall mid-block.
    _writeVerbatim(toFlush);
  }

  void _writeDirect(String text) {
    if (text.isEmpty || _disposed) return;
    // Frame content goes to the sink untouched: inside a Mode 2026 frame the
    // application owns cursor and column placement, so a bare LF must not
    // acquire a carriage return.
    if (_frameOpenOnWire || text.contains(_kSyncPrefix)) {
      _writeVerbatim(text);
      return;
    }
    final wasWriting = _isWritingSink;
    _isWritingSink = true;
    try {
      _sink.write(_translateNewlines(text));
    } finally {
      _isWritingSink = wasWriting;
    }
  }

  /// Writes [text] to the sink exactly as received, with no newline
  /// translation, and updates the on-the-wire frame state from any markers it
  /// carries.
  void _writeVerbatim(String text) {
    if (text.isEmpty || _disposed) return;
    final lastStart = text.lastIndexOf(_kSyncStart);
    final lastEnd = text.lastIndexOf(_kSyncEnd);
    // A chunk can carry the closing marker and then ordinary output. Only the
    // frame's own bytes are exempt from newline translation, so hand the tail
    // back to _writeDirect rather than letting it inherit the exemption.
    //
    // Comparing only the last marker of each kind is enough because callers
    // never hand this text spanning a close and a reopen: _processSynchronizedOutput
    // splits its input at the first start marker, and _syncBuffer is flushed at
    // the close, so text arriving here holds at most one frame boundary. See
    // the 'a close and a reopen in one chunk' test, which pins that.

    final closes = lastEnd != -1 && lastEnd > lastStart;
    final split = closes ? lastEnd + _kSyncMarkerLength : text.length;
    final framePart = split == text.length ? text : text.substring(0, split);

    final wasWriting = _isWritingSink;
    _isWritingSink = true;
    try {
      _pendingCarriageReturn = framePart.endsWith('\r');
      _sink.write(framePart);
    } finally {
      _isWritingSink = wasWriting;
    }

    if (lastStart != -1 || lastEnd != -1) {
      _frameOpenOnWire = lastStart > lastEnd;
    }
    if (_frameOpenOnWire) {
      _rearmFrameAbandonTimer();
    } else {
      _frameAbandonTimer?.cancel();
      _frameAbandonTimer = null;
    }
    if (split < text.length) {
      _writeDirect(text.substring(split));
    }
  }

  void _rearmFrameAbandonTimer() {
    if (_disposed) return;
    _frameAbandonTimer?.cancel();
    _frameAbandonTimer = Timer(kSyncFrameAbandonTimeout, _closeFrameOnWire);
  }

  void _closeFrameOnWire() {
    _frameAbandonTimer?.cancel();
    _frameAbandonTimer = null;
    _frameOpenOnWire = false;
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

    final len = input.length;
    var needsTranslation = false;
    for (var i = 0; i < len; i++) {
      if (input.codeUnitAt(i) == 0x0A) {
        final precededByCr =
            (i > 0 && input.codeUnitAt(i - 1) == 0x0D) ||
            (i == 0 && _pendingCarriageReturn);
        if (!precededByCr &&
            !_isFollowedByRelativeCursorMovement(input, i + 1)) {
          needsTranslation = true;
          break;
        }
      }
    }

    final endsWithCr = input.codeUnitAt(len - 1) == 0x0D;
    if (!needsTranslation) {
      _pendingCarriageReturn = endsWithCr;
      return input;
    }

    final buffer = StringBuffer();
    var lastFlush = 0;
    for (var i = 0; i < len; i++) {
      if (input.codeUnitAt(i) == 0x0A) {
        final precededByCr =
            (i > 0 && input.codeUnitAt(i - 1) == 0x0D) ||
            (i == 0 && _pendingCarriageReturn);
        if (!precededByCr &&
            !_isFollowedByRelativeCursorMovement(input, i + 1)) {
          if (i > lastFlush) {
            buffer.write(input.substring(lastFlush, i));
          }
          buffer.write('\r');
          lastFlush = i;
        }
      }
    }
    if (lastFlush < len) {
      buffer.write(input.substring(lastFlush));
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
    var tailStart = s.length > _kMaxCarryEscapeLength
        ? s.length - _kMaxCarryEscapeLength
        : 0;
    if (tailStart > 0 && tailStart < s.length) {
      final unit = s.codeUnitAt(tailStart);
      if (unit >= 0xDC00 && unit <= 0xDFFF) {
        tailStart -= 1;
      }
    }
    final scanTail = s.substring(tailStart);
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
    _cancelSyncLiveFlush();
    _inSynchronizedOutput = false;
    _closeFrameOnWire();
    _syncBuffer.clear();
    // A suppression window armed by the previous lifecycle's replay must not
    // leak into the new one and swallow its early input. Safe for the
    // full-replay path, which re-arms after calling this.
    _suppressTimer?.cancel();
    _suppressTimer = null;
    _suppressHostInput = false;
    _appliedLiveSeq = null;
    _appliedLogBytes = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _suppressTimer?.cancel();
    _suppressTimer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _frameAbandonTimer?.cancel();
    _frameAbandonTimer = null;
    _cancelSyncLiveFlush();
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

/// Schema counters are uint64: a negative is corrupt, so treat it as
/// unknown (null) rather than letting it poison watermarks.
int? _sanitizeCounter(int? value) => value != null && value < 0 ? null : value;
