import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/approval_prompt_parser.dart';

void main() {
  test('returns null for ordinary terminal output without approval flag', () {
    final prompt = parseApprovalPrompt(
      pendingApproval: false,
      visibleRows: const [
        '1. First build step',
        '2. Second build step',
        'cargo test passed',
        r'~/repo $',
      ],
    );
    expect(prompt, isNull);
  });

  test('parses [y/N] confirmation prompts into tap-to-answer choices', () {
    final prompt = parseApprovalPrompt(
      pendingApproval: false,
      visibleRows: const ['Apply database migration? [y/N]'],
    );
    expect(prompt, isNotNull);
    expect(prompt!.reason, 'Apply database migration? [y/N]');
    expect(prompt.choices.map((c) => (c.label, c.bytes)).toList(), [
      ('Yes (y)', 'y\r'),
      ('No (n)', 'n\r'),
      ('Esc', '\x1b'),
    ]);
  });

  test('parses numbered menu choices ahead of fallback defaults', () {
    final prompt = parseApprovalPrompt(
      pendingApproval: false,
      visibleRows: const [
        'Do you want to proceed?',
        '❯ 1. Yes',
        '  2. Yes, always allow',
        '  3. No, cancel',
      ],
    );
    expect(prompt, isNotNull);
    expect(prompt!.reason, 'Do you want to proceed?');
    expect(prompt.choices.map((c) => (c.label, c.bytes)).toList(), [
      ('1. Yes', '1'),
      ('2. Yes, always allow', '2'),
      ('3. No, cancel', '3'),
      ('Esc', '\x1b'),
    ]);
  });

  test('uses daemon pendingApproval and reason even when rows lack tokens', () {
    final prompt = parseApprovalPrompt(
      pendingApproval: true,
      pendingApprovalReason: 'Tool requires human approval: rm -rf ./tmp',
      visibleRows: const ['waiting...'],
    );
    expect(prompt, isNotNull);
    expect(prompt!.reason, 'Tool requires human approval: rm -rf ./tmp');
    expect(prompt.choices.map((c) => (c.label, c.bytes)).toList(), [
      ('Yes (y)', 'y\r'),
      ('Always (a)', 'a\r'),
      ('No (n)', 'n\r'),
      ('Esc', '\x1b'),
    ]);
  });
}
