import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/main.dart';
import 'package:triage_client/terminal/terminal_paste.dart';
import 'package:triage_client/widgets/terminal_pane.dart';

void main() {
  group('formatPasteInput', () {
    test('returns empty string when input is empty', () {
      expect(formatPasteInput('', true), '');
      expect(formatPasteInput('', false), '');
    });

    test('returns verbatim string when bracketed paste is disabled', () {
      expect(formatPasteInput('hello world', false), 'hello world');
      expect(
        formatPasteInput('line1\nline2\r\nline3', false),
        'line1\nline2\r\nline3',
      );
    });

    test('wraps single-line text with bracketed paste escape sequences when enabled', () {
      expect(
        formatPasteInput('git status', true),
        '\x1b[200~git status\x1b[201~',
      );
    });

    test('wraps multi-line text with bracketed paste escape sequences when enabled', () {
      const multiLine = 'echo "hello"\necho "world"\n';
      expect(
        formatPasteInput(multiLine, true),
        '\x1b[200~$multiLine\x1b[201~',
      );
    });

    test('preserves CRLF within multi-line paste when enabled', () {
      const crlfText = 'first\r\nsecond\r\nthird';
      expect(
        formatPasteInput(crlfText, true),
        '\x1b[200~$crlfText\x1b[201~',
      );
    });

    test('preserves lone CR and mixed line endings within multi-line paste when enabled', () {
      const mixedText = 'line1\rline2\nline3\r\nline4';
      expect(
        formatPasteInput(mixedText, true),
        '\x1b[200~$mixedText\x1b[201~',
      );
    });

    test('wraps whitespace-only string when enabled', () {
      const whitespace = '   \t  \n  ';
      expect(
        formatPasteInput(whitespace, true),
        '\x1b[200~$whitespace\x1b[201~',
      );
    });

    test('strips embedded escape injection sequence \\x1b[201~ from payload', () {
      const malicious = 'echo "safe"\x1b[201~rm -rf /\x1b[200~echo "more"';
      final formatted = formatPasteInput(malicious, true);
      expect(
        formatted,
        '\x1b[200~echo "safe"rm -rf /\x1b[200~echo "more"\x1b[201~',
      );
      // Ensure the only terminating \\x1b[201~ is at the very end
      expect(formatted.indexOf('\x1b[201~'), formatted.length - '\x1b[201~'.length);
    });

    test('strips 8-bit C1 escape injection sequence \\x9b201~ from payload', () {
      const maliciousC1 = 'echo "safe"\x9b201~rm -rf /\x9b200~echo "more"';
      final formatted = formatPasteInput(maliciousC1, true);
      expect(
        formatted,
        '\x1b[200~echo "safe"rm -rf /\x9b200~echo "more"\x1b[201~',
      );
      expect(formatted.contains('\x9b201~'), isFalse);
    });

    test('strips combined 7-bit and 8-bit C1 injection sequences', () {
      const mixed = 'line1\x1b[201~injected1\x9b201~injected2\x1b[201~line2';
      final formatted = formatPasteInput(mixed, true);
      expect(
        formatted,
        '\x1b[200~line1injected1injected2line2\x1b[201~',
      );
      expect(formatted.indexOf('\x1b[201~'), formatted.length - '\x1b[201~'.length);
      expect(formatted.contains('\x9b201~'), isFalse);
    });
  });

  group('SessionVm bracketed paste state', () {
    test('initializes with bracketedPasteEnabled = false and synchronizes terminal', () {
      final session = SessionVm(
        title: 'test-session',
        status: 'attached',
        statusColor: const Color(0xff7fd1c7),
        icon: Icons.terminal,
        rows: [],
      );

      expect(session.bracketedPasteEnabled, isFalse);
      expect(session.terminal.bracketedPasteMode, isFalse);

      session.setBracketedPasteEnabled(true);
      expect(session.bracketedPasteEnabled, isTrue);
      expect(session.terminal.bracketedPasteMode, isTrue);

      session.setBracketedPasteEnabled(false);
      expect(session.bracketedPasteEnabled, isFalse);
      expect(session.terminal.bracketedPasteMode, isFalse);
    });

    test('SessionVm with distinct title and sessionId synchronizes without errors', () {
      final session = SessionVm(
        title: 'triage / 01952e43-8472-7633-8a03-68e7b1a13fa4',
        sessionId: '01952e43-8472-7633-8a03-68e7b1a13fa4',
        status: 'attached',
        statusColor: const Color(0xff7fd1c7),
        icon: Icons.terminal,
        rows: [],
      );

      session.setBracketedPasteEnabled(true);
      expect(session.bracketedPasteEnabled, isTrue);
      expect(session.terminal.bracketedPasteMode, isTrue);
    });

    test('TerminalPane.setBracketedPasteMode static handler is safe to call', () {
      expect(() => TerminalPane.setBracketedPasteMode('session-1', true), returnsNormally);
      expect(() => TerminalPane.setBracketedPasteMode('session-1', false), returnsNormally);
    });
  });
}
