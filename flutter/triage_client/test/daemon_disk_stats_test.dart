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

  test('formats huge volumes with separators and percentage', () {
    // A formatting golden for the top end of the range: thousands separators
    // in the megabyte count plus the whole percent. (It cannot pin the
    // divide-before-scale formula shape: 95TB times 100 is exactly
    // representable in float64, so a multiply-first refactor stays green.)
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
