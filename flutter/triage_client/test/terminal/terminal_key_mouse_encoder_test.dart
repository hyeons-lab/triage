import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_key_encoder.dart';
import 'package:triage_client/terminal/terminal_mouse_encoder.dart';

KeyDownEvent _down(
  LogicalKeyboardKey logical, {
  PhysicalKeyboardKey? physical,
  String? character,
}) {
  return KeyDownEvent(
    physicalKey: physical ?? PhysicalKeyboardKey.keyA,
    logicalKey: logical,
    character: character,
    timeStamp: Duration.zero,
  );
}

void main() {
  group('encodeTerminalKeyEvent', () {
    String? encode(
      LogicalKeyboardKey key, {
      String? character,
      bool shift = false,
      bool ctrl = false,
      bool alt = false,
      bool meta = false,
      TargetPlatform platform = TargetPlatform.linux,
      bool appCursorKeys = false,
      int kittyKeyboardFlags = 0,
    }) {
      return encodeTerminalKeyEvent(
        _down(key, character: character),
        shift: shift,
        ctrl: ctrl,
        alt: alt,
        meta: meta,
        platform: platform,
        appCursorKeys: appCursorKeys,
        kittyKeyboardFlags: kittyKeyboardFlags,
      );
    }

    test('ignores KeyUpEvent and pure modifier keys', () {
      const up = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      );
      expect(
        encodeTerminalKeyEvent(
          up,
          shift: false,
          ctrl: false,
          alt: false,
          meta: false,
          platform: TargetPlatform.macOS,
        ),
        isNull,
      );
      expect(encode(LogicalKeyboardKey.shiftLeft, shift: true), isNull);
      expect(encode(LogicalKeyboardKey.controlLeft, ctrl: true), isNull);
      expect(encode(LogicalKeyboardKey.metaLeft, meta: true), isNull);
    });

    test('encodes arrows and Home/End in normal vs DECCKM and with modifiers', () {
      expect(encode(LogicalKeyboardKey.arrowUp), '\x1b[A');
      expect(
        encode(LogicalKeyboardKey.arrowUp, appCursorKeys: true),
        '\x1bOA',
      );
      expect(encode(LogicalKeyboardKey.home), '\x1b[H');
      expect(encode(LogicalKeyboardKey.end, appCursorKeys: true), '\x1bOF');
      expect(encode(LogicalKeyboardKey.arrowRight, shift: true), '\x1b[1;2C');
      expect(encode(LogicalKeyboardKey.arrowLeft, alt: true), '\x1b[1;3D');
      expect(
        encode(LogicalKeyboardKey.arrowDown, ctrl: true, appCursorKeys: true),
        '\x1b[1;5B',
      );
    });

    test('encodes function keys F1..F12 and tilde navigation keys', () {
      expect(encode(LogicalKeyboardKey.f1), '\x1bOP');
      expect(encode(LogicalKeyboardKey.f4, shift: true), '\x1b[1;2S');
      expect(encode(LogicalKeyboardKey.f5), '\x1b[15~');
      expect(encode(LogicalKeyboardKey.f12, ctrl: true), '\x1b[24;5~');
      expect(encode(LogicalKeyboardKey.delete), '\x1b[3~');
      expect(encode(LogicalKeyboardKey.pageUp, alt: true), '\x1b[5;3~');
    });

    test('encodes Enter, Tab, Backspace, Escape, Ctrl chords, and macOS Cmd chords', () {
      expect(encode(LogicalKeyboardKey.enter), '\r');
      expect(encode(LogicalKeyboardKey.enter, alt: true), '\x1b\r');
      expect(encode(LogicalKeyboardKey.tab), '\t');
      expect(encode(LogicalKeyboardKey.tab, shift: true), '\x1b[Z');
      expect(encode(LogicalKeyboardKey.backspace), '\x7f');
      expect(encode(LogicalKeyboardKey.backspace, ctrl: true), '\x08');
      expect(encode(LogicalKeyboardKey.backspace, alt: true), '\x1b\x7f');
      expect(encode(LogicalKeyboardKey.escape), '\x1b');
      expect(encode(LogicalKeyboardKey.escape, alt: true), '\x1b\x1b');
      expect(encode(LogicalKeyboardKey.keyC, ctrl: true), '\x03');
      expect(encode(LogicalKeyboardKey.keyC, ctrl: true, alt: true), '\x1b\x03');
      expect(encode(LogicalKeyboardKey.space, ctrl: true), '\x00');

      expect(
        encode(
          LogicalKeyboardKey.arrowLeft,
          meta: true,
          platform: TargetPlatform.macOS,
        ),
        '\x01',
      );
      expect(
        encode(
          LogicalKeyboardKey.arrowRight,
          meta: true,
          platform: TargetPlatform.macOS,
        ),
        '\x05',
      );
      expect(
        encode(
          LogicalKeyboardKey.backspace,
          meta: true,
          platform: TargetPlatform.macOS,
        ),
        '\x15',
      );
      expect(
        encode(
          LogicalKeyboardKey.keyK,
          meta: true,
          platform: TargetPlatform.macOS,
        ),
        isNull,
      );
    });

    test('encodes Kitty keyboard disambiguate sequences when flag 1 is active', () {
      expect(
        encode(
          LogicalKeyboardKey.escape,
          kittyKeyboardFlags: kKittyDisambiguateEscapeCodes,
        ),
        '\x1b[27u',
      );
      expect(
        encode(
          LogicalKeyboardKey.enter,
          shift: true,
          kittyKeyboardFlags: kKittyDisambiguateEscapeCodes,
        ),
        '\x1b[13;2u',
      );
      expect(
        encode(
          LogicalKeyboardKey.enter,
          ctrl: true,
          kittyKeyboardFlags: kKittyDisambiguateEscapeCodes,
        ),
        '\x1b[13;5u',
      );
    });
  });

  group('encodeTerminalMouseEvent & encodeAltScreenFallbackWheel', () {
    test('distinguishes X10 (?9 = 1) from VT200 (?1000 = 2), ?1002 = 3, and ?1003 = 4', () {
      // Off -> null
      expect(
        encodeTerminalMouseEvent(
          mouseMode: kMouseModeOff,
          mouseReportMode: kMouseReportSgr,
          button: TerminalMouseButton.left,
          col: 4,
          row: 9,
          pressed: true,
        ),
        isNull,
      );

      // X10 (?9 -> mouseMode 1): reports press only; drops release, wheel, and motion.
      expect(
        encodeTerminalMouseEvent(
          mouseMode: kMouseModeX10,
          mouseReportMode: kMouseReportSgr,
          button: TerminalMouseButton.left,
          col: 4,
          row: 9,
          pressed: true,
        ),
        '\x1b[<0;5;10M',
      );
      expect(
        encodeTerminalMouseEvent(
          mouseMode: kMouseModeX10,
          mouseReportMode: kMouseReportSgr,
          button: TerminalMouseButton.left,
          col: 4,
          row: 9,
          pressed: false,
        ),
        isNull,
      );
      expect(
        encodeTerminalMouseEvent(
          mouseMode: kMouseModeX10,
          mouseReportMode: kMouseReportSgr,
          button: TerminalMouseButton.wheelUp,
          col: 4,
          row: 9,
          pressed: true,
        ),
        isNull,
      );

      // VT200 (?1000 -> mouseMode 2): reports press, release, and wheel, but not motion.
      expect(
        encodeTerminalMouseEvent(
          mouseMode: kMouseModeNormal,
          mouseReportMode: kMouseReportSgr,
          button: TerminalMouseButton.left,
          col: 4,
          row: 9,
          pressed: false,
        ),
        '\x1b[<0;5;10m',
      );
      expect(
        encodeTerminalMouseEvent(
          mouseMode: kMouseModeNormal,
          mouseReportMode: kMouseReportSgr,
          button: TerminalMouseButton.wheelDown,
          col: 4,
          row: 9,
          pressed: true,
        ),
        '\x1b[<65;5;10M',
      );
      expect(
        encodeTerminalMouseEvent(
          mouseMode: kMouseModeNormal,
          mouseReportMode: kMouseReportSgr,
          button: TerminalMouseButton.left,
          col: 4,
          row: 9,
          pressed: true,
          motion: true,
        ),
        isNull,
      );

      // Button-event (?1002 = 3) and any-event (?1003 = 4) encode motion (+32) and modifiers.
      expect(
        encodeTerminalMouseEvent(
          mouseMode: kMouseModeButtonEvent,
          mouseReportMode: kMouseReportSgr,
          button: TerminalMouseButton.left,
          col: 299,
          row: 199,
          pressed: true,
          motion: true,
          shift: true,
          ctrl: true,
        ),
        '\x1b[<52;300;200M',
      );
    });

    test('encodes legacy X10/VT200 6-byte packets and caps coordinates at 223', () {
      final press = encodeTerminalMouseEvent(
        mouseMode: kMouseModeNormal,
        mouseReportMode: kMouseReportNormal,
        button: TerminalMouseButton.left,
        col: 0,
        row: 0,
        pressed: true,
      );
      expect(press?.codeUnits, <int>[0x1b, 0x5b, 0x4d, 32, 33, 33]);

      final release = encodeTerminalMouseEvent(
        mouseMode: kMouseModeNormal,
        mouseReportMode: kMouseReportNormal,
        button: TerminalMouseButton.left,
        col: 0,
        row: 0,
        pressed: false,
      );
      expect(release?.codeUnits, <int>[0x1b, 0x5b, 0x4d, 35, 33, 33]);

      expect(
        encodeTerminalMouseEvent(
          mouseMode: kMouseModeNormal,
          mouseReportMode: kMouseReportNormal,
          button: TerminalMouseButton.left,
          col: 223,
          row: 0,
          pressed: true,
        ),
        isNull,
      );
    });

    test('encodeAltScreenFallbackWheel honors appCursorKeys and step count', () {
      expect(
        encodeAltScreenFallbackWheel(up: true, appCursorKeys: false, steps: 3),
        '\x1b[A\x1b[A\x1b[A',
      );
      expect(
        encodeAltScreenFallbackWheel(up: false, appCursorKeys: true, steps: 2),
        '\x1bOB\x1bOB',
      );
    });
  });
}
