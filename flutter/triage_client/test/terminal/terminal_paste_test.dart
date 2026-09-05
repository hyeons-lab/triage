import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/main.dart';
import 'package:triage_client/terminal/terminal_paste.dart';
import 'package:triage_client/widgets/multiline_paste_dialog.dart';
import 'package:triage_client/widgets/terminal_pane.dart';

void main() {
  group('formatPasteInput', () {
    test('returns empty string when input is empty', () {
      expect(formatPasteInput('', true), '');
      expect(formatPasteInput('', false), '');
    });

    test(
      'normalizes CRLF and bare LF to CR when bracketed paste is disabled',
      () {
        expect(formatPasteInput('hello world', false), 'hello world');
        expect(
          formatPasteInput('line1\nline2\r\nline3', false),
          'line1\rline2\rline3',
        );
      },
    );

    test(
      'preserves Unicode grapheme clusters and emojis with ZWJ when formatted',
      () {
        const emojiText = '👨‍👩‍👧‍👦 Hello 世界 🚀\n';
        expect(
          formatPasteInput(emojiText, true),
          '\x1b[200~$emojiText\x1b[201~',
        );
      },
    );

    test(
      'wraps single-line text with bracketed paste escape sequences when enabled',
      () {
        expect(
          formatPasteInput('git status', true),
          '\x1b[200~git status\x1b[201~',
        );
      },
    );

    test(
      'wraps multi-line text with bracketed paste escape sequences when enabled',
      () {
        const multiLine = 'echo "hello"\necho "world"\n';
        expect(
          formatPasteInput(multiLine, true),
          '\x1b[200~$multiLine\x1b[201~',
        );
      },
    );

    test('preserves CRLF within multi-line paste when enabled', () {
      const crlfText = 'first\r\nsecond\r\nthird';
      expect(formatPasteInput(crlfText, true), '\x1b[200~$crlfText\x1b[201~');
    });

    test(
      'preserves lone CR and mixed line endings within multi-line paste when enabled',
      () {
        const mixedText = 'line1\rline2\nline3\r\nline4';
        expect(
          formatPasteInput(mixedText, true),
          '\x1b[200~$mixedText\x1b[201~',
        );
      },
    );

    test('wraps whitespace-only string when enabled', () {
      const whitespace = '   \t  \n  ';
      expect(
        formatPasteInput(whitespace, true),
        '\x1b[200~$whitespace\x1b[201~',
      );
    });

    test(
      'strips embedded escape injection sequence \\x1b[201~ from payload',
      () {
        const malicious = 'echo "safe"\x1b[201~rm -rf /\x1b[200~echo "more"';
        final formatted = formatPasteInput(malicious, true);
        expect(
          formatted,
          '\x1b[200~echo "safe"rm -rf /\x1b[200~echo "more"\x1b[201~',
        );
        // Ensure the only terminating \\x1b[201~ is at the very end
        expect(
          formatted.indexOf('\x1b[201~'),
          formatted.length - '\x1b[201~'.length,
        );
      },
    );

    test(
      'strips 8-bit C1 escape injection sequence \\x9b201~ from payload',
      () {
        const maliciousC1 = 'echo "safe"\x9b201~rm -rf /\x9b200~echo "more"';
        final formatted = formatPasteInput(maliciousC1, true);
        expect(
          formatted,
          '\x1b[200~echo "safe"rm -rf /\x9b200~echo "more"\x1b[201~',
        );
        expect(formatted.contains('\x9b201~'), isFalse);
      },
    );

    test('strips combined 7-bit and 8-bit C1 injection sequences', () {
      const mixed = 'line1\x1b[201~injected1\x9b201~injected2\x1b[201~line2';
      final formatted = formatPasteInput(mixed, true);
      expect(formatted, '\x1b[200~line1injected1injected2line2\x1b[201~');
      expect(
        formatted.indexOf('\x1b[201~'),
        formatted.length - '\x1b[201~'.length,
      );
      expect(formatted.contains('\x9b201~'), isFalse);
    });
  });

  group('isMultiLine', () {
    test('reports false for empty and single-line text', () {
      expect(isMultiLine(''), isFalse);
      expect(isMultiLine('hello world'), isFalse);
      expect(isMultiLine('git status --short'), isFalse);
    });

    test('reports true for multi-line text with LF, CRLF, and CR', () {
      expect(isMultiLine('hello\nworld'), isTrue);
      expect(isMultiLine('hello\r\nworld'), isTrue);
      expect(isMultiLine('hello\rworld'), isTrue);
      expect(isMultiLine('trailing newline\n'), isTrue);
    });
  });

  group('flattenToSingleLine', () {
    test('preserves single-line text', () {
      expect(flattenToSingleLine('hello world'), 'hello world');
    });

    test('replaces various newline sequences with a single space', () {
      expect(
        flattenToSingleLine('line1\nline2\r\nline3\rline4'),
        'line1 line2 line3 line4',
      );
      expect(flattenToSingleLine('command1\ncommand2\n'), 'command1 command2 ');
    });

    test('handles empty string and consecutive newlines', () {
      expect(flattenToSingleLine(''), '');
      expect(flattenToSingleLine('line1\n\nline2'), 'line1  line2');
      expect(flattenToSingleLine('\r\n'), ' ');
    });
  });

  group('lineCount', () {
    test('returns 0 for empty string', () {
      expect(lineCount(''), 0);
    });

    test('returns 1 for single line without newlines', () {
      expect(lineCount('single line'), 1);
    });

    test('returns correct count for multiline strings', () {
      expect(lineCount('line 1\nline 2'), 2);
      expect(lineCount('line 1\r\nline 2\r\nline 3'), 3);
      expect(lineCount('line 1\nline 2\nline 3\nline 4\n'), 4);
    });

    test('handles edge cases, mixed line endings, and trailing newlines', () {
      expect(lineCount('\n'), 1);
      expect(lineCount('\r\n'), 1);
      expect(lineCount('\r'), 1);
      expect(lineCount('\n\n\n'), 3);
      expect(lineCount('trailing CR\r'), 1);
      expect(lineCount('a\rb\nc\r\nd'), 4);
      expect(lineCount('a\rb\nc\r\nd\n'), 4);
    });
  });

  group('showMultiLinePasteDialog widget tests', () {
    testWidgets(
      'renders dialog with line count, snippet preview, and action buttons',
      (tester) async {
        String? result;
        const testPayload =
            'line 1: first log\nline 2: second log\nline 3: third log';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    result = await showMultiLinePasteDialog(
                      context,
                      testPayload,
                    );
                  },
                  child: const Text('Open Dialog'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Dialog'));
        await tester.pumpAndSettle();

        expect(find.text('Multi-Line Paste Warning'), findsOneWidget);
        expect(find.textContaining('3 lines'), findsOneWidget);
        expect(find.textContaining('line 1: first log'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Paste as Single Line'), findsOneWidget);
        expect(find.text('Paste (Execute Commands)'), findsOneWidget);

        // Tap "Paste as Single Line"
        await tester.tap(find.text('Paste as Single Line'));
        await tester.pumpAndSettle();

        expect(
          result,
          'line 1: first log line 2: second log line 3: third log',
        );
      },
    );

    testWidgets('Paste (Execute Commands) returns original multiline text', (
      tester,
    ) async {
      String? result;
      const testPayload = 'git add .\ngit commit -m "feat"\n';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showMultiLinePasteDialog(context, testPayload);
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Paste (Execute Commands)'));
      await tester.pumpAndSettle();

      expect(result, testPayload);
    });

    testWidgets('Cancel returns null without sending input', (tester) async {
      String? result = 'initial';
      const testPayload = 'rm -rf /\necho done\n';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showMultiLinePasteDialog(context, testPayload);
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets(
      'renders truncated snippet when lines exceed display limit',
      (tester) async {
        final multiline = List.generate(10, (i) => 'Line ${i + 1}').join('\n');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showMultiLinePasteDialog(context, multiline),
                  child: const Text('Open Dialog'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Dialog'));
        await tester.pumpAndSettle();

        expect(find.text('Multi-Line Paste Warning'), findsOneWidget);
        expect(find.textContaining('10 lines'), findsOneWidget);
        expect(find.textContaining('... (4 more lines)'), findsOneWidget);
        expect(find.textContaining('Line 1'), findsOneWidget);
        expect(find.textContaining('Line 6'), findsOneWidget);
        expect(find.textContaining('Line 7'), findsNothing);
      },
    );

    testWidgets('formats size in KB for payloads >= 1024 bytes', (
      tester,
    ) async {
      final largePayload = '${'a' * 2048}\n${'b' * 10}';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showMultiLinePasteDialog(context, largePayload),
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.textContaining('2.0 KB'), findsOneWidget);
    });
  });

  group('SessionVm bracketed paste state', () {
    test(
      'initializes with bracketedPasteEnabled = false and synchronizes terminal',
      () {
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
      },
    );

    test(
      'SessionVm with distinct title and sessionId synchronizes without errors',
      () {
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
      },
    );

    test(
      'TerminalPane.setBracketedPasteMode static handler is safe to call',
      () {
        expect(
          () => TerminalPane.setBracketedPasteMode('session-1', true),
          returnsNormally,
        );
        expect(
          () => TerminalPane.setBracketedPasteMode('session-1', false),
          returnsNormally,
        );
      },
    );
  });
}
