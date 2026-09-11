import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/mobile_auto_space.dart';

void main() {
  group('MobileAutoSpaceTracker', () {
    late MobileAutoSpaceTracker tracker;

    setUp(() {
      tracker = MobileAutoSpaceTracker();
    });

    test('initial state has no preceding word', () {
      expect(tracker.lastEndedWithWordChar, isFalse);
    });

    test('first swiped word is emitted without prepended space', () {
      expect(tracker.processInput('git'), 'git');
      expect(tracker.lastEndedWithWordChar, isTrue);
    });

    test('consecutive swiped words automatically receive a leading space', () {
      expect(tracker.processInput('git'), 'git');
      expect(tracker.processInput('status'), ' status');
      expect(tracker.processInput('checkout'), ' checkout');
      expect(tracker.lastEndedWithWordChar, isTrue);
    });

    test(
      'manual space prevents duplicate spaces on subsequent swiped word',
      () {
        expect(tracker.processInput('git'), 'git');
        expect(tracker.processInput(' '), ' ');
        expect(tracker.lastEndedWithWordChar, isFalse);
        expect(tracker.processInput('status'), 'status');
      },
    );

    test('key-by-key tap typing within a word does not insert spaces', () {
      expect(tracker.processInput('c'), 'c');
      expect(tracker.processInput('d'), 'd');
      expect(tracker.lastEndedWithWordChar, isTrue);
    });

    test('punctuation and flag prefixes do not insert leading spaces', () {
      expect(tracker.processInput('git'), 'git');
      expect(tracker.processInput('-'), '-');
      expect(tracker.lastEndedWithWordChar, isFalse);
      expect(tracker.processInput('m'), 'm');
    });

    test('paths do not insert spaces around slashes', () {
      expect(tracker.processInput('/'), '/');
      expect(tracker.processInput('usr'), 'usr');
      expect(tracker.processInput('/'), '/');
      expect(tracker.processInput('bin'), 'bin');
    });

    test('Enter and Return reset word tracking', () {
      expect(tracker.processInput('git'), 'git');
      expect(tracker.processInput('\r'), '\r');
      expect(tracker.lastEndedWithWordChar, isFalse);
      expect(tracker.processInput('status'), 'status');
    });

    test('Backspace resets word tracking', () {
      expect(tracker.processInput('git'), 'git');
      expect(tracker.processInput('\x7f'), '\x7f');
      expect(tracker.lastEndedWithWordChar, isFalse);
      expect(tracker.processInput('status'), 'status');
    });

    test('Tab resets word tracking', () {
      expect(tracker.processInput('git'), 'git');
      expect(tracker.processInput('\t'), '\t');
      expect(tracker.lastEndedWithWordChar, isFalse);
      expect(tracker.processInput('status'), 'status');
    });

    test('reset() clears state on host write or user interaction', () {
      expect(tracker.processInput('git'), 'git');
      tracker.reset();
      expect(tracker.lastEndedWithWordChar, isFalse);
      expect(tracker.processInput('status'), 'status');
    });

    test('empty string returns empty and preserves state', () {
      expect(tracker.processInput('git'), 'git');
      expect(tracker.processInput(''), '');
      expect(tracker.lastEndedWithWordChar, isTrue);
    });

    test('accented Latin-1 letters are treated as word characters', () {
      expect(tracker.processInput('café'), 'café');
      expect(tracker.lastEndedWithWordChar, isTrue);
      expect(tracker.processInput('noir'), ' noir');
    });

    test('global Unicode scripts are treated as word characters', () {
      // Cyrillic
      expect(tracker.processInput('привет'), 'привет');
      expect(tracker.lastEndedWithWordChar, isTrue);
      expect(tracker.processInput('мир'), ' мир');

      // Polish (Extended Latin)
      tracker.reset();
      expect(tracker.processInput('cześć'), 'cześć');
      expect(tracker.lastEndedWithWordChar, isTrue);
      expect(tracker.processInput('świecie'), ' świecie');

      // Korean Hangul
      tracker.reset();
      expect(tracker.processInput('안녕'), '안녕');
      expect(tracker.lastEndedWithWordChar, isTrue);
      expect(tracker.processInput('세상'), ' 세상');
    });

    test('PTY echo simulation does not clear tracking state between words', () {
      // 1. User swipes first word
      expect(tracker.processInput('git'), 'git');
      expect(tracker.lastEndedWithWordChar, isTrue);

      // 2. Remote PTY echoes "git" to terminal output (not a tracker reset event)
      expect(tracker.lastEndedWithWordChar, isTrue);

      // 3. User swipes second word: leading space is correctly inserted
      expect(tracker.processInput('status'), ' status');
      expect(tracker.lastEndedWithWordChar, isTrue);
    });

    test('words ending with digits retain word character state', () {
      expect(tracker.processInput('python3'), 'python3');
      expect(tracker.lastEndedWithWordChar, isTrue);
      expect(tracker.processInput('script'), ' script');

      tracker.reset();
      expect(tracker.processInput('utf8'), 'utf8');
      expect(tracker.lastEndedWithWordChar, isTrue);
      expect(tracker.processInput('encoding'), ' encoding');
    });

    test(
      'surrogate pairs such as emojis do not register as word characters',
      () {
        final emoji = '🚀';
        final firstCodeUnit = emoji.codeUnitAt(0);
        expect(MobileAutoSpaceTracker.isWordChar(firstCodeUnit), isFalse);

        expect(tracker.processInput(emoji), emoji);
        expect(tracker.lastEndedWithWordChar, isFalse);
        expect(tracker.processInput('launch'), 'launch');
      },
    );
  });
}
