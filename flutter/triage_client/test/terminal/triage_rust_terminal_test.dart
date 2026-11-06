import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/main.dart' show SessionVm;
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

  test(
    'TriageRustTerminal narrowing resize at scrollback capacity does not spin',
    () {
      final terminal = createTriageTerminal(maxLines: 50, reflowEnabled: true);
      addTearDown(terminal.dispose);
      terminal.resize(80, 10);

      for (var i = 0; i < 60; i++) {
        terminal.write('line-${i.toString().padLeft(2, '0')}-${'X' * 65}\r\n');
      }
      expect(terminal.buffer.lines.length, 50);

      final sw = Stopwatch()..start();
      terminal.resize(20, 10);
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(50));
      expect(terminal.buffer.lines.length, 50);
    },
  );

  test(
    'TriageRustTerminal setSynchronizedUpdateMode batches writes into one notification',
    () {
      final terminal = createTriageTerminal(
        maxLines: 1000,
        reflowEnabled: true,
      );
      addTearDown(terminal.dispose);
      terminal.resize(44, 30);

      var notifications = 0;
      terminal.addListener(() {
        notifications++;
      });

      terminal.setSynchronizedUpdateMode(true);
      for (var i = 0; i < 200; i++) {
        terminal.write('batch-line-$i\r\n');
      }
      expect(notifications, 0);

      terminal.setSynchronizedUpdateMode(false);
      expect(notifications, 1);
      expect(terminal.buffer.getText(), contains('batch-line-199'));
    },
  );

  test(
    'SessionVm replays history and resizes to mobile dimensions without freezing',
    () {
      final vm = SessionVm(
        title: 'mobile-replay',
        status: 'Running',
        statusColor: Colors.green,
        icon: Icons.terminal,
        rows: const [],
        sessionId: 'session-mobile-test',
        isRemote: true,
      );
      addTearDown(vm.dispose);

      // Start at mobile viewport 44x30 and replay 300 synchronized output frames.
      vm.noteViewFit(44, 30);
      final payload = StringBuffer();
      for (var i = 0; i < 300; i++) {
        payload.write(
          '\x1b[?2026h\r\x1b[2KFrame $i: ${'A' * 70}\r\n\x1b[?2026l',
        );
      }
      final sw = Stopwatch()..start();
      vm.applyHistory(
        payload.toString().codeUnits,
        throughOutputSeq: 1,
        rawOutputStart: 0,
        windowBytes: 256 * 1024,
      );
      vm.terminal.resize(80, 24);
      vm.terminal.resize(44, 30);
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(250));
      expect(vm.terminal.buffer.getText(), contains('Frame 299'));
    },
  );

  test(
    'alternate screen height shrink with non-whitespace bottom row does not spin',
    () {
      final terminal = createTriageTerminal(maxLines: 1000);
      addTearDown(terminal.dispose);

      terminal.write('\x1b[?1049h\x1b[1;1HHeader\x1b[24;1HStatusBar\x1b[1;1H');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(terminal.buffer.height, 24);

      terminal.resize(44, 15);
      expect(terminal.viewWidth, 44);
      expect(terminal.viewHeight, 15);
      expect(terminal.buffer.height, 15);
    },
  );

  test(
    '30-frame IME keyboard height animation on full scrollback completes quickly',
    () {
      final terminal = createTriageTerminal(maxLines: 1000);
      addTearDown(terminal.dispose);

      terminal.resize(44, 30);
      final sb = StringBuffer();
      for (var i = 0; i < 1000; i++) {
        sb.write('scrollback-line-$i-content\r\n');
      }
      terminal.write(sb.toString());
      expect(terminal.buffer.height, 1000);

      final sw = Stopwatch()..start();
      for (var rows = 29; rows >= 15; rows--) {
        terminal.resize(44, rows);
      }
      for (var rows = 16; rows <= 30; rows++) {
        terminal.resize(44, rows);
      }
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(50));
      expect(terminal.viewHeight, 30);
      expect(terminal.buffer.getText(), contains('scrollback-line-999'));
    },
  );

  test(
    '500 incremental live writes over 10,000 scrollback lines complete quickly',
    () {
      final vm = SessionVm(
        title: 'scrollback-live-burst',
        status: 'Running',
        statusColor: Colors.green,
        icon: Icons.terminal,
        rows: const [],
        sessionId: 'session-burst-test',
        isRemote: true,
      );
      addTearDown(vm.dispose);

      vm.noteViewFit(80, 24);
      vm.applyHistory(
        const <int>[],
        throughOutputSeq: 0,
        rawOutputStart: 0,
        windowBytes: 64 * 1024,
      );
      final initial = StringBuffer();
      for (var i = 0; i < 10000; i++) {
        initial.write('history-row-$i-${'x' * 50}\r\n');
      }
      vm.terminal.setSynchronizedUpdateMode(true);
      vm.terminal.write(initial.toString());
      vm.terminal.setSynchronizedUpdateMode(false);
      expect(vm.terminal.buffer.height, greaterThanOrEqualTo(10000));

      var notifications = 0;
      vm.terminal.addListener(() {
        notifications++;
      });

      final sw = Stopwatch()..start();
      // 250 unbatched incremental writes (each syncing against a 10k-line scrollback).
      for (var i = 0; i < 250; i++) {
        vm.applyLiveBytes('live-unbatched-$i\r\n'.codeUnits, outputSeq: i + 1);
      }
      expect(notifications, 250);

      // 250 batched live writes (as in _processWebsocketEventQueue).
      vm.beginTerminalWriteBatch();
      for (var i = 250; i < 500; i++) {
        vm.applyLiveBytes('live-batched-$i\r\n'.codeUnits, outputSeq: i + 1);
      }
      vm.endTerminalWriteBatch();
      sw.stop();

      expect(notifications, 251);
      expect(sw.elapsedMilliseconds, lessThan(150));
      expect(vm.terminal.buffer.getText(), contains('live-batched-499'));
    },
  );
}
