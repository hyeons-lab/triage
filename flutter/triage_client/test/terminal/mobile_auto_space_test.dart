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
  });
}
