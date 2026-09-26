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

/// Records the history-replay signal in the same ordered op list as writes, so
/// a test can assert the signal lands after every decoded byte.
class ReplayOrderSink extends FakeTerminalSink {
  @override
  void onHistoryReplayed() {
    ops.add('historyReplayed');
    super.onHistoryReplayed();
  }
}

/// A sink that runs a one-shot callback from inside [write], so a test can
/// tear the store down part-way through a flush the way a listener reacting to
/// freshly painted output can.
class ReentrantSink extends FakeTerminalSink {
  void Function()? onWrite;

  @override
  void write(String data) {
    super.write(data);
    final callback = onWrite;
    onWrite = null;
    callback?.call();
  }
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

  test('history replay ending mid-escape releases the trailing partial', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      // The history tail is cut at an arbitrary byte offset, so it routinely
      // ends mid-sequence. The hold itself is correct: the next live chunk
      // may complete a strippable CSI > join, but with no live following,
      // the watchdog must still release it. (The replay's own sync-block
      // close used to cancel that watchdog, stranding the tail.)
      const tail = 'ok\x1b[38;2;118;123;131;4';
      store.dispatch(HistoryBytes(b(tail), cols: 80, rows: 24));
      expect(sink.written.toString(), 'ok');
      async.elapse(kSyncOutputWatchdogTimeout * 2);
      expect(sink.written.toString(), tail);
    });
  });

  test('exit with a held escape carry still releases the trailing partial', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      // A live chunk ending mid-escape holds its tail for the next chunk.
      const tail = 'ok\x1b[38;2;118;123;131;4';
      store.dispatch(LiveBytes(b(tail)));
      expect(sink.written.toString(), 'ok');
      // The process exits with no live following: the exit flush must not
      // cancel the watchdog guarding the carry.
      store.dispatch(const Exited());
      async.elapse(kSyncOutputWatchdogTimeout * 2);
      expect(sink.written.toString(), tail);
    });
  });

  test('end marker in the arming chunk does not strand the escape tail', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      // The strip pass holds the trailing partial and arms the watchdog;
      // the sync pass then hits the end marker in the same chunk and closes.
      // The close must re-arm rather than strand the tail.
      const frame = '\x1b[?2026hFRAME\x1b[?2026l';
      const tail = 'ok\x1b[38;2;118;123;131;4';
      store.dispatch(LiveBytes(b('$frame$tail')));
      expect(sink.written.toString(), '${frame}ok');
      async.elapse(kSyncOutputWatchdogTimeout * 2);
      expect(sink.written.toString(), '$frame$tail');
    });
  });

  test('capacity cap close with a held escape carry still releases the tail', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      // A frame past the 1 MiB cap force-flushes through the shared close
      // while the strip pass still holds the chunk's trailing partial: the
      // close must re-arm rather than strand it.
      const tail = 'ok\x1b[38;2;118;123;131;4';
      final frame = '\x1b[?2026h${'F' * (1024 * 1024)}$tail';
      store.dispatch(LiveBytes(b(frame)));
      expect(sink.written.length, greaterThan(1024 * 1024));
      expect(sink.written.toString().endsWith('ok'), isTrue);
      async.elapse(kSyncOutputWatchdogTimeout * 2);
      expect(sink.written.toString().endsWith(tail), isTrue);
    });
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
    'open synchronized block flushes progressively during sustained streams',
    () {
      fakeAsync((async) {
        store.dispatch(const Attach());
        store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
        sink.ops.clear();

        // Open a block; nothing reaches the sink yet.
        store.dispatch(LiveBytes(b('\x1b[?2026hchunk-one '), outputSeq: 1));
        expect(sink.ops.where((op) => op.startsWith('write:')), isEmpty);

        // Chunks keep arriving faster than the idle watchdog, so the watchdog
        // alone would never flush and the screen would freeze for the whole
        // stream. The live-flush interval still paints periodically.
        async.elapse(const Duration(milliseconds: 30));
        store.dispatch(LiveBytes(b('chunk-two '), outputSeq: 2));
        async.elapse(const Duration(milliseconds: 30));
        store.dispatch(LiveBytes(b('chunk-three '), outputSeq: 3));
        async.elapse(const Duration(milliseconds: 30));
        store.dispatch(LiveBytes(b('chunk-four '), outputSeq: 4));
        async.elapse(const Duration(milliseconds: 10)); // t=100: interval fires
        var writes = sink.ops.where((op) => op.startsWith('write:')).toList();
        expect(writes.length, 1);
        expect(
          writes.first,
          'write:\x1b[?2026hchunk-one chunk-two chunk-three chunk-four ',
          reason: 'live flush paints the open block without closing it',
        );

        // The block is still open: the remainder closes atomically at its end
        // marker, with no bytes lost or duplicated across the writes.
        sink.ops.clear();
        store.dispatch(LiveBytes(b('tail\x1b[?2026lafter'), outputSeq: 5));
        writes = sink.ops.where((op) => op.startsWith('write:')).toList();
        expect(writes, ['write:tail\x1b[?2026l', 'write:after']);

        // The interval stops once the block closes.
        async.elapse(kSyncOutputLiveFlushInterval * 3);
        expect(
          sink.ops.where((op) => op.startsWith('write:')).length,
          2,
          reason: 'no further writes after the block closed',
        );
      });
    },
  );

  test('a watchdog close after a live flush still writes the tail raw', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      sink.ops.clear();

      // Sustained chunks keep the 50ms watchdog re-armed so the 100ms live
      // flush is what fires, consuming the block's opening marker.
      store.dispatch(LiveBytes(b('\x1b[?2026hone '), outputSeq: 1));
      async.elapse(const Duration(milliseconds: 30));
      store.dispatch(LiveBytes(b('two '), outputSeq: 2));
      async.elapse(const Duration(milliseconds: 30));
      store.dispatch(LiveBytes(b('three '), outputSeq: 3));
      async.elapse(const Duration(milliseconds: 30));
      store.dispatch(LiveBytes(b('four '), outputSeq: 4));
      async.elapse(const Duration(milliseconds: 10));
      expect(sink.ops, ['write:\x1b[?2026hone two three four ']);

      // Still inside the block, then idle: the watchdog closes a tail that no
      // longer carries a marker. Its bare LF must survive untouched, because
      // the application owns cursor placement inside a synchronized frame.
      sink.ops.clear();
      store.dispatch(LiveBytes(b('bbb\nccc'), outputSeq: 5));
      async.elapse(kSyncOutputWatchdogTimeout * 2);
      expect(
        sink.ops,
        ['write:bbb\nccc'],
        reason: 'no \\r may be injected into a synchronized-output frame',
      );
    });
  });

  test('chunks after a premature close stay raw until the real end marker', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      sink.ops.clear();

      // Open a frame, then stall longer than the watchdog. The watchdog stops
      // holding the block, but the application has not closed the frame.
      store.dispatch(LiveBytes(b('\x1b[?2026hone '), outputSeq: 1));
      async.elapse(kSyncOutputWatchdogTimeout * 2);
      expect(sink.ops, ['write:\x1b[?2026hone ']);

      // A stall mid-generation is routine, and these bytes are still frame
      // content: the application owns cursor placement until it says otherwise.
      sink.ops.clear();
      store.dispatch(LiveBytes(b('bbb\nccc'), outputSeq: 2));
      expect(
        sink.ops,
        ['write:bbb\nccc'],
        reason: 'no \\r may be injected while the frame is open on the wire',
      );

      // Once the frame really closes, ordinary newline translation resumes.
      sink.ops.clear();
      store.dispatch(LiveBytes(b('\x1b[?2026l'), outputSeq: 3));
      sink.ops.clear();
      store.dispatch(LiveBytes(b('ddd\neee'), outputSeq: 4));
      expect(sink.ops, ['write:ddd\r\neee']);
    });
  });

  test('history replay ending mid-frame flushes before it signals', () {
    // #162 documents onHistoryReplayed as "all decoded snapshot bytes
    // written", and its web bottom-restore depends on that. A replay whose
    // tail ends inside a Mode 2026 block would otherwise still be held.
    final orderSink = ReplayOrderSink();
    final replayStore = TerminalStore(orderSink);
    replayStore.dispatch(const Attach());
    replayStore.dispatch(
      HistoryBytes(b('\x1b[?2026hheld tail'), cols: 80, rows: 24),
    );

    final writeIndex = orderSink.ops.indexWhere(
      (op) => op.startsWith('write:'),
    );
    final signalIndex = orderSink.ops.indexOf('historyReplayed');
    expect(writeIndex, isNonNegative, reason: 'the held tail must be flushed');
    expect(signalIndex, isNonNegative);
    expect(
      writeIndex,
      lessThan(signalIndex),
      reason: 'every decoded byte must reach the sink before the signal',
    );
    replayStore.dispose();
  });

  test('a close and a reopen in one chunk keeps the middle translated', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      store.dispatch(LiveBytes(b('\x1b[?2026hopen'), outputSeq: 1));
      // Let the watchdog stop holding the block while the frame is still open
      // on the wire, so the next chunk is dispatched with the exemption active.
      async.elapse(kSyncOutputWatchdogTimeout * 2);
      sink.ops.clear();

      // Close, ordinary output, reopen, all in one chunk. _writeVerbatim only
      // compares the last marker of each kind, which is sound only because the
      // text reaching it never spans a close and a reopen.
      store.dispatch(
        LiveBytes(b('\x1b[?2026laaa\nbbb\x1b[?2026hccc'), outputSeq: 2),
      );
      expect(sink.ops, [
        'write:\x1b[?2026l',
        'write:aaa\r\nbbb',
      ], reason: 'output between the two frames is not frame content');
    });
  });

  test('an abandoned frame stops suppressing newline translation', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      sink.ops.clear();

      // A frame opens and the application then dies without ever closing it.
      store.dispatch(LiveBytes(b('\x1b[?2026hpartial'), outputSeq: 1));
      async.elapse(kSyncOutputWatchdogTimeout * 2);
      sink.ops.clear();

      // Still inside the abandon window, so this is treated as frame content.
      store.dispatch(LiveBytes(b('aaa\nbbb'), outputSeq: 2));
      expect(sink.ops, ['write:aaa\nbbb']);

      // Past it, the frame is presumed gone and ordinary shell output must not
      // staircase for the rest of the session.
      sink.ops.clear();
      async.elapse(kSyncFrameAbandonTimeout * 2);
      store.dispatch(LiveBytes(b('ccc\nddd'), outputSeq: 3));
      expect(sink.ops, ['write:ccc\r\nddd']);
    });
  });

  test('a session exit closes an unfinished frame', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      store.dispatch(LiveBytes(b('\x1b[?2026hpartial'), outputSeq: 1));
      async.elapse(kSyncOutputWatchdogTimeout * 2);

      store.dispatch(const Exited());
      sink.ops.clear();
      store.dispatch(LiveBytes(b('ccc\nddd'), outputSeq: 2));
      expect(sink.ops, ['write:ccc\r\nddd']);
    });
  });

  test('a session exit while the block is still held closes the frame', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      // No elapse: the block is still buffered, so retiring the frame without
      // flushing would let the watchdog re-derive it from the buffered start
      // marker and re-arm the abandon timer.
      store.dispatch(LiveBytes(b('\x1b[?2026hpartial'), outputSeq: 1));
      store.dispatch(const Exited());
      async.elapse(kSyncOutputWatchdogTimeout * 2);

      sink.ops.clear();
      store.dispatch(LiveBytes(b('ccc\nddd'), outputSeq: 2));
      expect(sink.ops, [
        'write:ccc\r\nddd',
      ], reason: 'the abandoned frame must not survive the flush');
    });
  });

  test('output after a closing marker is translated, not carried verbatim', () {
    fakeAsync((async) {
      store.dispatch(const Attach());
      store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      store.dispatch(LiveBytes(b('\x1b[?2026hone '), outputSeq: 1));
      // The watchdog stops holding the block while the frame is still open on
      // the wire, so the closing marker arrives outside a held block.
      async.elapse(kSyncOutputWatchdogTimeout * 2);

      sink.ops.clear();
      store.dispatch(LiveBytes(b('\x1b[?2026lccc\nddd'), outputSeq: 2));
      expect(
        sink.ops,
        ['write:\x1b[?2026l', 'write:ccc\r\nddd'],
        reason:
            'only the frame is exempt; the tail after it is ordinary output',
      );
    });
  });

  test('disposing from inside a live flush leaves no timer armed', () {
    fakeAsync((async) {
      // A store of its own: this one is disposed inside the test, while the
      // shared `store` stays for tearDown to dispose.
      final reentrantSink = ReentrantSink();
      final victim = TerminalStore(reentrantSink);
      victim.dispatch(const Attach());
      victim.dispatch(const HistoryBytes([], cols: 80, rows: 24));
      reentrantSink.ops.clear();

      // Chunks must keep arriving inside the 50ms watchdog, or the watchdog
      // closes the block first and the live flush under test never runs.
      victim.dispatch(LiveBytes(b('\x1b[?2026hone '), outputSeq: 1));
      reentrantSink.onWrite = victim.dispose;
      async.elapse(const Duration(milliseconds: 30));
      victim.dispatch(LiveBytes(b('two '), outputSeq: 2));
      async.elapse(const Duration(milliseconds: 30));
      victim.dispatch(LiveBytes(b('three '), outputSeq: 3));
      async.elapse(const Duration(milliseconds: 30));
      victim.dispatch(LiveBytes(b('four '), outputSeq: 4));
      async.elapse(const Duration(milliseconds: 10)); // t=100: flush fires

      expect(
        reentrantSink.ops.where((op) => op.startsWith('write:')).length,
        1,
        reason: 'the live flush painted once before the store was disposed',
      );
      // The tick resumes after the dispose its own write triggered. Re-arming
      // there would leave a timer firing against a disposed sink every
      // interval, forever.
      expect(
        async.nonPeriodicTimerCount,
        0,
        reason:
            'dispose must leave no live flush armed: '
            '${async.pendingTimersDebugString}',
      );
    });
  });

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
    expect(sink.historyReplayedCount, 1);
  });

  test(
    'delta merge: snapshot behind live stream is a no-op when bytes are already covered',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Initial history replay at seq 5 with 50 bytes
      final initialText = 'a' * 50;
      store.dispatch(
        HistoryBytes(
          b(initialText),
          cols: 80,
          rows: 24,
          throughOutputSeq: 5,
          rawOutputStart: 0,
        ),
      );
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(store.appliedLogBytes, 50);

      // Live streaming advances outputSeq to 8 and appliedLogBytes to 80
      final liveText = 'b' * 30;
      store.dispatch(LiveBytes(b(liveText), outputSeq: 8));
      expect(store.appliedLiveSeq, 8);
      expect(store.appliedLogBytes, 80);
      final opCountBeforeSnapshot = sink.ops.length;

      // An attach/resync snapshot arrives from daemon captured at seq 5 with 50 bytes.
      // throughOutputSeq (5) <= appliedLiveSeq (8), and snapshotEndBytes (50) <= currentLogBytes (80).
      // Must NOT trigger clear or replay.
      store.dispatch(
        HistoryBytes(
          b(initialText),
          cols: 80,
          rows: 24,
          throughOutputSeq: 5,
          rawOutputStart: 0,
        ),
      );

      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(sink.ops.length, opCountBeforeSnapshot);
      expect(store.appliedLogBytes, 80);
      expect(store.appliedLiveSeq, 8);
      expect(sink.historyReplayedCount, 1);
    },
  );

  test(
    'delta merge: snapshot overlapping live stream appends only delta bytes without clearing',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Initial history replay at seq 5 with 50 bytes
      final initialText = 'a' * 50;
      store.dispatch(
        HistoryBytes(
          b(initialText),
          cols: 80,
          rows: 24,
          throughOutputSeq: 5,
          rawOutputStart: 0,
        ),
      );
      expect(store.appliedLogBytes, 50);

      // Live stream advances appliedLogBytes to 70 at seq 7
      final liveText = 'b' * 20;
      store.dispatch(LiveBytes(b(liveText), outputSeq: 7));
      expect(store.appliedLogBytes, 70);

      // Snapshot arrives covering 0..100 at seq 10.
      // Client is at byte 70, so delta is 70..100 (30 bytes).
      final deltaText = 'c' * 30;
      final fullSnapshotText = '$initialText$liveText$deltaText';
      store.dispatch(
        HistoryBytes(
          b(fullSnapshotText),
          cols: 80,
          rows: 24,
          throughOutputSeq: 10,
          rawOutputStart: 0,
        ),
      );

      // Must NOT have cleared the sink
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      // Must only write the delta portion
      expect(sink.ops.last, 'write:$deltaText');
      expect(store.appliedLogBytes, 100);
      expect(store.state.historyHighWaterSeq, 10);
      expect(sink.historyReplayedCount, 1);
    },
  );

  test(
    'delta merge: sequence fallback without rawOutputStart resolves high water and preserves buffer',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Initial history replay without rawOutputStart at seq 5
      store.dispatch(
        HistoryBytes(
          b('initial output'),
          cols: 80,
          rows: 24,
          throughOutputSeq: 5,
        ),
      );
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(store.state.historyHighWaterSeq, 5);

      // Live streaming advances to seq 8
      store.dispatch(LiveBytes(b(' live'), outputSeq: 8));
      expect(store.appliedLiveSeq, 8);
      final opCount = sink.ops.length;

      // Resync snapshot without rawOutputStart arrives at seq 6 (behind live stream 8)
      store.dispatch(
        HistoryBytes(
          b('initial output'),
          cols: 80,
          rows: 24,
          throughOutputSeq: 6,
        ),
      );

      // Must NOT clear or replay
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(sink.ops.length, opCount);
      expect(store.state.historyHighWaterSeq, 6);
      expect(store.appliedLiveSeq, 8);
      expect(store.state.phase, AttachPhase.live);
      expect(sink.historyReplayedCount, 1);
    },
  );

  test(
    'delta merge: unchanged snapshot sequence without rawOutputStart preserves buffer',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Initial history replay without rawOutputStart at seq 5
      store.dispatch(
        HistoryBytes(
          b('initial output'),
          cols: 80,
          rows: 24,
          throughOutputSeq: 5,
        ),
      );
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(store.state.historyHighWaterSeq, 5);

      // Live streaming advances to seq 8
      store.dispatch(LiveBytes(b(' live'), outputSeq: 8));
      expect(store.appliedLiveSeq, 8);
      final opCount = sink.ops.length;

      // Resync snapshot without rawOutputStart arrives at unchanged seq 5
      store.dispatch(
        HistoryBytes(
          b('initial output'),
          cols: 80,
          rows: 24,
          throughOutputSeq: 5,
        ),
      );

      // Must NOT clear or replay
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(sink.ops.length, opCount);
      expect(store.state.historyHighWaterSeq, 5);
      expect(store.appliedLiveSeq, 8);
      expect(store.state.phase, AttachPhase.live);
      expect(sink.historyReplayedCount, 1);
    },
  );

  test(
    'delta merge: UTF-8 rune split across snapshot delta boundary decodes correctly',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      // Initial history with 6 bytes ('hello ')
      final prefix = utf8.encode('hello ');
      store.dispatch(
        HistoryBytes(
          prefix,
          cols: 80,
          rows: 24,
          throughOutputSeq: 1,
          rawOutputStart: 0,
        ),
      );
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(store.appliedLogBytes, 6);

      // Live stream emits 1 byte of 3-byte rune '日' (0xE6, 0x97, 0xA5)
      final rune = utf8.encode('日');
      store.dispatch(LiveBytes([rune[0]], outputSeq: 2));
      expect(store.appliedLogBytes, 7);

      // Subsequent snapshot arrives with full string ('hello 日', 9 bytes) starting at 0
      final fullBytes = [...prefix, ...rune];
      store.dispatch(
        HistoryBytes(
          fullBytes,
          cols: 80,
          rows: 24,
          throughOutputSeq: 3,
          rawOutputStart: 0,
        ),
      );

      // Must NOT clear sink, must append remaining bytes, and must decode rune correctly
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(sink.written.toString(), 'hello 日');
      expect(store.appliedLogBytes, 9);
    },
  );

  test(
    'delta merge: empty snapshot payload is a clean no-op without clear',
    () {
      final sink = FakeTerminalSink();
      final store = TerminalStore(sink);
      store.dispatch(const Resize(80, 24));

      store.dispatch(
        HistoryBytes(
          b('initial'),
          cols: 80,
          rows: 24,
          throughOutputSeq: 1,
          rawOutputStart: 0,
        ),
      );
      expect(sink.ops.where((op) => op == 'clear').length, 1);
      final opCount = sink.ops.length;

      // Empty snapshot payload arrives at offset 0
      store.dispatch(
        HistoryBytes(
          const <int>[],
          cols: 80,
          rows: 24,
          throughOutputSeq: 1,
          rawOutputStart: 0,
        ),
      );

      expect(sink.ops.where((op) => op == 'clear').length, 1);
      expect(sink.ops.length, opCount);
      expect(sink.historyReplayedCount, 1);
    },
  );

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

  // A daemon restart (cold restore or session revive) resets a session's
  // `output_seq` counter to 0 while the byte log carries on unchanged (a
  // handover, by contrast, preserves both counters). A client still holding
  // the pre-restart high-water would score every renumbered chunk as a
  // duplicate and go permanently deaf: history stays on screen, the cursor
  // still blinks, and typing reaches the PTY while nothing it produces is
  // ever drawn.
  test('live seq restarting below the high-water still renders (restart)', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('OLD'), cols: 80, rows: 24, throughOutputSeq: 90000),
    );
    store.dispatch(LiveBytes(b('pre'), outputSeq: 90001));
    expect(sink.ops, ['resize:80,24', 'clear', 'write:OLD', 'write:pre']);

    // Restarted daemon renumbers from scratch.
    sink.ops.clear();
    store.dispatch(LiveBytes(b('after'), outputSeq: 1));
    store.dispatch(LiveBytes(b('more'), outputSeq: 2));
    expect(sink.ops, ['write:after', 'write:more']);
  });

  // The epoch-reset window (1024) never trips for a fresh session: a baseline
  // of 500 renumbered to 0/1 scores `0 < 500 - 1024` as false, so without the
  // low-baseline clause every renumbered chunk looks like a duplicate and the
  // terminal goes permanently deaf after a restart.
  test('live seq reset to 0/1 on a fresh session still renders (restart)', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('OLD'), cols: 80, rows: 24, throughOutputSeq: 495),
    );
    store.dispatch(LiveBytes(b('pre'), outputSeq: 500));
    expect(sink.ops, ['resize:80,24', 'clear', 'write:OLD', 'write:pre']);

    // Restarted daemon renumbers from scratch.
    sink.ops.clear();
    store.dispatch(LiveBytes(b('after'), outputSeq: 1));
    store.dispatch(LiveBytes(b('more'), outputSeq: 2));
    expect(sink.ops, ['write:after', 'write:more']);
  });

  test('startup redelivery of seq 1 at a tiny baseline stays a duplicate', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('OLD'), cols: 80, rows: 24, throughOutputSeq: 8),
    );
    store.dispatch(LiveBytes(b('pre'), outputSeq: 10));
    sink.ops.clear();

    // Baseline is 10: seq 1 is an old duplicate, not a new epoch.
    store.dispatch(LiveBytes(b('stale'), outputSeq: 1));
    expect(sink.ops, isEmpty);
  });

  test(
    'delta merge mid-frame flushes without closing the synchronized block',
    () {
      final deltaSink = FakeTerminalSink();
      final deltaStore = TerminalStore(deltaSink);
      addTearDown(deltaStore.dispose);
      deltaStore.dispatch(const Resize(80, 24));

      const seed = 'seed ';
      const frameStart = '\x1b[?2026hframe ';
      const delta = 'delta ';
      deltaStore.dispatch(
        HistoryBytes(
          b(seed),
          cols: 80,
          rows: 24,
          throughOutputSeq: 5,
          rawOutputStart: 0,
        ),
      );
      // Open a Mode 2026 frame over the live stream: buffered, nothing written.
      deltaStore.dispatch(LiveBytes(b(frameStart), outputSeq: 6));
      final bufferedOpCount = deltaSink.ops.length;

      // Overlapping snapshot covering seed + live + unseen delta bytes.
      deltaStore.dispatch(
        HistoryBytes(
          b('$seed$frameStart$delta'),
          cols: 80,
          rows: 24,
          throughOutputSeq: 7,
          rawOutputStart: 0,
        ),
      );

      // Delta merge: no clear, and the buffered frame paints verbatim.
      expect(deltaSink.ops.where((op) => op == 'clear').length, 1);
      expect(deltaSink.ops.length, bufferedOpCount + 1);
      expect(deltaSink.ops.last, 'write:$frameStart$delta');
      expect(deltaSink.historyReplayedCount, 1);

      // The block is still open: mid-frame live bytes buffer instead of writing.
      deltaStore.dispatch(LiveBytes(b('more\n'), outputSeq: 8));
      expect(deltaSink.ops.last, 'write:$frameStart$delta');

      // The real end marker still closes the frame atomically.
      deltaStore.dispatch(LiveBytes(b('\x1b[?2026l'), outputSeq: 9));
      expect(deltaSink.ops.last, 'write:more\n\x1b[?2026l');
    },
  );

  test('empty snapshot without coordinates on a live store is a pure no-op',
      () {
    final emptySink = FakeTerminalSink();
    final emptyStore = TerminalStore(emptySink);
    addTearDown(emptyStore.dispose);
    emptyStore.dispatch(const Resize(80, 24));
    emptyStore.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    emptyStore.dispatch(LiveBytes(b('b' * 30), outputSeq: 8));
    expect(emptyStore.appliedLogBytes, 80);
    final opCount = emptySink.ops.length;

    emptyStore.dispatch(const HistoryBytes([], cols: 80, rows: 24));

    expect(emptySink.ops.where((op) => op == 'clear').length, 1);
    expect(emptySink.ops.length, opCount);
    expect(emptyStore.appliedLogBytes, 80);
    expect(emptyStore.appliedLiveSeq, 8);
    expect(emptyStore.state.historyHighWaterSeq, 5);
    expect(emptySink.historyReplayedCount, 1);
  });

  test('empty ahead-seq snapshot neither clears nor drops late live', () {
    final aheadSink = FakeTerminalSink();
    final aheadStore = TerminalStore(aheadSink);
    addTearDown(aheadStore.dispose);
    aheadStore.dispatch(const Resize(80, 24));
    aheadStore.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    aheadStore.dispatch(LiveBytes(b('live'), outputSeq: 8));

    // Old-daemon resync shape: no raw_output_start, advancing seq, no bytes.
    aheadStore.dispatch(
      const HistoryBytes([], cols: 80, rows: 24, throughOutputSeq: 10),
    );
    aheadStore.dispatch(LiveBytes(b('late'), outputSeq: 9));

    expect(aheadSink.ops.where((op) => op == 'clear').length, 1);
    expect(aheadSink.ops.last, 'write:late');
  });

  test('empty snapshot on an exited store still replays and clears exited', () {
    final exitedSink = FakeTerminalSink();
    final exitedStore = TerminalStore(exitedSink);
    addTearDown(exitedStore.dispose);
    exitedStore.dispatch(const Resize(80, 24));
    exitedStore.dispatch(
      HistoryBytes(
        b('old'),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    exitedStore.dispatch(const Exited());
    expect(exitedStore.state.exited, isTrue);
    exitedStore.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    expect(exitedStore.state.exited, isFalse);
    expect(exitedSink.ops.where((op) => op == 'clear').length, 2);
    expect(exitedSink.historyReplayedCount, 2);
  });

  test('empty snapshot at the applied byte offset is a no-op', () {
    final atSink = FakeTerminalSink();
    final atStore = TerminalStore(atSink);
    addTearDown(atStore.dispose);
    atStore.dispatch(const Resize(80, 24));
    atStore.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    expect(atStore.appliedLogBytes, 50);
    final opCount = atSink.ops.length;

    atStore.dispatch(
      const HistoryBytes([], cols: 80, rows: 24, throughOutputSeq: 5,
          rawOutputStart: 50),
    );

    expect(atSink.ops.where((op) => op == 'clear').length, 1);
    expect(atSink.ops.length, opCount);
    expect(atStore.appliedLogBytes, 50);
    // The empty-snapshot guard must not advance the live baseline: without
    // it, this input falls into the delta no-op path, which sets it to 5.
    expect(atStore.appliedLiveSeq, isNull);
  });

  test('live without output_seq applies over sequenced history', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('H'), cols: 80, rows: 24, throughOutputSeq: 5),
    );
    sink.ops.clear();

    store.dispatch(LiveBytes(b('x')));

    expect(sink.ops, ['write:x']);
  });

  test('negative history counters neither throw nor poison watermarks', () {
    final negSink = FakeTerminalSink();
    final negStore = TerminalStore(negSink);
    addTearDown(negStore.dispose);
    negStore.dispatch(const Resize(80, 24));
    negStore.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );

    // Corrupt frame (schema is uint64): treated as unanchored, so the store
    // falls back to a full replay with sane, non-negative baselines.
    negStore.dispatch(
      HistoryBytes(
        b('junk'),
        cols: 80,
        rows: 24,
        throughOutputSeq: 6,
        rawOutputStart: -5,
      ),
    );

    expect(negSink.ops.where((op) => op == 'clear').length, 2);
    expect(negStore.appliedLogBytes, 4);
    expect(negStore.state.historyHighWaterSeq, 6);
  });

  test('negative history throughOutputSeq replays without poisoning', () {
    final negSeqSink = FakeTerminalSink();
    final negSeqStore = TerminalStore(negSeqSink);
    addTearDown(negSeqStore.dispose);
    negSeqStore.dispatch(const Resize(80, 24));
    negSeqStore.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );

    // Mirror of the negative-rawOutputStart case: the corrupt seq sanitizes
    // to null and must not poison the high-water mark.
    negSeqStore.dispatch(
      HistoryBytes(
        b('junk'),
        cols: 80,
        rows: 24,
        throughOutputSeq: -7,
        rawOutputStart: 0,
      ),
    );

    expect(negSeqSink.ops.where((op) => op == 'clear').length, 2);
    expect(negSeqStore.state.historyHighWaterSeq, 5);
    expect(negSeqStore.appliedLogBytes, 4);
  });

  test('negative live seq applies as unsequenced without baselines', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('OLD'), cols: 80, rows: 24, throughOutputSeq: 8),
    );
    store.dispatch(LiveBytes(b('pre'), outputSeq: 10));
    sink.ops.clear();

    // Corrupt counter, not corrupt bytes: treated as unsequenced, so the
    // content applies exactly like a seq-less chunk while both watermarks
    // stay put.
    store.dispatch(LiveBytes(b('stale'), outputSeq: -3));

    expect(sink.ops, ['write:stale']);
    expect(store.state.historyHighWaterSeq, 8);
    expect(store.appliedLiveSeq, 10);
  });

  test('negative live seq at a large baseline neither resets nor poisons',
      () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('OLD'), cols: 80, rows: 24, throughOutputSeq: 1999),
    );
    store.dispatch(LiveBytes(b('pre'), outputSeq: 2000));
    sink.ops.clear();

    // Without the sanitize, -3 reads as an epoch reset at this baseline,
    // wiping both watermarks and parking the live baseline on -3.
    store.dispatch(LiveBytes(b('stale'), outputSeq: -3));

    expect(sink.ops, ['write:stale']);
    expect(store.state.historyHighWaterSeq, 1999);
    expect(store.appliedLiveSeq, 2000);
  });

  test('negative live seq on null baselines applies without recording', () {
    final nullSink = FakeTerminalSink();
    final nullStore = TerminalStore(nullSink);
    addTearDown(nullStore.dispose);
    nullStore.dispatch(const Resize(80, 24));
    nullStore.dispatch(
      HistoryBytes(b('H'), cols: 80, rows: 24, rawOutputStart: 0),
    );
    expect(nullStore.state.historyHighWaterSeq, isNull);
    expect(nullStore.appliedLiveSeq, isNull);
    nullSink.ops.clear();

    nullStore.dispatch(LiveBytes(b('x'), outputSeq: -3));

    expect(nullSink.ops, ['write:x']);
    expect(nullStore.appliedLiveSeq, isNull);
  });

  test('trimmed log tail replays once, re-anchors, then delta-merges', () {
    final trimSink = FakeTerminalSink();
    final trimStore = TerminalStore(trimSink);
    addTearDown(trimStore.dispose);
    trimStore.dispatch(const Resize(80, 24));
    trimStore.dispatch(
      HistoryBytes(
        b('a' * 100),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    trimStore.dispatch(LiveBytes(b('b' * 20), outputSeq: 8));
    expect(trimStore.appliedLogBytes, 120);

    // Daemon trimmed the log and rebased its offsets while the seq advanced:
    // nonzero start, advanced seq, byte end behind the applied head.
    trimStore.dispatch(
      HistoryBytes(
        b('c' * 10),
        cols: 80,
        rows: 24,
        throughOutputSeq: 9,
        rawOutputStart: 90,
      ),
    );

    expect(trimSink.ops.where((op) => op == 'clear').length, 2);
    expect(trimSink.ops.last, 'write:${'c' * 10}');
    expect(trimStore.appliedLogBytes, 100);
    expect(trimStore.state.historyHighWaterSeq, 9);

    // A follow-up snapshot merges instead of replaying or no-op looping.
    trimStore.dispatch(
      HistoryBytes(
        b('${'c' * 10}ddddd'),
        cols: 80,
        rows: 24,
        throughOutputSeq: 10,
        rawOutputStart: 90,
      ),
    );

    expect(trimSink.ops.where((op) => op == 'clear').length, 2);
    expect(trimSink.ops.last, 'write:ddddd');
    expect(trimStore.appliedLogBytes, 105);
  });

  test('shorter snapshot at exactly the live head still replays', () {
    final eqSink = FakeTerminalSink();
    final eqStore = TerminalStore(eqSink);
    addTearDown(eqStore.dispose);
    eqStore.dispatch(const Resize(80, 24));
    eqStore.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    eqStore.dispatch(LiveBytes(b('b' * 30), outputSeq: 8));
    expect(eqStore.appliedLogBytes, 80);

    // Same epoch position as the live baseline but fewer bytes: the extra
    // applied bytes no longer exist (trim landed mid-epoch), so the equality
    // arms of the freshness check must still count this as fresh.
    final fresh = 'c' * 30;
    eqStore.dispatch(
      HistoryBytes(
        b(fresh),
        cols: 80,
        rows: 24,
        throughOutputSeq: 8,
        rawOutputStart: 0,
      ),
    );

    expect(eqSink.ops.where((op) => op == 'clear').length, 2);
    expect(eqSink.ops.last, 'write:$fresh');
    expect(eqStore.appliedLogBytes, 30);
    expect(eqStore.state.historyHighWaterSeq, 8);
  });

  test('resize-broadcast empty snapshot is a no-op on a live store', () {
    final bcSink = FakeTerminalSink();
    final bcStore = TerminalStore(bcSink);
    addTearDown(bcStore.dispose);
    bcStore.dispatch(const Resize(80, 24));
    bcStore.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    bcStore.dispatch(LiveBytes(b('b' * 30), outputSeq: 8));
    final opCount = bcSink.ops.length;

    // The exact daemon resize-broadcast shape: anchored coordinates, the
    // current seq, no bytes.
    bcStore.dispatch(
      const HistoryBytes(
        [],
        cols: 100,
        rows: 30,
        throughOutputSeq: 8,
        rawOutputStart: 0,
      ),
    );

    expect(bcSink.ops.where((op) => op == 'clear').length, 1);
    expect(bcSink.ops.length, opCount + 1);
    expect(bcSink.ops.last, 'resize:100,30');
    expect(bcStore.appliedLogBytes, 80);
    expect(bcStore.appliedLiveSeq, 8);
  });

  test('empty snapshot past the head then its tail replays without a gap',
      () {
    final gapSink = FakeTerminalSink();
    final gapStore = TerminalStore(gapSink);
    addTearDown(gapStore.dispose);
    gapStore.dispatch(const Resize(80, 24));
    gapStore.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    gapStore.dispatch(LiveBytes(b('b' * 30), outputSeq: 8));
    expect(gapStore.appliedLogBytes, 80);

    // An empty snapshot stranded past the applied head carries no bytes to
    // anchor a replay, so the guard swallows it; the tail that follows
    // still carries the gap evidence and replays.
    gapStore.dispatch(
      const HistoryBytes(
        [],
        cols: 80,
        rows: 24,
        throughOutputSeq: 8,
        rawOutputStart: 120,
      ),
    );
    expect(gapSink.ops.where((op) => op == 'clear').length, 1);

    gapStore.dispatch(
      HistoryBytes(
        b('t' * 10),
        cols: 80,
        rows: 24,
        throughOutputSeq: 9,
        rawOutputStart: 120,
      ),
    );

    expect(gapSink.ops.where((op) => op == 'clear').length, 2);
    expect(gapSink.ops.last, 'write:${'t' * 10}');
    expect(gapStore.appliedLogBytes, 130);
  });

  test('shorter snapshot with advanced seq replays instead of no-op', () {
    final truncSink = FakeTerminalSink();
    final truncStore = TerminalStore(truncSink);
    addTearDown(truncStore.dispose);
    truncStore.dispatch(const Resize(80, 24));
    truncStore.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    truncStore.dispatch(LiveBytes(b('b' * 30), outputSeq: 8));
    expect(truncStore.appliedLogBytes, 80);

    // Authoritative and newer (seq 10 past the live baseline 8) but shorter:
    // the extra 50 applied bytes no longer exist and must not be kept.
    final fresh = 'c' * 30;
    truncStore.dispatch(
      HistoryBytes(
        b(fresh),
        cols: 80,
        rows: 24,
        throughOutputSeq: 10,
        rawOutputStart: 0,
      ),
    );

    expect(truncSink.ops.where((op) => op == 'clear').length, 2);
    expect(truncSink.ops.last, 'write:$fresh');
    expect(truncStore.appliedLogBytes, 30);
    expect(truncStore.state.historyHighWaterSeq, 10);
  });

  test('restart snapshot at seq 1 without rawOutputStart replays', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('OLD'), cols: 80, rows: 24, throughOutputSeq: 0),
    );
    store.dispatch(LiveBytes(b('a'), outputSeq: 2));
    sink.ops.clear();

    // Post-restart snapshot carrying seq 1 once output flowed: same new epoch
    // the live path's 0/1 rule matches, so history must replay, not no-op.
    store.dispatch(
      HistoryBytes(b('NEW'), cols: 80, rows: 24, throughOutputSeq: 1),
    );

    expect(sink.ops, ['clear', 'write:NEW']);
  });

  test('history-first restart snapshot rebases live dedup (no deafness)', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('OLD'), cols: 80, rows: 24, throughOutputSeq: 495),
    );
    store.dispatch(LiveBytes(b('pre'), outputSeq: 500));
    sink.ops.clear();

    // The restart snapshot arrives before any new-epoch live chunk: replay
    // clears the stale live baseline, so the new epoch applies immediately.
    store.dispatch(
      HistoryBytes(
        b('NEW'),
        cols: 80,
        rows: 24,
        throughOutputSeq: 1,
        rawOutputStart: 0,
      ),
    );
    store.dispatch(LiveBytes(b('after'), outputSeq: 2));

    expect(sink.ops, ['clear', 'write:NEW', 'write:after']);
  });

  test('baseline 11 with seq 1 resets to the new epoch', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('OLD'), cols: 80, rows: 24, throughOutputSeq: 9),
    );
    store.dispatch(LiveBytes(b('pre'), outputSeq: 11));
    sink.ops.clear();

    store.dispatch(LiveBytes(b('after'), outputSeq: 1));
    store.dispatch(LiveBytes(b('more'), outputSeq: 2));

    expect(sink.ops, ['write:after', 'write:more']);
  });

  test('baseline 11 with seq 2 stays a duplicate', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('OLD'), cols: 80, rows: 24, throughOutputSeq: 9),
    );
    store.dispatch(LiveBytes(b('pre'), outputSeq: 11));
    sink.ops.clear();

    store.dispatch(LiveBytes(b('stale'), outputSeq: 2));

    expect(sink.ops, isEmpty);
  });

  test('epoch window edge: baseline-1024 is a duplicate, below resets', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('OLD'), cols: 80, rows: 24, throughOutputSeq: 1999),
    );
    store.dispatch(LiveBytes(b('pre'), outputSeq: 2000));
    sink.ops.clear();

    store.dispatch(LiveBytes(b('old'), outputSeq: 976));
    expect(sink.ops, isEmpty);

    store.dispatch(LiveBytes(b('new'), outputSeq: 975));
    expect(sink.ops, ['write:new']);
  });

  test('delta merge over a plain List<int> appends only the delta', () {
    final listSink = FakeTerminalSink();
    final listStore = TerminalStore(listSink);
    addTearDown(listStore.dispose);
    listStore.dispatch(const Resize(80, 24));
    listStore.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    listStore.dispatch(LiveBytes(b('b' * 20), outputSeq: 7));
    expect(listStore.appliedLogBytes, 70);

    // A spread list is a plain growable List, not a Uint8List, so this
    // exercises the copying sublist branch rather than sublistView.
    final fullSnapshot = [...b('${'a' * 50}${'b' * 20}${'c' * 30}')];
    listStore.dispatch(
      HistoryBytes(
        fullSnapshot,
        cols: 80,
        rows: 24,
        throughOutputSeq: 10,
        rawOutputStart: 0,
      ),
    );

    expect(listSink.ops.where((op) => op == 'clear').length, 1);
    expect(listSink.ops.last, 'write:${'c' * 30}');
    expect(listStore.appliedLogBytes, 100);
    expect(listStore.state.historyHighWaterSeq, 10);
  });

  test('history after re-Attach full-replays even with overlapping seq', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );
    store.dispatch(const Attach());

    store.dispatch(
      HistoryBytes(
        b('a' * 50),
        cols: 80,
        rows: 24,
        throughOutputSeq: 5,
        rawOutputStart: 0,
      ),
    );

    expect(sink.ops.where((op) => op == 'clear').length, 2);
    expect(store.state.phase, AttachPhase.live);
    expect(store.state.scrollbackReady, isTrue);
  });

  test('disposing inside a history write does not throw on notify', () {
    final reentrantSink = ReentrantSink();
    final reentrantStore = TerminalStore(reentrantSink);
    reentrantStore.dispatch(const Resize(80, 24));
    reentrantStore.dispatch(const Attach());
    reentrantSink.onWrite = reentrantStore.dispose;

    expect(
      () => reentrantStore.dispatch(
        HistoryBytes(
          b('hi'),
          cols: 80,
          rows: 24,
          throughOutputSeq: 1,
          rawOutputStart: 0,
        ),
      ),
      returnsNormally,
    );
    // Proves the write actually fired and the dispose ran reentrantly: a
    // store that never wrote would pass the assertion above vacuously.
    expect(reentrantSink.ops, contains('dispose'));
  });

  test('large payload newline translation completes quickly without stalling', () {
    store.dispatch(const Attach());
    store.dispatch(
      HistoryBytes(b('init'), cols: 80, rows: 24, throughOutputSeq: 1),
    );
    sink.ops.clear();

    final pattern = 'line of terminal output\nand another line\r\n';
    final repeated = pattern * 10000;
    final stopwatch = Stopwatch()..start();
    store.dispatch(LiveBytes(utf8.encode(repeated), outputSeq: 2));
    stopwatch.stop();

    expect(sink.written.toString(), contains('line of terminal output\r\n'));
    expect(stopwatch.elapsedMilliseconds, lessThan(2000));
  });
}
