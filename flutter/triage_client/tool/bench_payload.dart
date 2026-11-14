// Shared deterministic benchmark payload generator for TCG1 cell sync benches.
// Importable from `tool/` and `integration_test/`.
import 'dart:math';

const List<String> kReplayBenchReportKeys = <String>[
  'terminal_grid_sync_a',
  'terminal_grid_sync_b',
];

List<String> buildBenchLines(int lineCount, {int cols = 120}) {
  final rng = Random(0xC0FFEE);
  const plain = <String>[
    'feat(client): daemon-authoritative dirty-row terminal cell sync',
    'Compiling triaged v0.3.0 (/Users/dev/triage/crates/triaged)',
    'Finished `release` profile [optimized] target(s) in 3m 12s',
    'tests::terminal_sync_dirty_row_diff_roundtrip ... ok',
    'note: virtual scrollback demand paging active across 128-row pages',
  ];
  const paths = <String>[
    'crates/triaged/src/session.rs',
    'flutter/triage_client/lib/terminal/terminal_cell_buffer.dart',
    'crates/triage-term/src/lib.rs',
  ];
  final lines = <String>[];
  for (var i = 0; i < lineCount; i++) {
    final kind = i % 10;
    String text;
    if (kind == 0) {
      text = '=== round ${i ~/ 10} ===';
    } else if (kind == 1) {
      text =
          '+ ${paths[i % paths.length]} ${rng.nextInt(9000) + 1000} insertions';
    } else if (kind == 2) {
      text = '- obsolete line with trailing detail | box -> 中文';
    } else if (kind == 3) {
      text = 'warning: unused symbol `foo` [${plain[i % plain.length]}]';
    } else {
      text = '${plain[i % plain.length]} #${rng.nextInt(1 << 30)}';
    }
    final runes = text.runes.toList();
    if (runes.length > cols) {
      text = String.fromCharCodes(runes.sublist(0, cols));
    }
    lines.add(text);
  }
  return lines;
}
