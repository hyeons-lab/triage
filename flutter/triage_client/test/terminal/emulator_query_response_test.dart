import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/emulator_query_response.dart';

void main() {
  group('isEmulatorQueryResponse', () {
    test('matches Cursor Position Reports (CPR)', () {
      expect(isEmulatorQueryResponse('\x1b[1;1R'), isTrue);
      expect(isEmulatorQueryResponse('\x1b[24;80R'), isTrue);
      expect(isEmulatorQueryResponse('\x1b[100;200R'), isTrue);
    });

    test('matches Device Attributes (DA1, DA2, DA3, DSR)', () {
      expect(isEmulatorQueryResponse('\x1b[?1;2c'), isTrue);
      expect(
        isEmulatorQueryResponse('\x1b[?62;1;2;4;6;7;8;9;15;18;21;22;28;29c'),
        isTrue,
      );
      expect(isEmulatorQueryResponse('\x1b[>0;276;0c'), isTrue);
      expect(isEmulatorQueryResponse('\x1b[>1;10;0c'), isTrue);
      expect(isEmulatorQueryResponse('\x1b[0n'), isTrue);
      expect(isEmulatorQueryResponse('\x1b[3n'), isTrue);
    });

    test('matches Kitty keyboard protocol responses', () {
      expect(isEmulatorQueryResponse('\x1b[?0u'), isTrue);
      expect(isEmulatorQueryResponse('\x1b[?1u'), isTrue);
      expect(isEmulatorQueryResponse('\x1b[?31u'), isTrue);
    });

    test('matches DECRPM mode reports', () {
      expect(isEmulatorQueryResponse('\x1b[?2026;2\$y'), isTrue);
      expect(isEmulatorQueryResponse('\x1b[?2027;1\$y'), isTrue);
      expect(isEmulatorQueryResponse('\x1b[2026;2\$y'), isTrue);
      expect(isEmulatorQueryResponse('\x072026;2\$y\x072027;3\$y'), isTrue);
      expect(isEmulatorQueryResponse('2026;2\$y'), isFalse);
    });

    test('matches OSC color query responses', () {
      expect(isEmulatorQueryResponse('\x1b]10;rgb:ffff/ffff/ffff\x07'), isTrue);
      expect(
        isEmulatorQueryResponse('\x1b]11;rgb:0000/0000/0000\x1b\\'),
        isTrue,
      );
    });

    test('matches window size reports', () {
      expect(isEmulatorQueryResponse('\x1b[4;600;800t'), isTrue);
      expect(isEmulatorQueryResponse('\x1b[8;24;80t'), isTrue);
    });

    test('matches concatenated query responses', () {
      expect(isEmulatorQueryResponse('\x1b[?1;2c\x1b[24;1R'), isTrue);
      expect(
        isEmulatorQueryResponse('\x1b[?0u\x1b[?2026;2\$y\x1b[1;1R'),
        isTrue,
      );
    });

    test('does NOT match user keystrokes or editing keys', () {
      // Normal characters
      expect(isEmulatorQueryResponse(''), isFalse);
      expect(isEmulatorQueryResponse('a'), isFalse);
      expect(isEmulatorQueryResponse('ls -la\n'), isFalse);
      expect(isEmulatorQueryResponse('R'), isFalse);
      expect(isEmulatorQueryResponse('c'), isFalse);
      expect(isEmulatorQueryResponse('\r'), isFalse);
      expect(isEmulatorQueryResponse('\n'), isFalse);
      expect(isEmulatorQueryResponse('\t'), isFalse);
      expect(isEmulatorQueryResponse('\x7f'), isFalse);
      expect(isEmulatorQueryResponse('\x03'), isFalse);

      // Arrow keys (Cursor Up, Down, Forward, Back)
      expect(isEmulatorQueryResponse('\x1b[A'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[B'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[C'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[D'), isFalse);
      expect(isEmulatorQueryResponse('\x1bOA'), isFalse);
      expect(isEmulatorQueryResponse('\x1bOB'), isFalse);
      expect(isEmulatorQueryResponse('\x1bOC'), isFalse);
      expect(isEmulatorQueryResponse('\x1bOD'), isFalse);

      // Home, End, PageUp, PageDown, Delete, Insert
      expect(isEmulatorQueryResponse('\x1b[H'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[F'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[1~'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[4~'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[5~'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[6~'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[2~'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[3~'), isFalse);

      // Function keys
      expect(isEmulatorQueryResponse('\x1bOP'), isFalse);
      expect(isEmulatorQueryResponse('\x1bOQ'), isFalse);
      expect(isEmulatorQueryResponse('\x1bOR'), isFalse);
      expect(isEmulatorQueryResponse('\x1bOS'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[15~'), isFalse);

      // Modified keys (Ctrl/Alt/Shift + arrows)
      expect(isEmulatorQueryResponse('\x1b[1;5A'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[1;2B'), isFalse);
      expect(isEmulatorQueryResponse('\x1b[1;3C'), isFalse);

      // Shift-Tab (BackTab)
      expect(isEmulatorQueryResponse('\x1b[Z'), isFalse);
    });
  });
}
