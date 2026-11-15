class ApprovalChoice {
  const ApprovalChoice({
    required this.label,
    required this.bytes,
    this.isPrimary = false,
    this.isDestructive = false,
  });

  final String label;
  final String bytes;
  final bool isPrimary;
  final bool isDestructive;
}

class ApprovalPromptState {
  const ApprovalPromptState({
    required this.reason,
    required this.choices,
    required this.signature,
  });

  final String reason;
  final List<ApprovalChoice> choices;
  final String signature;
}

final RegExp _numberedOptionPattern = RegExp(
  r'^(?:[❯›>*•-]\s*)?([1-9])[.)]\s+(.+)$',
);

const List<String> _approvalPhrases = <String>[
  'do you want to proceed',
  'do you want to continue',
  'do you want to run',
  'do you want to allow',
  'allow once',
  'yes, allow',
  "yes, and don't ask again",
  'approve this',
  'waiting for approval',
  'press enter to confirm',
];

const List<String> _yesNoTokens = <String>[
  '[y/n]',
  '[y/n?',
  '(y/n)',
  '[yes/no]',
  '(yes/no)',
  '[y/n/a]',
  '(y/n/a)',
];

String _truncateChipLabel(String digit, String text) {
  final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  const maxBodyLen = 22;
  final body = compact.length <= maxBodyLen
      ? compact
      : '${compact.substring(0, maxBodyLen - 1)}…';
  return '$digit. $body';
}

bool _isDestructiveOption(String body) {
  final lower = body.toLowerCase();
  return lower == 'no' ||
      lower.startsWith('no,') ||
      lower.startsWith('no ') ||
      lower.contains('deny') ||
      lower.contains('reject') ||
      lower.contains('cancel') ||
      lower.contains("don't");
}

String? _detectApprovalPhrase(List<String> tailRows) {
  final recent = tailRows.length <= 6
      ? tailRows
      : tailRows.sublist(tailRows.length - 6);
  for (final line in recent.reversed) {
    final lower = line.toLowerCase();
    for (final token in _yesNoTokens) {
      if (lower.contains(token)) return line;
    }
    for (final phrase in _approvalPhrases) {
      if (lower.contains(phrase)) return line;
    }
  }
  return null;
}

List<ApprovalChoice> _extractNumberedChoices(List<String> tailRows) {
  final found = <int, String>{};
  for (final line in tailRows) {
    final match = _numberedOptionPattern.firstMatch(line);
    if (match == null) continue;
    final digit = int.tryParse(match.group(1) ?? '');
    final body = match.group(2)?.trim() ?? '';
    if (digit == null || body.isEmpty) continue;
    found[digit] = body;
  }
  if (found.length < 2 || !found.containsKey(1)) {
    return const <ApprovalChoice>[];
  }
  final orderedDigits = found.keys.toList()..sort();
  final choices = <ApprovalChoice>[];
  for (final digit in orderedDigits.take(4)) {
    final body = found[digit]!;
    final digitStr = '$digit';
    choices.add(
      ApprovalChoice(
        label: _truncateChipLabel(digitStr, body),
        bytes: digitStr,
        isPrimary: digit == 1,
        isDestructive: _isDestructiveOption(body),
      ),
    );
  }
  choices.add(
    const ApprovalChoice(label: 'Esc', bytes: '\x1b', isDestructive: true),
  );
  return choices;
}

/// Derives tap-to-answer approval choices from daemon snapshot flags and the
/// bottom non-empty terminal rows, returning `null` when no confirmation is due.
ApprovalPromptState? parseApprovalPrompt({
  required bool pendingApproval,
  String? pendingApprovalReason,
  required List<String> visibleRows,
}) {
  final tailRows = visibleRows
      .map((row) => row.trim())
      .where((row) => row.isNotEmpty)
      .toList();
  final slice = tailRows.length <= 10
      ? tailRows
      : tailRows.sublist(tailRows.length - 10);

  final trimmedReason = pendingApprovalReason?.trim();
  final detectedLine = _detectApprovalPhrase(slice);
  if (!pendingApproval && detectedLine == null) {
    return null;
  }

  final reason = (trimmedReason != null && trimmedReason.isNotEmpty)
      ? trimmedReason
      : (detectedLine ?? 'Approval requested');
  final lowerContext =
      '${reason.toLowerCase()}\n${slice.join('\n').toLowerCase()}';

  final numbered = _extractNumberedChoices(slice);
  final List<ApprovalChoice> choices;
  if (numbered.isNotEmpty) {
    choices = numbered;
  } else if (lowerContext.contains('press enter to confirm')) {
    choices = const <ApprovalChoice>[
      ApprovalChoice(label: 'Confirm', bytes: '\r', isPrimary: true),
      ApprovalChoice(label: 'Esc', bytes: '\x1b', isDestructive: true),
    ];
  } else if (lowerContext.contains('[y/n/a]') ||
      lowerContext.contains('(y/n/a)')) {
    choices = const <ApprovalChoice>[
      ApprovalChoice(label: 'Yes (y)', bytes: 'y\r', isPrimary: true),
      ApprovalChoice(label: 'Always (a)', bytes: 'a\r'),
      ApprovalChoice(label: 'No (n)', bytes: 'n\r', isDestructive: true),
      ApprovalChoice(label: 'Esc', bytes: '\x1b'),
    ];
  } else if (_yesNoTokens.any(lowerContext.contains)) {
    choices = const <ApprovalChoice>[
      ApprovalChoice(label: 'Yes (y)', bytes: 'y\r', isPrimary: true),
      ApprovalChoice(label: 'No (n)', bytes: 'n\r', isDestructive: true),
      ApprovalChoice(label: 'Esc', bytes: '\x1b'),
    ];
  } else {
    choices = const <ApprovalChoice>[
      ApprovalChoice(label: 'Yes (y)', bytes: 'y\r', isPrimary: true),
      ApprovalChoice(label: 'Always (a)', bytes: 'a\r'),
      ApprovalChoice(label: 'No (n)', bytes: 'n\r', isDestructive: true),
      ApprovalChoice(label: 'Esc', bytes: '\x1b'),
    ];
  }

  final signature =
      '$reason|${choices.map((c) => '${c.label}:${c.bytes}').join(',')}';
  return ApprovalPromptState(
    reason: reason,
    choices: choices,
    signature: signature,
  );
}
