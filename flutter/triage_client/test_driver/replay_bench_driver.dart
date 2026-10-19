// Perf driver for the Phase −1 replay bench: summarizes each traceAction
// timeline and prints the JSON for the record.
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final missing = <String>[];
    for (final key in [
      'xterm4_replay_256k_a',
      'xterm2_replay_256k_a',
      'xterm2_replay_256k_b',
      'xterm4_replay_256k_b',
    ]) {
      final raw = data?[key];
      if (raw is! Map<String, dynamic>) {
        print('MISSING_TIMELINE: $key (keys: ${data?.keys.toList()})');
        missing.add(key);
        continue;
      }
      final summary = TimelineSummary.summarize(Timeline.fromJson(raw));
      await summary.writeTimelineToFile(key, pretty: true);
      print('=== $key ===');
      print(const JsonEncoder.withIndent('  ').convert(summary.summaryJson));
    }
    if (missing.isNotEmpty) {
      throw StateError('Missing benchmark timelines: ${missing.join(', ')}');
    }
  },
);
