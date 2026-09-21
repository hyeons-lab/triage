import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/size_drift.dart';

void main() {
  test('matching grid and host is not drift', () {
    expect(
      liveGridDriftedFromHost(
        gridCols: 110,
        gridRows: 30,
        hostCols: 110,
        hostRows: 30,
      ),
      isFalse,
    );
  });

  test('narrow grid under a wider host is drift', () {
    // The diagnosed stuck state: a 46-col fit applied locally while the PTY
    // sits at 80.
    expect(
      liveGridDriftedFromHost(
        gridCols: 46,
        gridRows: 20,
        hostCols: 80,
        hostRows: 24,
      ),
      isTrue,
    );
  });

  test('single-dimension mismatch is drift', () {
    expect(
      liveGridDriftedFromHost(
        gridCols: 80,
        gridRows: 20,
        hostCols: 80,
        hostRows: 24,
      ),
      isTrue,
    );
  });

  test('unknown grid or host stays quiet', () {
    expect(
      liveGridDriftedFromHost(
        gridCols: null,
        gridRows: 20,
        hostCols: 80,
        hostRows: 24,
      ),
      isFalse,
    );
    expect(
      liveGridDriftedFromHost(
        gridCols: 46,
        gridRows: 20,
        hostCols: null,
        hostRows: null,
      ),
      isFalse,
    );
  });
}
