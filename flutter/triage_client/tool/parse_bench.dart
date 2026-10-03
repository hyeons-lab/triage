// Phase −1 gate: headless 1 MiB / 256 KiB replay comparison of the xterm 4.0
// fork (status quo) vs xterm2 5.2.0. Pure Dart: `dart tool/parse_bench.dart`
// (JIT) or AOT via `dart compile exe tool/parse_bench.dart`.
//
// Payload mimics daemon replay bytes: SGR-heavy agent output with CRLF line
// endings, 256-color segments, box drawing, and occasional wide chars.
// ignore_for_file: avoid_print
import 'dart:math';

import 'package:xterm/core.dart' as xterm4;
import 'package:xterm2/core.dart' as xterm2;

import 'bench_payload.dart';

const int kMaxLines = 50000; // matches the product's native Terminal
const int kChunkBytes = 8 * 1024;

double _median(List<double> xs) {
  final sorted = List<double>.of(xs)..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

void _runArm({
  required String label,
  required String payload,
  required int Function() makeTerminalAndWrite,
  required int rounds,
}) {
  // Warmup (JIT + first-trim paths), then interleaved-by-caller rounds.
  makeTerminalAndWrite();
  final times = <double>[];
  for (var r = 0; r < rounds; r++) {
    final sw = Stopwatch()..start();
    final lines = makeTerminalAndWrite();
    sw.stop();
    if (lines < 100) throw StateError('$label wrote only $lines lines');
    times.add(sw.elapsedMicroseconds / 1000.0);
  }
  final med = _median(times);
  final mibPerSec = (payload.length / (1024 * 1024)) / (med / 1000.0);
  print(
    '$label: median ${med.toStringAsFixed(1)} ms '
    '(${mibPerSec.toStringAsFixed(1)} MiB/s) over $rounds rounds',
  );
}

void _benchSize(int sizeBytes, int rounds) {
  final payload = buildBenchPayload(sizeBytes);
  print('--- ${(sizeBytes / 1024).round()} KiB payload (${payload.length} chars) ---');
  _runArm(
    label: 'xterm4 one-shot ',
    payload: payload,
    rounds: rounds,
    makeTerminalAndWrite: () {
      final t = xterm4.Terminal(maxLines: kMaxLines);
      t.write(payload);
      return t.mainBuffer.lines.length;
    },
  );
  _runArm(
    label: 'xterm2 one-shot ',
    payload: payload,
    rounds: rounds,
    makeTerminalAndWrite: () {
      final t = xterm2.Terminal(maxLines: kMaxLines);
      t.write(payload);
      return t.mainBuffer.lines.length;
    },
  );
  _runArm(
    label: 'xterm4 chunked  ',
    payload: payload,
    rounds: rounds,
    makeTerminalAndWrite: () {
      final t = xterm4.Terminal(maxLines: kMaxLines);
      for (var i = 0; i < payload.length; i += kChunkBytes) {
        final end = min(i + kChunkBytes, payload.length);
        t.write(payload.substring(i, end));
      }
      return t.mainBuffer.lines.length;
    },
  );
  _runArm(
    label: 'xterm2 chunked  ',
    payload: payload,
    rounds: rounds,
    makeTerminalAndWrite: () {
      final t = xterm2.Terminal(maxLines: kMaxLines);
      for (var i = 0; i < payload.length; i += kChunkBytes) {
        final end = min(i + kChunkBytes, payload.length);
        t.write(payload.substring(i, end));
      }
      return t.mainBuffer.lines.length;
    },
  );
}

void main() {
  _benchSize(256 * 1024, 5);
  _benchSize(1024 * 1024, 3);
}
