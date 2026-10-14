// Shared deterministic replay payload for the Phase −1 benches. Pure Dart;
// importable from `tool/` (relative) and `integration_test/` (relative).
import 'dart:math';

String buildBenchPayload(int targetBytes) {
  final rng = Random(0xC0FFEE);
  const plain = [
    'feat(client): reconcile stuck-narrow web terminal grid',
    'Compiling triaged v0.3.0 (/Users/dev/triage/crates/triaged)',
    'Finished `release` profile [optimized] target(s) in 3m 12s',
    'tests::snapshot_history_matches_the_served_tail_cap ... ok',
    'note: to see what the problems were, use --future-incompat-report',
  ];
  const paths = [
    'crates/triaged/src/session.rs',
    'flutter/triage_client/lib/terminal/terminal_store.dart',
    'crates/triage-core/src/session.rs',
  ];
  final buf = StringBuffer();
  var i = 0;
  while (buf.length < targetBytes) {
    final kind = i % 10;
    if (kind == 0) {
      buf.write('\x1b[1m\x1b[38;5;33m━━━ round ${i ~/ 10} ━━━\x1b[0m\r\n');
    } else if (kind == 1) {
      buf.write(
        '\x1b[32m+\x1b[0m ${paths[i % paths.length]} '
        '\x1b[2m${rng.nextInt(9000) + 1000} insertions\x1b[0m\r\n',
      );
    } else if (kind == 2) {
      buf.write('\x1b[31m-\x1b[0m obsolete line with \x1b[3mtrailing detail\x1b[0m │ box ── 中文\r\n');
    } else if (kind == 3) {
      buf.write('\x1b[38;5;214mwarning\x1b[0m: unused import `foo` [${plain[i % plain.length]}]\r\n');
    } else {
      buf.write('${plain[i % plain.length]} #${rng.nextInt(1 << 30)}\r\n');
    }
    i++;
  }
  final s = buf.toString();
  return s.length <= targetBytes ? s : s.substring(0, targetBytes);
}
