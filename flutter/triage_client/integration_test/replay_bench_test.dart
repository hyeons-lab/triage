// Widget bench: TCG1 frame sync and RenderTerminalGrid paint times.
// Run profile-mode via flutter drive:
//   flutter drive --driver=test_driver/replay_bench_driver.dart \
//     --target=integration_test/replay_bench_test.dart --profile -d <device>
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/terminal/terminal_cell_protocol.dart';
import 'package:triage_client/widgets/terminal_grid_render_box.dart';

import '../tool/bench_payload.dart';

const int kBenchCols = 100;
const int kBenchViewportRows = 36;
const int kBenchScrollbackRows = 512;

Future<void> _benchArm(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  String reportKey,
  Widget Function() buildView,
  void Function() applyFrame,
) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: buildView())));
  await tester.pumpAndSettle();
  try {
    await binding.traceAction(() async {
      final sw = Stopwatch()..start();
      applyFrame();
      sw.stop();
      // ignore: avoid_print
      print('$reportKey ui_thread_sync_ms=${sw.elapsedMicroseconds / 1000.0}');
      await tester.pumpAndSettle();
    }, reportKey: reportKey);
  } finally {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pumpAndSettle();
  }
}

Widget _sizedView(TerminalCellBuffer buffer, ScrollController scroll) => Center(
  child: SizedBox(
    width: 800,
    height: 600,
    child: TerminalGridView(
      buffer: buffer,
      scrollController: scroll,
    ),
  ),
);

TerminalSyncFrameData _makeSyncFrame(
  Uint8List viewportPayload,
  Uint8List scrollbackPayload,
  int scrollbackRows,
) {
  return TerminalSyncFrameData(
    frameSeq: 1,
    rows: kBenchViewportRows,
    cols: kBenchCols,
    totalScrollbackRows: scrollbackRows,
    trimmedTopRows: 0,
    eraseScrollbackGen: 0,
    cursorX: 0,
    cursorY: kBenchViewportRows - 1,
    cursorStyle: 0,
    modeFlags: kModeFullViewport | kModeCursorVisible,
    mouseMode: 0,
    mouseReportMode: 0,
    kittyKeyboardFlags: 0,
    title: null,
    viewportCompression: kCellCompressionNone,
    viewportPayload: viewportPayload,
    pushedScrollbackStartRow: 0,
    pushedScrollbackRowCount: scrollbackRows,
    pushedScrollbackCompression: kCellCompressionNone,
    pushedScrollbackPayload: scrollbackPayload,
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final viewportPayload = encodeTcg1PlainTextRows(
    buildBenchLines(kBenchViewportRows, cols: kBenchCols),
    cols: kBenchCols,
  );
  final scrollbackPayload = encodeTcg1PlainTextRows(
    buildBenchLines(kBenchScrollbackRows, cols: kBenchCols),
    cols: kBenchCols,
  );

  testWidgets('warmup', (tester) async {
    final buffer = TerminalCellBuffer(
      cols: kBenchCols,
      rows: kBenchViewportRows,
    );
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _sizedView(buffer, scroll))),
    );
    buffer.applySyncFrame(
      _makeSyncFrame(viewportPayload, Uint8List(0), 0),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pumpAndSettle();
  });

  testWidgets('sync frames: terminal_grid (a)', (tester) async {
    final buffer = TerminalCellBuffer(
      cols: kBenchCols,
      rows: kBenchViewportRows,
    );
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _benchArm(
      tester,
      binding,
      'terminal_grid_sync_a',
      () => _sizedView(buffer, scroll),
      () => buffer.applySyncFrame(
        _makeSyncFrame(viewportPayload, scrollbackPayload, kBenchScrollbackRows),
      ),
    );
    expect(buffer.totalLines, kBenchViewportRows + kBenchScrollbackRows);
  });

  testWidgets('sync frames: terminal_grid (b)', (tester) async {
    final buffer = TerminalCellBuffer(
      cols: kBenchCols,
      rows: kBenchViewportRows,
    );
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _benchArm(
      tester,
      binding,
      'terminal_grid_sync_b',
      () => _sizedView(buffer, scroll),
      () => buffer.applySyncFrame(
        _makeSyncFrame(viewportPayload, scrollbackPayload, kBenchScrollbackRows),
      ),
    );
    expect(buffer.totalLines, kBenchViewportRows + kBenchScrollbackRows);
  });
}
