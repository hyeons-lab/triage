import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/control_bytes.dart';

void main() {
  group('controlByteForChar (accessory-bar sticky Ctrl)', () {
    test('maps letters to their control code, case-insensitively', () {
      expect(controlByteForChar('c'), '\x03'); // Ctrl+C -> SIGINT
      expect(controlByteForChar('C'), '\x03');
      expect(controlByteForChar('k'), '\x0b'); // Ctrl+K
      expect(controlByteForChar('K'), '\x0b');
      expect(controlByteForChar('a'), '\x01'); // Ctrl+A
      expect(controlByteForChar('z'), '\x1a'); // Ctrl+Z -> SIGTSTP
      expect(controlByteForChar('d'), '\x04'); // Ctrl+D -> EOF
    });

    test('maps the @[\\]^_ range', () {
      expect(controlByteForChar('['), '\x1b'); // Ctrl+[ -> ESC
      expect(controlByteForChar('@'), '\x00'); // Ctrl+@ -> NUL
      expect(controlByteForChar('_'), '\x1f');
    });

    test('returns null for characters with no control form', () {
      expect(controlByteForChar('1'), isNull);
      expect(controlByteForChar(' '), isNull);
      expect(controlByteForChar('/'), isNull);
    });

    test('returns null unless exactly one character', () {
      expect(controlByteForChar(''), isNull);
      expect(controlByteForChar('ab'), isNull);
    });
  });

  group('bytesForEnterKey (Shift+Enter newline)', () {
    String? enter({
      bool shift = false,
      bool ctrl = false,
      bool alt = false,
      bool meta = false,
    }) => bytesForEnterKey(shift: shift, ctrl: ctrl, alt: alt, meta: meta);

    test('shift alone sends LF', () {
      expect(enter(shift: true), '\n');
    });

    test('plain enter keeps the default path', () {
      expect(enter(), isNull);
    });

    test('any other modifier keeps the default path', () {
      expect(enter(shift: true, ctrl: true), isNull);
      expect(enter(shift: true, alt: true), isNull);
      expect(enter(shift: true, meta: true), isNull);
      expect(enter(ctrl: true), isNull);
      expect(enter(alt: true), isNull);
      expect(enter(meta: true), isNull);
    });
  });
}
