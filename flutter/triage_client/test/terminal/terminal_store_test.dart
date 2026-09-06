import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_controller_sink.dart';
import 'package:triage_client/terminal/terminal_intent.dart';
import 'package:triage_client/terminal/terminal_sink.dart';
import 'package:triage_client/terminal/terminal_state.dart';
import 'package:triage_client/terminal/terminal_store.dart';
import 'package:triage_client/widgets/terminal_pane.dart'
    show TerminalController;

/// Records every sink op in order so tests assert on the *single ordered write
/// path* the reducer is supposed to produce.
class FakeTerminalSink implements TerminalSink {
  final List<String> ops = <String>[];
  final StringBuffer written = StringBuffer();

  @override
  set onOutput(void Function(String data)? handler) => _onOutput = handler;
  void Function(String data)? _onOutput;

  @override
  set onResize(void Function(int cols, int rows)? handler) =>
      _onResize = handler;
  void Function(int cols, int rows)? _onResize;

  void emitOutput(String data) => _onOutput?.call(data);
  void emitResize(int c, int r) => _onResize?.call(c, r);

  @override
  void write(String data) {
    ops.add('write:$data');
    written.write(data);
  }

  @override
  void resize(int cols, int rows) => ops.add('resize:$cols,$rows');

  @override
  void clear() => ops.add('clear');

  @override
  void dispose() => ops.add('dispose');

  int historyReplayedCount = 0;

  @override
  void onHistoryReplayed() => historyReplayedCount++;
}

