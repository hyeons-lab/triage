import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/daemon_host_stats.dart';

void main() {
  test('formats cpu and battery with charge state', () {
    expect(
      formatHostStats(
        cpuPercent: 12,
        batteryPercent: 87,
        batteryState: 'charging',
      ),
      'CPU 12% · Battery 87% (charging)',
    );
  });

  test('formats each state suffix', () {
    expect(
      formatHostStats(batteryPercent: 42, batteryState: 'discharging'),
      'Battery 42% (discharging)',
    );
    expect(
      formatHostStats(batteryPercent: 100, batteryState: 'full'),
      'Battery 100% (full)',
    );
    expect(
      formatHostStats(batteryPercent: 87, batteryState: 'unknown'),
      'Battery 87%',
    );
  });

  test('hides unknown legs independently', () {
    expect(formatHostStats(cpuPercent: 12), 'CPU 12%');
    expect(
      formatHostStats(batteryPercent: 87, batteryState: 'charging'),
      'Battery 87% (charging)',
    );
    expect(formatHostStats(), isNull);
  });

  test('out-of-range percents hide their leg', () {
    expect(
      formatHostStats(cpuPercent: -1, batteryPercent: 87),
      'Battery 87%',
    );
    expect(formatHostStats(cpuPercent: 101), isNull);
    expect(formatHostStats(batteryPercent: 101), isNull);
  });
}
