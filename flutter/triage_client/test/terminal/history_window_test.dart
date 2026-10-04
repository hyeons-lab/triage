import 'package:flutter_test/flutter_test.dart';

import 'package:triage_client/terminal/terminal_store.dart';

void main() {
  group('nextHistoryWindowBytes', () {
    test('doubles toward the platform budget', () {
      expect(
        nextHistoryWindowBytes(current: 64 * 1024, max: 1024 * 1024),
        128 * 1024,
      );
    });

    test('caps at the platform budget', () {
      expect(
        nextHistoryWindowBytes(current: 768 * 1024, max: 1024 * 1024),
        1024 * 1024,
      );
      expect(
        nextHistoryWindowBytes(current: 1024 * 1024, max: 1024 * 1024),
        1024 * 1024,
      );
    });

    test('repairs a non-positive window with the first page', () {
      expect(nextHistoryWindowBytes(current: 0, max: 256 * 1024), 64 * 1024);
      expect(nextHistoryWindowBytes(current: -8, max: 4096), 4096);
    });
  });
}
