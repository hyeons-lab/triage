// Phase −1 widget bench: 256 KiB one-shot replay frame times for a visible
// TerminalView, xterm 4.0 fork vs xterm2. ABBA order: each arm runs twice so
// first-paint warmup (fonts, shaders) can't bias the comparison. Run
// profile-mode via flutter drive:
//   flutter drive --driver=test_driver/replay_bench_driver.dart \
//     --target=integration_test/replay_bench_test.dart --profile -d <device>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart' as xterm4;
import 'package:xterm2/xterm.dart' as xterm2;

import '../tool/bench_payload.dart';

const int kMaxLines = 50000;
const int kPayloadBytes = 256 * 1024;

Future<void> _benchArm(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  String reportKey,
  Widget Function() buildView,
  void Function() write,
) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: buildView())));
  await tester.pumpAndSettle();
  await binding.traceAction(() async {
    final sw = Stopwatch()..start();
    write();
    sw.stop();
    // ignore: avoid_print
    print('$reportKey ui_thread_write_ms=${sw.elapsedMicroseconds / 1000.0}');
    await tester.pumpAndSettle();
  }, reportKey: reportKey);
  // Tear down so the next arm starts from a clean tree.
  await tester.pumpWidget(const MaterialApp(home: Scaffold()));
  await tester.pumpAndSettle();
}

Widget _sizedView(Widget child) => Center(
  child: SizedBox(width: 800, height: 600, child: child),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final payload = buildBenchPayload(kPayloadBytes);

  testWidgets('warmup', (tester) async {
    // Unmeasured: pay font/shader/first-frame costs once, outside the traces.
    final terminal = xterm4.Terminal(maxLines: kMaxLines);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _sizedView(xterm4.TerminalView(terminal))),
      ),
    );
    terminal.write(payload.substring(0, 65536));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pumpAndSettle();
  });

  testWidgets('replay frames: xterm4 (a)', (tester) async {
    final terminal = xterm4.Terminal(maxLines: kMaxLines);
    await _benchArm(
      tester,
      binding,
      'xterm4_replay_256k_a',
      () => _sizedView(xterm4.TerminalView(terminal)),
      () => terminal.write(payload),
    );
    expect(terminal.mainBuffer.lines.length, greaterThan(100));
  });

  testWidgets('replay frames: xterm2 (a)', (tester) async {
    final terminal = xterm2.Terminal(maxLines: kMaxLines);
    await _benchArm(
      tester,
      binding,
      'xterm2_replay_256k_a',
      () => _sizedView(xterm2.TerminalView(terminal)),
      () => terminal.write(payload),
    );
    expect(terminal.mainBuffer.lines.length, greaterThan(100));
  });

  testWidgets('replay frames: xterm2 (b)', (tester) async {
    final terminal = xterm2.Terminal(maxLines: kMaxLines);
    await _benchArm(
      tester,
      binding,
      'xterm2_replay_256k_b',
      () => _sizedView(xterm2.TerminalView(terminal)),
      () => terminal.write(payload),
    );
    expect(terminal.mainBuffer.lines.length, greaterThan(100));
  });

  testWidgets('replay frames: xterm4 (b)', (tester) async {
    final terminal = xterm4.Terminal(maxLines: kMaxLines);
    await _benchArm(
      tester,
      binding,
      'xterm4_replay_256k_b',
      () => _sizedView(xterm4.TerminalView(terminal)),
      () => terminal.write(payload),
    );
    expect(terminal.mainBuffer.lines.length, greaterThan(100));
  });
}
