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
}
