import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_intent.dart';
import 'package:triage_client/terminal/terminal_state.dart';
import 'package:triage_client/terminal/terminal_sink.dart';
import 'package:triage_client/terminal/terminal_store.dart';

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
    store.dispatch(HistoryBytes(b('H'), cols: 80, rows: 24, throughOutputSeq: 5));
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
    store.dispatch(HistoryBytes(b('H'), cols: 80, rows: 24, throughOutputSeq: 5));
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

  test('bare LF normalized to CRLF, existing CRLF preserved', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    store.dispatch(LiveBytes(b('a\nb\r\nc')));
    expect(sink.written.toString(), 'a\r\nb\r\nc');
  });

  test('CRLF split across chunks is not doubled', () {
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    sink.ops.clear();
    store.dispatch(LiveBytes(b('line\r')));
    store.dispatch(LiveBytes(b('\nnext')));
    expect(sink.written.toString(), 'line\r\nnext');
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
    store.dispatch(const Attach());
    store.dispatch(const HistoryBytes([], cols: 80, rows: 24));
    hostResize.clear();
    sink.emitOutput('x'); // user keystroke from emulator
    sink.emitResize(70, 20); // emulator fit
    expect(hostInput, ['x']);
    expect(hostResize, ['70,20']);
  });

  test('detached live bytes are ignored', () {
    store.dispatch(LiveBytes(b('ghost')));
    expect(sink.ops, isEmpty);
  });
}