void main() {
  late FakeTerminalSink sink;
  late TerminalStore store;
  late List<String> hostInput;
  late List<String> hostResize;

  setUp(() {
    sink = FakeTerminalSink();
    store = TerminalStore(sink);
    hostInput = <String>[];
    hostResize = <String>[];
    store.onHostInput = hostInput.add;
    store.onHostResize = (c, r) => hostResize.add('$c,$r');
  });

  tearDown(() => store.dispose());

  List<int> b(String s) => utf8.encode(s);

  test('live bytes are buffered until sized, then flushed in order', () {
    store.dispatch(const Attach());
    // No size yet, still awaitingHistory -> live is queued, nothing written.
    store.dispatch(LiveBytes(b('hello')));
    expect(sink.ops, isEmpty, reason: 'nothing written before size/history');

    // History (empty) flips to live + sizes the grid -> queued live flushes.
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    expect(sink.ops, ['resize:80,24', 'clear', 'write:hello']);
  });

  test('history before live: clear + history write, then live appends', () {
    store.dispatch(const Attach());
    store.dispatch(HistoryBytes(b('BANNER'), cols: 100, rows: 30));
    store.dispatch(LiveBytes(b('live')));
    expect(sink.ops, ['resize:100,30', 'clear', 'write:BANNER', 'write:live']);
    expect(store.state.phase, AttachPhase.live);
    expect(store.state.scrollbackReady, isTrue);
  });

  test('outputSeq <= history high-water is dropped as duplicate', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('H'), cols: 80, rows: 24, throughOutputSeq: 5),
    );
    store.dispatch(LiveBytes(b('dup'), outputSeq: 5)); // <= 5 -> drop
    store.dispatch(LiveBytes(b('old'), outputSeq: 3)); // < 5 -> drop
    store.dispatch(LiveBytes(b('new'), outputSeq: 6)); // > 5 -> keep
    expect(sink.ops, ['resize:80,24', 'clear', 'write:H', 'write:new']);
  });

  test('queued live across history drops duplicates by outputSeq', () {
    store.dispatch(const Attach());
    // Live arrives before history (awaitingHistory) -> queued.
    store.dispatch(LiveBytes(b('A'), outputSeq: 4));
    store.dispatch(LiveBytes(b('B'), outputSeq: 7));
    expect(sink.ops, isEmpty);
    store.dispatch(
      HistoryBytes(b('H'), cols: 80, rows: 24, throughOutputSeq: 5),
    );
    // A(4) <=5 dropped, B(7) replayed.
    expect(sink.ops, ['resize:80,24', 'clear', 'write:H', 'write:B']);
  });

  test('resize emits no replay/clear, forwards distinct sizes once', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    hostResize.clear();

    store.dispatch(const Resize(90, 30));
    store.dispatch(const Resize(90, 30)); // same -> no-op
    store.dispatch(const Resize(100, 40));
    expect(sink.ops, ['resize:90,30', 'resize:100,40']);
    expect(sink.ops.where((o) => o == 'clear'), isEmpty);
    expect(hostResize, ['90,30', '100,40']);
  });

  test('sub-minimum resize is ignored', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    store.dispatch(const Resize(1, 0));
    expect(sink.ops, isEmpty);
  });

  test('split UTF-8 across live chunks decodes correctly', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();

    final bytes = utf8.encode('é🦀'); // multi-byte runes
    final mid = bytes.length - 2; // split inside the last rune
    store.dispatch(LiveBytes(bytes.sublist(0, mid)));
    store.dispatch(LiveBytes(bytes.sublist(mid)));
    expect(sink.written.toString(), 'é🦀');
  });

  test('bare LF is translated to CRLF, existing CRLF preserved', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    store.dispatch(LiveBytes(b('a\nb\r\nc')));
    expect(sink.written.toString(), 'a\r\nb\r\nc');
  });

  test('relative cursor movement escape sequences preserve bare LF', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    store.dispatch(LiveBytes(b('Row 1\n\x1b[35DRow 2\n\x1b[13DSpinner')));
    expect(sink.written.toString(), 'Row 1\n\x1b[35DRow 2\n\x1b[13DSpinner');
  });

  test('split chunks pass bytes through without duplicate CR', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    store.dispatch(LiveBytes(b('line\r')));
    store.dispatch(LiveBytes(b('\nnext')));
    expect(sink.written.toString(), 'line\r\nnext');
  });

  test(
    'split relative cursor movement escape sequence across chunks preserves bare LF',
    () {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      sink.ops.clear();
      store.dispatch(LiveBytes(b('Row 1\n\x1b[')));
      store.dispatch(LiveBytes(b('35DRow 2')));
      expect(sink.written.toString(), 'Row 1\n\x1b[35DRow 2');
    },
  );

  test('split non-relative escape sequence across chunks receives CRLF', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    store.dispatch(LiveBytes(b('Done\n\x1b[')));
    store.dispatch(LiveBytes(b('32mSuccess\x1b[0m')));
    expect(sink.written.toString(), 'Done\r\n\x1b[32mSuccess\x1b[0m');
  });

  test('UserInput forwards to host, suppressed after exit', () {
    store.dispatch(const Attach());
    store.dispatch(const UserInput('ls'));
    expect(hostInput, ['ls']);
    store.dispatch(const Exited());
    store.dispatch(const UserInput('more'));
    expect(hostInput, ['ls'], reason: 'no input after exit');
  });

  test('sink output/resize echo route through the reducer', () {
    // No recent history replay here, so the input-suppression window is closed
    // and an emulator keystroke routes straight through (see the suppression
    // tests for the during-replay behavior).
    store.dispatch(const Attach());
    sink.emitOutput('x'); // user keystroke from emulator
    sink.emitResize(70, 20); // emulator fit
    expect(hostInput, ['x']);
    expect(hostResize, ['70,20']);
  });

  test('detached live bytes are ignored', () {
    store.dispatch(LiveBytes(b('ghost')));
    expect(sink.ops, isEmpty);
  });

  test('strips CSI > ... m private sequences (xterm misparses as SGR)', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    // modifyOtherKeys / XTMODKEYS — must not reach the emulator (it parses the
    // private `>` form as SGR 4 -> underline, poisoning the screen).
    store.dispatch(LiveBytes(b('\x1b[>4;2mhello')));
    expect(sink.written.toString(), 'hello');
  });

  test('strips CSI > ... m split across live chunks', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    store.dispatch(LiveBytes(b('a\x1b[>4'))); // sequence split mid-way
    store.dispatch(LiveBytes(b(';2mb')));
    expect(sink.written.toString(), 'ab');
  });

  test(
    'absolute-column cursor jumps pass through history and live verbatim',
    () {
      // The original "ClaudeCode" collapse came from rewriting cursor-addressed
      // gaps. The store must forward `CSI n G` column jumps to the emulator
      // untouched (only the unsupported `CSI > ... m` form is stripped).
      store.dispatch(const Attach());
      const banner = '\x1b[6GClaude\x1b[13GCode';
      store.dispatch(HistoryBytes(b(banner), cols: 80, rows: 24));
      store.dispatch(LiveBytes(b('\x1b[20Gtail')));
      expect(sink.written.toString(), '$banner\x1b[20Gtail');
    },
  );

  test(
    'UTF-8 rune split across the history/live boundary decodes correctly',
    () {
      store.dispatch(const Attach());
      final rune = utf8.encode('é'); // 0xC3 0xA9
      // History tail ends mid-rune (only the lead byte); the carry must persist
      // into the first live chunk rather than emitting a replacement character.
      store.dispatch(
        HistoryBytes([rune[0]], cols: 80, rows: 24, throughOutputSeq: 1),
      );
      store.dispatch(LiveBytes([rune[1]], outputSeq: 2));
      expect(sink.written.toString(), 'é');
    },
  );

  test('CSI > ... m split across the history/live boundary is stripped', () {
    store.dispatch(const Attach());
    // The private sequence begins in history and completes in the first live
    // chunk; it must still be stripped, not leak through as bogus SGR.
    store.dispatch(
      HistoryBytes(b('hi\x1b[>4'), cols: 80, rows: 24, throughOutputSeq: 1),
    );
    store.dispatch(LiveBytes(b(';2mthere'), outputSeq: 2));
    expect(sink.written.toString(), 'hithere');
  });

  test('re-delivered live outputSeq is dropped (re-delivery de-dup)', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    store.dispatch(LiveBytes(b('one'), outputSeq: 10));
    store.dispatch(LiveBytes(b('dup'), outputSeq: 10)); // re-delivery -> drop
    store.dispatch(LiveBytes(b('back'), outputSeq: 9)); // older -> drop
    store.dispatch(LiveBytes(b('two'), outputSeq: 11)); // newer -> keep
    expect(sink.written.toString(), 'onetwo');
  });

  test('emulator output is suppressed during a history replay', () {
    store.dispatch(const Attach());
    store.dispatch(HistoryBytes(b('H'), cols: 80, rows: 24));
    // The replay re-feeds the program's queries; xterm.dart answers them
    // synchronously inside write. Those answers must not reach the host.
    expect(store.isSuppressingHostInput, isTrue);
    store.dispatch(const UserInput('\x1b[1;1R')); // a replayed cursor report
    expect(hostInput, isEmpty);
  });

  test(
    'live emulator query responses are dropped even outside suppression window',
    () {
      fakeAsync((async) {
        final s = TerminalStore(FakeTerminalSink());
        final got = <String>[];
        s.onHostInput = got.add;
        s.dispatch(const Attach());
        s.dispatch(const HistoryBytes([], cols: 80, rows: 24));
        async.elapse(
          kHistoryInputSuppression + const Duration(milliseconds: 1),
        );

        // Outside suppression window: emulator query responses are still dropped
        s.dispatch(const UserInput('\x1b[24;1R')); // CPR
        s.dispatch(const UserInput('\x1b[?1;2c')); // DA
        s.dispatch(const UserInput('\x1b[?0u')); // Kitty query response
        s.dispatch(const UserInput('\x1b[?2026;2\$y')); // DECRPM
        expect(got, isEmpty);

        // Legitimate user keystrokes are preserved
        s.dispatch(const UserInput('a'));
        s.dispatch(const UserInput('\x1b[A')); // Up arrow
        expect(got, ['a', '\x1b[A']);
        s.dispose();
      });
    },
  );

  test('host-input suppression lifts after the window', () {
    fakeAsync((async) {
      final s = TerminalStore(FakeTerminalSink());
      final got = <String>[];
      s.onHostInput = got.add;
      s.dispatch(const Attach());
      s.dispatch(HistoryBytes(b('H'), cols: 80, rows: 24));
      s.dispatch(const UserInput('blocked'));
      async.elapse(kHistoryInputSuppression + const Duration(milliseconds: 1));
      s.dispatch(const UserInput('allowed'));
      expect(got, ['allowed']);
      s.dispose();
    });
  });

  test('re-Attach drops live buffered against the prior attach', () {
    store.dispatch(const Attach());
    store.dispatch(LiveBytes(b('stale'))); // queued in awaitingHistory
    store.dispatch(const Attach()); // fresh lifecycle -> discard the queue
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    expect(sink.written.toString(), isEmpty, reason: 'no cross-attach leakage');
  });

  test('Clear drops queued pre-size live so it cannot re-populate', () {
    store.dispatch(const Attach());
    store.dispatch(LiveBytes(b('stale')));
    store.dispatch(const Clear());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    expect(sink.written.toString(), isEmpty);
  });

  test('pre-size live buffer is bounded; oldest chunks drop past the cap', () {
    store.dispatch(const Attach()); // awaitingHistory -> live chunks queue
    final chunk = List<int>.filled(256 * 1024, 0x61); // 256 KiB of 'a'
    // Queue well past the 1 MiB cap without ever sizing/flushing.
    for (var i = 0; i < 8; i++) {
      store.dispatch(LiveBytes(chunk, outputSeq: i + 1));
    }
    // Flush by going live; the most-recent chunks survive, oldest were dropped.
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    expect(sink.written.length, lessThanOrEqualTo(kPendingLiveByteCap));
    expect(sink.written.length, greaterThan(0));
  });

  test(
    'Synchronized Output Mode 2026 batches writes into a single atomic sink.write',
    () {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      sink.ops.clear();

      // Chunk 1 opens mode 2026 and draws partial frame.
      store.dispatch(
        LiveBytes(b('\x1b[?2026h\r\x1b[3A● \n Runn'), outputSeq: 1),
      );
      // While synchronized, no write operations reach the sink yet.
      expect(sink.ops.where((op) => op.startsWith('write:')), isEmpty);

      // Chunk 2 continues the frame.
      store.dispatch(LiveBytes(b('\n\n\x1b[5D'), outputSeq: 2));
      expect(sink.ops.where((op) => op.startsWith('write:')), isEmpty);

      // Chunk 3 closes mode 2026.
      store.dispatch(LiveBytes(b('\x1b[?2026l'), outputSeq: 3));

      // Entire frame is delivered in one single atomic write call.
      final writes = sink.ops.where((op) => op.startsWith('write:')).toList();
      expect(writes.length, 1);
      expect(
        writes.first,
        'write:\x1b[?2026h\r\x1b[3A● \n Runn\n\n\x1b[5D\x1b[?2026l',
      );
    },
  );

  test(
    'Mode 2026 start and end escape markers split across chunks are carried and matched',
    () {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      sink.ops.clear();

      // Chunk 1 ends mid-escape for \x1b[?2026h
      store.dispatch(LiveBytes(b('prefix\x1b[?20'), outputSeq: 1));
      // Prefix before the escape marker was written directly.
      expect(sink.written.toString(), 'prefix');
      expect(sink.ops, ['write:prefix']);
      sink.ops.clear();

      // Chunk 2 completes \x1b[?2026h and writes body
      store.dispatch(LiveBytes(b('26hbody text'), outputSeq: 2));
      // Synchronized mode entered; body is buffered.
      expect(sink.ops.where((op) => op.startsWith('write:')), isEmpty);

      // Chunk 3 ends mid-escape for \x1b[?2026l
      store.dispatch(LiveBytes(b(' more\x1b[?'), outputSeq: 3));
      expect(sink.ops.where((op) => op.startsWith('write:')), isEmpty);

      // Chunk 4 completes \x1b[?2026l and adds trailing text
      store.dispatch(LiveBytes(b('2026lsuffix'), outputSeq: 4));

      final writes = sink.ops.where((op) => op.startsWith('write:')).toList();
      expect(writes.length, 2);
      expect(writes[0], 'write:\x1b[?2026hbody text more\x1b[?2026l');
      expect(writes[1], 'write:suffix');
    },
  );

  test(
    'Synchronized Output watchdog timer behaves as an idle timeout on active streams',
    () {
      fakeAsync((async) {
        store.dispatch(const Attach());
        store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
        sink.ops.clear();

        // Stream begins sync mode.
        store.dispatch(
          LiveBytes(b('\x1b[?2026h\r\x1b[3A○ Frame 1'), outputSeq: 1),
        );
        expect(sink.ops.where((op) => op.startsWith('write:')), isEmpty);

        // Advance 30ms (<50ms). Next chunk arrives, resetting the idle timer.
        async.elapse(const Duration(milliseconds: 30));
        store.dispatch(LiveBytes(b('\n\x1b[2K○ Frame 2'), outputSeq: 2));
        expect(sink.ops.where((op) => op.startsWith('write:')), isEmpty);

        // Advance another 30ms (total 60ms since start, but only 30ms idle).
        async.elapse(const Duration(milliseconds: 30));
        expect(
          sink.ops.where((op) => op.startsWith('write:')),
          isEmpty,
          reason:
              'idle timer did not prematurely flush active multi-chunk frame',
        );

        // Advance 55ms with no further incoming chunks -> idle timeout fires.
        async.elapse(const Duration(milliseconds: 55));
        final writes = sink.ops.where((op) => op.startsWith('write:')).toList();
        expect(writes.length, 1);
        expect(
          writes.first,
          'write:\x1b[?2026h\r\x1b[3A○ Frame 1\n\x1b[2K○ Frame 2',
        );
      });
    },
  );

  test(
    'Synchronized Output buffer capacity cap forces a flush when exceeded',
    () {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      sink.ops.clear();

      store.dispatch(LiveBytes(b('\x1b[?2026h'), outputSeq: 1));
      // Send 1.5 MiB of data in sync mode without sending \x1b[?2026l.
      final largeChunk = List<int>.filled(512 * 1024, 0x61);
      store.dispatch(LiveBytes(largeChunk, outputSeq: 2));
      store.dispatch(LiveBytes(largeChunk, outputSeq: 3));
      store.dispatch(LiveBytes(largeChunk, outputSeq: 4));

      // Buffer cap (1 MiB) triggered a safety flush.
      expect(sink.written.length, greaterThanOrEqualTo(1024 * 1024));
    },
  );

  test('trailing incomplete escape carry is flushed on idle timeout', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      sink.ops.clear();

      // Dispatch a chunk ending with a partial escape sequence.
      store.dispatch(LiveBytes(b('prompt: \x1b[?20'), outputSeq: 1));
      expect(sink.written.toString(), 'prompt: ');
      sink.ops.clear();

      // Idle timeout elapses without subsequent chunks.
      async.elapse(
        kSyncOutputWatchdogTimeout + const Duration(milliseconds: 10),
      );
      expect(sink.ops, ['write:\x1b[?20']);
    });
  });

  test(
    'interleaved start markers within a synchronized frame do not duplicate batch opens',
    () {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      sink.ops.clear();

      // Chunk with nested/repeated \x1b[?2026h before closing with \x1b[?2026l
      store.dispatch(
        LiveBytes(
          b('\x1b[?2026hfirst \x1b[?2026hsecond\x1b[?2026l'),
          outputSeq: 1,
        ),
      );

      final writes = sink.ops.where((op) => op.startsWith('write:')).toList();
      expect(writes.length, 1);
      expect(
        writes.first,
        'write:\x1b[?2026hfirst \x1b[?2026hsecond\x1b[?2026l',
      );
    },
  );

  test(
    're-Attach or Clear mid-synchronization cleans up sync buffer and cancels watchdog',
    () {
      fakeAsync((async) {
        store.dispatch(const Attach());
        store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
        sink.ops.clear();

        // Begin sync section
        store.dispatch(LiveBytes(b('\x1b[?2026hpartial frame'), outputSeq: 1));
        expect(sink.ops.where((op) => op.startsWith('write:')), isEmpty);

        // Re-attach drops live buffering and cancels watchdog
        store.dispatch(const Attach());
        async.elapse(const Duration(milliseconds: 100));

        // No delayed write fired after detach/re-attach
        expect(sink.ops.where((op) => op.startsWith('write:')), isEmpty);
      });
    },
  );

  test(
    'delta merge: subsequent snapshot overlapping applied bytes appends delta without clearing sink',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Initial history replay
      final initialText = 'hello world\r\n';
      store.dispatch(
        HistoryBytes(
          b(initialText),
          cols: 80,
          rows: 24,
          throughOutputSeq: 10,
          rawOutputStart: 0,
        ),
      );

      expect(sink.ops, contains('clear'));
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(sink.ops, contains('write:$initialText'));

      // Subsequent snapshot carrying both initial text and new lines
      final addedText = 'second line\r\n';
      final fullText = '$initialText$addedText';
      store.dispatch(
        HistoryBytes(
          b(fullText),
          cols: 80,
          rows: 24,
          throughOutputSeq: 15,
          rawOutputStart: 0,
        ),
      );

      // Sink must NOT have been cleared a second time
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      // Only the new delta bytes should have been written
      expect(sink.ops.last, 'write:$addedText');
      expect(store.appliedLogBytes, fullText.length);
      expect(store.state.historyHighWaterSeq, 15);
    },
  );

  test('delta merge: subsequent snapshot already fully covered is a no-op', () {
    final sink = FakeTerminalSink();
    final store = TerminalStore(sink);
    store.dispatch(const Resize(80, 24));

    final text = 'already current content\r\n';
    store.dispatch(
      HistoryBytes(
        b(text),
        cols: 80,
        rows: 24,
        throughOutputSeq: 10,
        rawOutputStart: 0,
      ),
    );

    final opCount = sink.ops.length;

    // Re-send snapshot with same seq and content
    store.dispatch(
      HistoryBytes(
        b(text),
        cols: 80,
        rows: 24,
        throughOutputSeq: 10,
        rawOutputStart: 0,
      ),
    );

    // No new clear or write operations performed
    expect(sink.ops.length, opCount);
  });

  test(
    'delta merge fallback: gap in output log triggers full clear and replay',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Initial history with 10 bytes at offset 0
      store.dispatch(
        HistoryBytes(
          b('old prefix'),
          cols: 80,
          rows: 24,
          throughOutputSeq: 5,
          rawOutputStart: 0,
        ),
      );
      expect(sink.ops.where((op) => op == 'clear').length, 1);

      // Snapshot arrives starting at byte offset 5000 (a gap exceeding client applied bytes)
      final newTail = 'rolled over tail\r\n';
      store.dispatch(
        HistoryBytes(
          b(newTail),
          cols: 80,
          rows: 24,
          throughOutputSeq: 50,
          rawOutputStart: 5000,
        ),
      );

      // Sink must be cleared again and full new tail written
      expect(sink.ops.where((op) => op == 'clear').length, 2);
      expect(sink.ops.last, 'write:$newTail');
      expect(store.appliedLogBytes, 5000 + newTail.length);
      expect(store.state.historyHighWaterSeq, 50);
    },
  );

  test('exited session restore clears exited state and does full replay', () {
    final sink = FakeTerminalSink();
    final store = TerminalStore(sink);
    store.dispatch(const Resize(80, 24));

    store.dispatch(
      HistoryBytes(
        b('shell prompt \$ '),
        cols: 80,
        rows: 24,
        throughOutputSeq: 20,
        rawOutputStart: 0,
      ),
    );
    expect(store.state.phase, AttachPhase.live);
    expect(store.state.exited, isFalse);

    // Session exits
    store.dispatch(const Exited());
    expect(store.state.exited, isTrue);

    // When restored, daemon re-spawns at seq 0 or sends fresh history.
    // If HistoryBytes arrives on an exited store, it must bypass delta-merge,
    // clear the sink, write the fresh history, and reset exited to false.
    final freshPrompt = 'restarted shell \$ ';
    store.dispatch(
      HistoryBytes(
        b(freshPrompt),
        cols: 80,
        rows: 24,
        throughOutputSeq: 0,
        rawOutputStart: 0,
      ),
    );

    expect(store.state.exited, isFalse);
    expect(store.state.phase, AttachPhase.live);
    expect(sink.ops.where((op) => op == 'clear').length, 2);
    expect(sink.ops.last, 'write:$freshPrompt');
    expect(store.appliedLogBytes, freshPrompt.length);
  });

  test('delta merge: flushes queued pending live chunks when sized', () {
    final sink = FakeTerminalSink();
    final store = TerminalStore(sink);
    store.dispatch(const Attach());

    // Live arrives before sizing
    store.dispatch(LiveBytes(b('live queued'), outputSeq: 6));

    // History arrives, providing sizing (80, 24) and delta-mergeable output
    store.dispatch(
      HistoryBytes(
        b('hello '),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );

    expect(sink.ops, contains('write:live queued'));
  });

  test(
    'sequence regression when rawOutputStart is null triggers full clear and replay',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      store.dispatch(
        HistoryBytes(
          b('old shell prompt'),
          cols: 80,
          rows: 24,
          throughOutputSeq: 50,
        ),
      );
      expect(sink.ops.where((op) => op == 'clear').length, 1);

      // New snapshot arrives with regressed sequence (e.g. 0 < 50) and no rawOutputStart
      final fresh = 'restarted shell';
      store.dispatch(
        HistoryBytes(b(fresh), cols: 80, rows: 24, throughOutputSeq: 0),
      );

      // Must trigger a full clear and replay
      expect(sink.ops.where((op) => op == 'clear').length, 2);
      expect(sink.ops.last, 'write:$fresh');
    },
  );

  test(
    'sequence reset when rawOutputStart is null and appliedLiveSeq is ahead triggers full clear and replay',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Initial history arrives at seq 0
      store.dispatch(
        HistoryBytes(
          b('initial prompt'),
          cols: 80,
          rows: 24,
          throughOutputSeq: 0,
        ),
      );
      expect(sink.ops.where((op) => op == 'clear').length, 1);

      // Live output advances appliedLiveSeq to 10
      store.dispatch(LiveBytes(b(' live text'), outputSeq: 10));
      expect(store.appliedLiveSeq, 10);

      // Daemon restarts and emits fresh history at seq 0 with null rawOutputStart
      final fresh = 'restarted shell prompt';
      store.dispatch(
        HistoryBytes(b(fresh), cols: 80, rows: 24, throughOutputSeq: 0),
      );

      // Must trigger full clear and replay rather than dropping the restart
      expect(sink.ops.where((op) => op == 'clear').length, 2);
      expect(sink.ops.last, 'write:$fresh');
    },
  );

  test(
    'sequence regression when rawOutputStart is 0 triggers full clear and replay',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Initial history arrives at seq 50 with rawOutputStart 0 and 500 bytes
      final initialOutput = 'x' * 500;
      store.dispatch(
        HistoryBytes(
          b(initialOutput),
          cols: 80,
          rows: 24,
          throughOutputSeq: 50,
          rawOutputStart: 0,
        ),
      );
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(store.appliedLogBytes, 500);

      // Daemon or shell resets and emits fresh snapshot at seq 0, rawOutputStart 0, and 100 bytes
      final fresh = 'restarted shell after daemon reload';
      store.dispatch(
        HistoryBytes(
          b(fresh),
          cols: 80,
          rows: 24,
          throughOutputSeq: 0,
          rawOutputStart: 0,
        ),
      );

      // Must trigger full clear and replay instead of misinterpreting currentLogBytes as having covered the snapshot
      expect(sink.ops.where((op) => op == 'clear').length, 2);
      expect(sink.ops.last, 'write:$fresh');
      expect(store.appliedLogBytes, fresh.length);
    },
  );

  test(
    'log length regression when bytes shrink triggers full clear and replay',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Initial history arrives with 500 bytes
      final initialOutput = 'y' * 500;
      store.dispatch(
        HistoryBytes(b(initialOutput), cols: 80, rows: 24, rawOutputStart: 0),
      );
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(store.appliedLogBytes, 500);

      // Shrunk log arrives with rawOutputStart 0 and 100 bytes
      final truncated = 'short log after reset';
      store.dispatch(
        HistoryBytes(b(truncated), cols: 80, rows: 24, rawOutputStart: 0),
      );

      expect(sink.ops.where((op) => op == 'clear').length, 2);
      expect(sink.ops.last, 'write:$truncated');
      expect(store.appliedLogBytes, truncated.length);
    },
  );

  test(
    'viewport resize with concurrent delta-merge updates sizing and drains pending live',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Seed initial output
      store.dispatch(
        HistoryBytes(
          b('prompt> '),
          cols: 80,
          rows: 24,
          throughOutputSeq: 1,
          rawOutputStart: 0,
        ),
      );
      expect(sink.ops, ['resize:80,24', 'clear', 'write:prompt> ']);

      // Live output arrives before viewport resize
      store.dispatch(LiveBytes(b('ls -l'), outputSeq: 2));

      // Delta-merge snapshot arrives with resized viewport dimensions (120x40)
      store.dispatch(
        HistoryBytes(
          b('prompt> ls -l\nfile1.txt\n'),
          cols: 120,
          rows: 40,
          throughOutputSeq: 3,
          rawOutputStart: 0,
        ),
      );

      // Delta merge updates store dimensions without clearing sink
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(store.state.cols, 120);
      expect(store.state.rows, 40);
      expect(sink.ops.last, 'write:\r\nfile1.txt\r\n');
    },
  );

  test(
    'HistoryBytes dispatches onHistoryReplayed to sink after write completes',
    () {
      expect(sink.historyReplayedCount, 0);

      store.dispatch(
        HistoryBytes(
          b('initial prompt> '),
          cols: 80,
          rows: 24,
          throughOutputSeq: 1,
          rawOutputStart: 0,
        ),
      );

      expect(sink.historyReplayedCount, 1);
    },
  );

  test('HistoryBytes dispatches onHistoryReplayed even when unsized', () {
    final freshStore = TerminalStore(sink);
    expect(sink.historyReplayedCount, 0);

    freshStore.dispatch(
      HistoryBytes(
        b('unsized prompt> '),
        cols: 80,
        rows: 24,
        throughOutputSeq: 1,
        rawOutputStart: 0,
      ),
    );

    expect(sink.historyReplayedCount, 1);
  });

  test(
    'TerminalControllerSink notifies TerminalController history replayed listeners',
    () {
      final controller = TerminalController();
      final controllerSink = TerminalControllerSink(controller);
      var replayedCount = 0;

      void listener() {
        replayedCount++;
      }

      controller.addHistoryReplayedListener(listener);

      controllerSink.onHistoryReplayed();
      expect(replayedCount, 1);

      controller.removeHistoryReplayedListener(listener);
      controllerSink.onHistoryReplayed();
      expect(replayedCount, 1);

      controller.dispose();
    },
  );
}
