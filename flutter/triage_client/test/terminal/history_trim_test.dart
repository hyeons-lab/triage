import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_store.dart';

void main() {
  List<int> b(String s) => utf8.encode(s);
  String s(List<int> bytes) => utf8.decode(bytes);

  test('empty payload stays empty (no reset prologue)', () {
    final out = trimHistoryTail([], maxLines: 10, maxBytes: 1024);
    expect(out, isEmpty);
  });

  test('payload under both caps passes through untouched', () {
    final input = b('one\ntwo\nthree\n');
    final out = trimHistoryTail(input, maxLines: 10, maxBytes: 1024);
    expect(identical(out, input), isTrue);
  });

  test('keeps the last K complete lines with trailing newline', () {
    final out = trimHistoryTail(
      b('a\nb\nc\nd\n'),
      maxLines: 2,
      maxBytes: 1024,
    );
    expect(s(out), '\x1b[0mc\nd\n');
  });

  test('keeps the last K lines without trailing newline', () {
    final out = trimHistoryTail(
      b('a\nb\nc'),
      maxLines: 2,
      maxBytes: 1024,
    );
    expect(s(out), '\x1b[0mb\nc');
  });

  test('trailing newline terminates instead of starting an empty line', () {
    final out = trimHistoryTail(
      b('a\nb\n'),
      maxLines: 1,
      maxBytes: 1024,
    );
    expect(s(out), '\x1b[0mb\n');
  });

  test('byte cap binds a single huge line', () {
    final line = 'x' * 100;
    final out = trimHistoryTail(
      b(line),
      maxLines: 1000,
      maxBytes: 10,
    );
    expect(s(out), '\x1b[0m${'x' * 10}');
  });

  test('byte cap wins when the line window is still too big', () {
    // 10 lines x 11 bytes = 110 bytes; line cap keeps all, byte cap keeps 22.
    final payload = List.generate(10, (i) => 'line$i-5678\n').join();
    final out = trimHistoryTail(
      b(payload),
      maxLines: 1000,
      maxBytes: 22,
    );
    expect(s(out), '\x1b[0mline8-5678\nline9-5678\n');
  });

  test('non-positive budgets keep nothing', () {
    expect(
      trimHistoryTail(b('a\nb\n'), maxLines: 0, maxBytes: 1024),
      isEmpty,
    );
    expect(
      trimHistoryTail(b('a\nb\n'), maxLines: 10, maxBytes: 0),
      isEmpty,
    );
  });

  test('reset prologue appears exactly when trimmed', () {
    const reset = '\x1b[0m';
    final kept = trimHistoryTail(b('a\n'), maxLines: 10, maxBytes: 1024);
    expect(s(kept).startsWith(reset), isFalse);
    final trimmed = trimHistoryTail(b('a\nb\n'), maxLines: 1, maxBytes: 1024);
    expect(s(trimmed).startsWith(reset), isTrue);
  });

  test('byte cap mid-line advances to the next complete line', () {
    // 20-byte window cuts into line8; the partial row is dropped rather than
    // replayed mid-line.
    final payload = List.generate(10, (i) => 'line$i-5678\n').join();
    final out = trimHistoryTail(
      b(payload),
      maxLines: 1000,
      maxBytes: 20,
    );
    expect(s(out), '\x1b[0mline9-5678\n');
  });

  test('byte cap mid-rune skips continuation bytes, no replacement glyph', () {
    // 'hello \u20ac world\n': the 3-byte euro sign sits at bytes 6..9. A
    // maxBytes window cutting into it must start on a rune boundary, so the
    // decoded replay holds no U+FFFD.
    final input = b('hello \u20ac world\n');
    for (var cut = 1; cut <= 12; cut++) {
      final out = trimHistoryTail(input, maxLines: 1000, maxBytes: cut);
      expect(
        s(out).contains('\uFFFD'),
        isFalse,
        reason: 'maxBytes=$cut produced a replacement glyph',
      );
    }
    // The tightest windows keep only the tail runes after the cut rune.
    final tight = trimHistoryTail(input, maxLines: 1000, maxBytes: 7);
    expect(s(tight), '\x1b[0m world\n');
  });

  test(
    'in-place spinner frames with cursor-up and linefeeds do not starve earlier history lines',
    () {
      final historyLines = List.generate(20, (i) => 'scrollback-$i\r\n').join();
      final spinnerFrames =
          '\x1b[?2026h\r\x1b[3A⠹  Running command...\n\n\n\x1b[19D\x1b[?2026l' *
          400;
      final input = b('$historyLines$spinnerFrames');
      final res = trimHistoryTailWithOffset(
        input,
        maxLines: 1000,
        maxBytes: 65536,
      );
      expect(res.droppedBytes, 0);
      expect(s(res.bytes), contains('scrollback-0\r\n'));
    },
  );

  test(
    'trimHistoryReplay preserves rawOutputPrefix when rawOutput alone exceeds maxBytes',
    () {
      final prefix = b(List.generate(50, (i) => 'prefix-$i\r\n').join());
      final raw = b('x' * 4000);
      final trimmed = trimHistoryReplay(
        rawOutputPrefix: prefix,
        rawOutput: raw,
        maxLines: 1000,
        maxBytes: 2000,
      );
      expect(trimmed.retainedPrefixBytes, greaterThan(0));
      expect(trimmed.prefixBytes, isNotEmpty);
      expect(s(trimmed.prefixBytes), contains('prefix-49\r\n'));
    },
  );

  test(
    'trimHistoryTailWithOffset handles 50000 consecutive newlines in linear time',
    () {
      final bytes = List<int>.filled(50000, 0x0a);
      final sw = Stopwatch()..start();
      final res = trimHistoryTailWithOffset(
        bytes,
        maxLines: 1000,
        maxBytes: 64 * 1024,
      );
      sw.stop();
      expect(res.droppedBytes, 49000);
      expect(sw.elapsedMilliseconds, lessThan(200));
    },
  );
}
