import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/triage_term_ffi.dart';
import 'package:xterm2/xterm.dart' as xt;

void main() {
  test('isTriageRustTerminalAvailable matches compiled release cdylib', () {
    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/../../target/release/libtriage_term.dylib',
      '$cwd/../../target/release/libtriage_term.so',
      '$cwd/../../target/release/triage_term.dll',
    ];
    final hasBuiltLib = candidates.any((p) => File(p).existsSync());
    expect(isTriageRustTerminalAvailable, equals(hasBuiltLib));
  });

  test(
    'TriageRustTerminal parses SGR colors, attributes, and cursor position',
    () {
      final terminal = createTriageTerminal(
        maxLines: 1000,
        reflowEnabled: true,
      );
      addTearDown(terminal.dispose);

      terminal.write('\x1b[1;4;38;2;255;128;64;48;5;42mHello\x1b[0m');
      expect(terminal.buffer.cursorX, 5);
      expect(terminal.buffer.cursorY, 0);
      expect(terminal.buffer.lines[0].getText(0, 5), 'Hello');

      final data = xt.CellData.empty();
      terminal.buffer.lines[0].getCellData(0, data);
      expect(data.flags & xt.CellFlags.bold, isNonZero);
      expect(data.flags & xt.CellFlags.underline, isNonZero);
      expect(data.foreground & xt.CellColor.typeMask, xt.CellColor.rgb);
      expect(data.foreground & xt.CellColor.valueMask, 0xFF8040);
      expect(data.background & xt.CellColor.typeMask, xt.CellColor.palette);
      expect(data.background & xt.CellColor.valueMask, 42);
    },
  );

  test('TriageRustTerminal handles wide CJK/emoji and combining marks', () {
    final terminal = createTriageTerminal(maxLines: 1000, reflowEnabled: true);
    addTearDown(terminal.dispose);

    terminal.write('中e\u0301');
    expect(terminal.buffer.cursorX, 3);
    expect(terminal.buffer.lines[0].getWidth(0), 2);
    expect(terminal.buffer.lines[0].getWidth(1), 0);
    expect(terminal.buffer.lines[0].getWidth(2), 1);
    expect(terminal.buffer.lines[0].getText(0, 3), '中e\u0301');
  });

  test('TriageRustTerminal reflows wrapped lines on width resize', () {
    final terminal = createTriageTerminal(maxLines: 1000, reflowEnabled: true);
    addTearDown(terminal.dispose);

    terminal.resize(10, 5);
    terminal.write('0123456789ABCDEF');
    expect(terminal.buffer.lines[0].getText(0, 10), '0123456789');
    expect(terminal.buffer.lines[1].isWrapped, isTrue);
    expect(terminal.buffer.lines[1].getText(0, 6), 'ABCDEF');

    terminal.resize(20, 5);
    expect(terminal.buffer.lines[0].getText(0, 16), '0123456789ABCDEF');
    expect(terminal.buffer.lines[1].isWrapped, isFalse);
  });

  test(
    'TriageRustTerminal ESC[3J detaches scrollback and preserves viewport identity',
    () {
      final terminal = createTriageTerminal(maxLines: 100, reflowEnabled: true);
      addTearDown(terminal.dispose);
      terminal.resize(20, 5);

      for (var i = 0; i < 20; i++) {
        terminal.write('line $i\r\n');
      }
      expect(terminal.buffer.lines.length, greaterThan(5));
      final oldScrollbackLine = terminal.buffer.lines[0];
      final viewportTopLine =
          terminal.buffer.lines[terminal.buffer.lines.length - 5];
      expect(oldScrollbackLine.attached, isTrue);
      expect(viewportTopLine.attached, isTrue);

      terminal.write('\x1b[3J');
      expect(terminal.buffer.lines.length, 5);
      expect(oldScrollbackLine.attached, isFalse);
      expect(viewportTopLine.attached, isTrue);
      expect(identical(terminal.buffer.lines[0], viewportTopLine), isTrue);
    },
  );

  test('TriageRustTerminal switches to and from alternate screen buffer', () {
    final terminal = createTriageTerminal(maxLines: 1000, reflowEnabled: true);
    addTearDown(terminal.dispose);
    terminal.resize(20, 5);

    terminal.write('PrimaryLine');
    expect(terminal.isUsingAltBuffer, isFalse);
    expect(terminal.buffer.lines[0].getText(0, 11), 'PrimaryLine');

    terminal.write('\x1b[?1049hAltLine');
    expect(terminal.isUsingAltBuffer, isTrue);
    expect(terminal.buffer.lines[0].getText(0, 7), 'AltLine');

    terminal.write('\x1b[?1049l');
    expect(terminal.isUsingAltBuffer, isFalse);
    expect(terminal.buffer.lines[0].getText(0, 11), 'PrimaryLine');
  });

  test('TriageRustTerminal clamps oversized CHT without hanging', () {
    final terminal = createTriageTerminal(maxLines: 1000, reflowEnabled: true);
    addTearDown(terminal.dispose);
    terminal.resize(80, 24);

    final sw = Stopwatch()..start();
    terminal.write('A\x1b[999999IB');
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(100));
    expect(terminal.buffer.lines[0].getText().trimRight(), endsWith('B'));
  });
}
