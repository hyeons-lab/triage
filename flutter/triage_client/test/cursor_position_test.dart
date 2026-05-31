import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/widgets/terminal_replay.dart';

StyledRow row(String text) => StyledRow(
  spans: [StyledSpan(text: text, style: const TerminalStyle())],
);

List<StyledRow> rowsWithPrompt(int length, int promptRow) {
  return [
    for (var i = 0; i < length; i++)
      row(i == promptRow ? r'prompt$ ' : 'line $i'),
  ];
}

void main() {
  group('Cursor Viewport-Relative Coordinate Mapping Tests', () {
    test(
      'standard layout - fallbackRows length matches fittedRows exactly',
      () {
        final placement = computeReplayCursorPlacement(
          fallbackRows: rowsWithPrompt(27, 20),
          fittedRows: 27,
          initialCursorRow: 20,
          initialCursorCol: 0,
        );
        expect(placement.terminalRow, equals(21));
      },
    );

    test(
      'scrollback layout - fallbackRows length is larger than fittedRows',
      () {
        final placement = computeReplayCursorPlacement(
          fallbackRows: rowsWithPrompt(100, 93),
          fittedRows: 40,
          initialCursorRow: 93,
          initialCursorCol: 0,
        );
        expect(placement.startRow, equals(60));
        expect(placement.terminalRow, equals(34));
      },
    );

    test('short layout - fallbackRows length is smaller than fittedRows', () {
      final placement = computeReplayCursorPlacement(
        fallbackRows: rowsWithPrompt(10, 5),
        fittedRows: 40,
        initialCursorRow: 5,
        initialCursorCol: 0,
      );
      expect(placement.startRow, equals(0));
      expect(placement.terminalRow, equals(6));
    });

    test(
      'cursor shifted layout - cursor is far above the bottom of scrollback',
      () {
        final placement = computeReplayCursorPlacement(
          fallbackRows: rowsWithPrompt(100, 50),
          fittedRows: 24,
          initialCursorRow: 50,
          initialCursorCol: 0,
        );
        expect(placement.startRow, equals(50));
        expect(placement.terminalRow, equals(1));
      },
    );

    test('clamping safety - absolute row is out of bounds (high)', () {
      final placement = computeReplayCursorPlacement(
        fallbackRows: rowsWithPrompt(100, 99),
        fittedRows: 40,
        initialCursorRow: 200,
        initialCursorCol: 0,
      );
      expect(placement.sourceRow, equals(99));
      expect(placement.terminalRow, equals(40));
    });

    test('clamping safety - absolute row is out of bounds (low)', () {
      final placement = computeReplayCursorPlacement(
        fallbackRows: rowsWithPrompt(10, 9),
        fittedRows: 40,
        initialCursorRow: -5,
        initialCursorCol: 0,
      );
      expect(placement.sourceRow, equals(9));
      expect(placement.terminalRow, equals(10));
    });

    test('replay placement keeps prompt cursor visible above stale rows', () {
      final fallbackRows = [
        const StyledRow(
          spans: [
            StyledSpan(text: 'Antigravity CLI 1.0.2', style: TerminalStyle()),
          ],
        ),
        const StyledRow(
          spans: [
            StyledSpan(
              text:
                  '/mnt/c/Users/iamst/development-windows/argus/worktrees/fix-terminal-layout',
              style: TerminalStyle(),
            ),
          ],
        ),
        const StyledRow(
          spans: [StyledSpan(text: '>', style: TerminalStyle())],
        ),
        const StyledRow(
          spans: [
            StyledSpan(
              text: r'dberrios@rogflowz13:/mnt/c/Users/iamst$ ',
              style: TerminalStyle(),
            ),
          ],
        ),
        const StyledRow(spans: []),
        const StyledRow(spans: []),
        const StyledRow(spans: []),
        const StyledRow(spans: []),
      ];

      final placement = computeReplayCursorPlacement(
        fallbackRows: fallbackRows,
        fittedRows: 6,
        initialCursorRow: 7,
        initialCursorCol: 0,
      );

      expect(placement.sourceRow, equals(3));
      expect(placement.sourceCol, equals(40));
      expect(placement.startRow, equals(2));
      expect(placement.terminalRow, equals(2));
      expect(placement.terminalCol, equals(41));
    });

    test('replay placement uses prompt row when cursor snapshot is absent', () {
      final fallbackRows = [
        const StyledRow(
          spans: [StyledSpan(text: 'header', style: TerminalStyle())],
        ),
        const StyledRow(
          spans: [
            StyledSpan(text: r'dberrios@host:/tmp$ ', style: TerminalStyle()),
          ],
        ),
        const StyledRow(spans: []),
      ];

      final placement = computeReplayCursorPlacement(
        fallbackRows: fallbackRows,
        fittedRows: 5,
      );

      expect(placement.sourceRow, equals(1));
      expect(placement.sourceCol, equals(20));
      expect(placement.terminalRow, equals(2));
      expect(placement.terminalCol, equals(21));
    });

    test('replay placement clamps status-row cursor to prompt row', () {
      final fallbackRows = [
        const StyledRow(
          spans: [StyledSpan(text: 'Antigravity CLI', style: TerminalStyle())],
        ),
        const StyledRow(
          spans: [StyledSpan(text: '>', style: TerminalStyle())],
        ),
        const StyledRow(
          spans: [StyledSpan(text: '? for shortcuts', style: TerminalStyle())],
        ),
      ];

      final placement = computeReplayCursorPlacement(
        fallbackRows: fallbackRows,
        fittedRows: 5,
        initialCursorRow: 2,
        initialCursorCol: 0,
      );

      expect(placement.sourceRow, equals(1));
      expect(placement.sourceCol, equals(1));
      expect(placement.terminalRow, equals(2));
      expect(placement.terminalCol, equals(2));
    });

    test('replay placement moves before-prompt cursor after prompt marker', () {
      final fallbackRows = [
        const StyledRow(
          spans: [StyledSpan(text: '>', style: TerminalStyle())],
        ),
      ];

      final placement = computeReplayCursorPlacement(
        fallbackRows: fallbackRows,
        fittedRows: 5,
        initialCursorRow: 0,
        initialCursorCol: 0,
      );

      expect(placement.sourceRow, equals(0));
      expect(placement.sourceCol, equals(1));
      expect(placement.terminalRow, equals(1));
      expect(placement.terminalCol, equals(2));
    });
  });

  group('Trailing Whitespace Trimming Tests', () {
    test('trims trailing whitespace spans completely', () {
      final row = StyledRow(
        spans: [
          const StyledSpan(text: 'Hello', style: TerminalStyle()),
          const StyledSpan(text: '   ', style: TerminalStyle()),
        ],
      );
      final trimmed = trimReplayTrailingWhitespace(row);
      expect(trimmed.spans.length, equals(1));
      expect(trimmed.spans[0].text, equals('Hello'));
    });

    test('trims whitespace from the end of the last span', () {
      final row = StyledRow(
        spans: [const StyledSpan(text: 'Hello   ', style: TerminalStyle())],
      );
      final trimmed = trimReplayTrailingWhitespace(row);
      expect(trimmed.spans.length, equals(1));
      expect(trimmed.spans[0].text, equals('Hello'));
    });

    test('leaves non-trailing whitespace spans untouched', () {
      final row = StyledRow(
        spans: [const StyledSpan(text: 'Hello World', style: TerminalStyle())],
      );
      final trimmed = trimReplayTrailingWhitespace(row);
      expect(trimmed.spans.length, equals(1));
      expect(trimmed.spans[0].text, equals('Hello World'));
    });

    test('handles empty row safely', () {
      final row = StyledRow(spans: []);
      final trimmed = trimReplayTrailingWhitespace(row);
      expect(trimmed.spans, isEmpty);
    });

    test('normalizes terminal padding before shell prompt-only rows', () {
      final normalized = normalizeReplayRow(
        row(
          r'                                        dberrios@rogflowz13:/mnt/c/Users/iamst$ ',
        ),
      );

      expect(
        normalized.spans.map((span) => span.text).join(),
        r'dberrios@rogflowz13:/mnt/c/Users/iamst$',
      );
    });

    test('keeps leading indentation for ordinary output rows', () {
      final normalized = normalizeReplayRow(row('    total cost \$3'));

      expect(
        normalized.spans.map((span) => span.text).join(),
        '    total cost \$3',
      );
    });
  });

  group('Cursor Repositioning and Clamping Tests', () {
    test(
      'repositions cursor to last non-empty row when cursor is on empty lines',
      () {
        final fallbackRows = [
          const StyledRow(
            spans: [StyledSpan(text: 'line 1', style: TerminalStyle())],
          ),
          const StyledRow(
            spans: [StyledSpan(text: r'prompt$', style: TerminalStyle())],
          ),
          const StyledRow(
            spans: [StyledSpan(text: '   ', style: TerminalStyle())],
          ), // effectively empty
          const StyledRow(spans: []), // empty
        ];

        final result = computeReplayCursorPlacement(
          initialCursorRow: 3,
          initialCursorCol: 40,
          fallbackRows: fallbackRows,
          fittedRows: 10,
        );

        expect(result.sourceRow, equals(1));
        expect(result.sourceCol, equals(7)); // length of 'prompt$'
      },
    );

    test(
      'does not count terminal padding after non-terminal prompt marker',
      () {
        final fallbackRows = [
          const StyledRow(
            spans: [StyledSpan(text: 'line 1', style: TerminalStyle())],
          ),
          const StyledRow(
            spans: [
              StyledSpan(text: r'> prompt        ', style: TerminalStyle()),
            ],
          ),
          const StyledRow(spans: []),
        ];

        final result = computeReplayCursorPlacement(
          initialCursorRow: 2,
          initialCursorCol: 40,
          fallbackRows: fallbackRows,
          fittedRows: 10,
        );

        expect(result.sourceRow, equals(1));
        expect(result.sourceCol, equals(8)); // length of '> prompt'
      },
    );

    test(
      'preserves one prompt space when padding hides a trailing shell prompt space',
      () {
        final fallbackRows = [
          const StyledRow(
            spans: [StyledSpan(text: r'$        ', style: TerminalStyle())],
          ),
          const StyledRow(spans: []),
        ];

        final result = computeReplayCursorPlacement(
          initialCursorRow: 1,
          initialCursorCol: 40,
          fallbackRows: fallbackRows,
          fittedRows: 10,
        );

        expect(result.sourceRow, equals(0));
        expect(result.sourceCol, equals(2)); // '$ '
      },
    );

    test(
      'repositions cursor to prompt row instead of non-prompt status row',
      () {
        final fallbackRows = [
          const StyledRow(
            spans: [StyledSpan(text: 'line 1', style: TerminalStyle())],
          ),
          const StyledRow(
            spans: [StyledSpan(text: r'> prompt', style: TerminalStyle())],
          ),
          const StyledRow(
            spans: [
              StyledSpan(text: '? for shortcuts', style: TerminalStyle()),
            ],
          ),
        ];

        final result = computeReplayCursorPlacement(
          initialCursorRow: 2,
          initialCursorCol: 10,
          fallbackRows: fallbackRows,
          fittedRows: 10,
        );

        expect(result.sourceRow, equals(1));
        expect(result.sourceCol, equals(8)); // length of '> prompt'
      },
    );

    test('does not reposition cursor when cursor is on/above active row', () {
      final fallbackRows = [
        const StyledRow(
          spans: [StyledSpan(text: 'line 1', style: TerminalStyle())],
        ),
        const StyledRow(
          spans: [StyledSpan(text: r'prompt$', style: TerminalStyle())],
        ),
        const StyledRow(spans: []),
      ];

      final result = computeReplayCursorPlacement(
        initialCursorRow: 1,
        initialCursorCol: 7,
        fallbackRows: fallbackRows,
        fittedRows: 10,
      );

      expect(result.sourceRow, equals(1));
      expect(result.sourceCol, equals(7));
    });

    test(
      'does not clamp if there is an active editor (non-empty/non-status text below prompt)',
      () {
        final fallbackRows = [
          const StyledRow(
            spans: [StyledSpan(text: r'prompt$', style: TerminalStyle())],
          ),
          const StyledRow(
            spans: [
              StyledSpan(text: 'real editor text here', style: TerminalStyle()),
            ],
          ),
          const StyledRow(spans: []),
        ];

        final result = computeReplayCursorPlacement(
          initialCursorRow: 2,
          initialCursorCol: 10,
          fallbackRows: fallbackRows,
          fittedRows: 10,
        );

        expect(result.sourceRow, equals(2));
        expect(result.sourceCol, equals(10));
      },
    );

    test(
      'does not clamp cursor when all fallbackRows are empty or whitespace-only',
      () {
        final fallbackRows = [
          const StyledRow(spans: []),
          const StyledRow(spans: []),
          const StyledRow(spans: []),
          const StyledRow(spans: []),
          const StyledRow(spans: []),
          const StyledRow(spans: []),
          const StyledRow(spans: []),
          const StyledRow(spans: []),
        ];

        final result = computeReplayCursorPlacement(
          initialCursorRow: 6,
          initialCursorCol: 0,
          fallbackRows: fallbackRows,
          fittedRows: 8,
        );

        expect(result.sourceRow, equals(6));
        expect(result.sourceCol, equals(0));
        expect(result.terminalRow, equals(7));
        expect(result.terminalCol, equals(1));
      },
    );
  });
}
