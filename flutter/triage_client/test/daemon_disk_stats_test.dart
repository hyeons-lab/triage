import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/daemon_disk_stats.dart';

const _mb = 1024 * 1024;

void main() {
  test('formats megabytes free with free percentage', () {
    expect(
      formatDiskFree(12340 * _mb, 100 * 1000 * _mb),
      '12,340 MB free (12%)',
    );
  });

  test('rounds the percentage', () {
    expect(formatDiskFree(255 * _mb, 1000 * _mb), '255 MB free (26%)');
  });

  test('omits thousands separators under one thousand', () {
    expect(formatDiskFree(999 * _mb, 1000 * _mb), '999 MB free (100%)');
  });

  test('huge volumes keep an exact percentage', () {
    // The production formula divides before scaling so the intermediate
    // `freeBytes * 100` cannot lose precision on the web number type past
    // ~90TB free; this pins the formula shape (the VM integers used here
    // would stay exact either way).
    const tb = 1024 * 1024 * _mb;
    expect(formatDiskFree(95 * tb, 100 * tb), '99,614,720 MB free (95%)');
  });

  test('unknown figures hide the line', () {
    expect(formatDiskFree(0, 0), isNull);
    expect(formatDiskFree(100, 0), isNull);
    expect(formatDiskFree(-1, 100), isNull);
    expect(formatDiskFree(200, 100), isNull);
  });
}
