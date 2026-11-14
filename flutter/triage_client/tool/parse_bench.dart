// Headless TCG1 cell-batch decode and TerminalCellBuffer apply benchmark.
// Run with `flutter test tool/parse_bench.dart` inside flutter/triage_client.
// ignore_for_file: avoid_print
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';

import 'bench_payload.dart';

double _median(List<double> xs) {
  final sorted = List<double>.of(xs)..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

void _runArm({
  required String label,
  required int payloadBytes,
  required int Function() runOnce,
  required int rounds,
}) {
  runOnce();
  final times = <double>[];
  for (var r = 0; r < rounds; r++) {
    final sw = Stopwatch()..start();
    final rows = runOnce();
    sw.stop();
    if (rows < 24) {
      throw StateError('$label processed only $rows rows');
    }
    times.add(sw.elapsedMicroseconds / 1000.0);
  }
  final med = _median(times);
  final mibPerSec = (payloadBytes / (1024 * 1024)) / (med / 1000.0);
  print(
    '$label: median ${med.toStringAsFixed(2)} ms '
    '(${mibPerSec.toStringAsFixed(1)} MiB/s) over $rounds rounds',
  );
}

void _benchBatch({
  required int cols,
  required int viewportRows,
  required int scrollbackRows,
  required int rounds,
}) {
  final viewportLines = buildBenchLines(viewportRows, cols: cols);
  final scrollbackLines = buildBenchLines(scrollbackRows, cols: cols);
  final rawViewport = encodeTcg1PlainTextRows(viewportLines, cols: cols);
  final rawScrollback = encodeTcg1PlainTextRows(scrollbackLines, cols: cols);
  final zlibScrollback = Uint8List.fromList(
    const ZLibEncoder().encode(rawScrollback),
  );
  print(
    '=== ${cols}x$viewportRows viewport (${rawViewport.length} B) + '
    '$scrollbackRows scrollback rows (${rawScrollback.length} B raw, '
    '${zlibScrollback.length} B zlib) ===',
  );

  _runArm(
    label: 'TCG1 raw sync + scrollback ',
    payloadBytes: rawViewport.length + rawScrollback.length,
    rounds: rounds,
    runOnce: () {
      final buf = TerminalCellBuffer(cols: cols, rows: viewportRows);
      try {
        buf.applySyncFrame(
          TerminalSyncFrameData(
            frameSeq: 1,
            rows: viewportRows,
            cols: cols,
            totalScrollbackRows: scrollbackRows,
            trimmedTopRows: 0,
            eraseScrollbackGen: 0,
            cursorX: 0,
            cursorY: viewportRows - 1,
            cursorStyle: 0,
            modeFlags: kModeFullViewport | kModeCursorVisible,
            mouseMode: 0,
            mouseReportMode: 0,
            kittyKeyboardFlags: 0,
            title: null,
            viewportCompression: kCellCompressionNone,
            viewportPayload: rawViewport,
            pushedScrollbackStartRow: 0,
            pushedScrollbackRowCount: scrollbackRows,
            pushedScrollbackCompression: kCellCompressionNone,
            pushedScrollbackPayload: rawScrollback,
          ),
        );
        return buf.totalLines;
      } finally {
        buf.dispose();
      }
    },
  );

  _runArm(
    label: 'TCG1 zlib page decode      ',
    payloadBytes: rawScrollback.length,
    rounds: rounds,
    runOnce: () {
      final buf = TerminalCellBuffer(cols: cols, rows: viewportRows);
      try {
        buf.applyFetchedRows(
          TerminalRowsPageData(
            sessionId: 'bench',
            startRow: 0,
            rowCount: scrollbackRows,
            totalScrollbackRows: scrollbackRows,
            trimmedTopRows: 0,
            eraseScrollbackGen: 0,
            compression: kCellCompressionZlib,
            payload: zlibScrollback,
          ),
        );
        return buf.totalLines;
      } finally {
        buf.dispose();
      }
    },
  );
}

void main() {
  test('TCG1 cell-batch decode and TerminalCellBuffer apply benchmark', () {
    _benchBatch(cols: 120, viewportRows: 40, scrollbackRows: 512, rounds: 7);
    _benchBatch(cols: 120, viewportRows: 40, scrollbackRows: 2048, rounds: 5);
  });
}
