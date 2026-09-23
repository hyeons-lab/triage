import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/size_drift.dart';

void main() {
  test('matching grid and host is not drift', () {
    expect(
      terminalSizesDrifted(aCols: 110, aRows: 30, bCols: 110, bRows: 30),
      isFalse,
    );
  });

  test('narrow grid under a wider host is drift', () {
    // The diagnosed stuck state: a 46-col fit applied locally while the PTY
    // sits at 80.
    expect(
      terminalSizesDrifted(aCols: 46, aRows: 20, bCols: 80, bRows: 24),
      isTrue,
    );
  });

  test('rows-only mismatch is drift', () {
    expect(
      terminalSizesDrifted(aCols: 80, aRows: 20, bCols: 80, bRows: 24),
      isTrue,
    );
  });

  test('unknown grid or host stays quiet', () {
    expect(
      terminalSizesDrifted(aCols: null, aRows: 20, bCols: 80, bRows: 24),
      isFalse,
    );
    expect(
      terminalSizesDrifted(aCols: 46, aRows: 20, bCols: null, bRows: null),
      isFalse,
    );
    expect(
      // hostCols-null with hostRows present: pins the hostCols guard slot,
      // which the both-null case above would mask on its own.
      terminalSizesDrifted(aCols: 46, aRows: 20, bCols: null, bRows: 24),
      isFalse,
    );
  });

  test('cols-only mismatch is drift', () {
    // Mirror of the rows-only case: the diagnosed stuck state differs in
    // cols (46 vs 80), so the cols leg must be pinned independently.
    expect(
      terminalSizesDrifted(aCols: 46, aRows: 24, bCols: 80, bRows: 24),
      isTrue,
    );
  });

  test('null rows stay quiet', () {
    expect(
      terminalSizesDrifted(aCols: 46, aRows: null, bCols: 80, bRows: 24),
      isFalse,
    );
    expect(
      terminalSizesDrifted(aCols: 46, aRows: 20, bCols: 80, bRows: null),
      isFalse,
    );
  });

  test('cached grid wrapper reads (rows, cols) in order', () {
    // (80, 24) against an 80-col, 24-row host is drift only when $1 is rows
    // and $2 is cols; a swapped read matches both dimensions and stays quiet.
    expect(
      cachedGridDriftedFromHost(
        gridRowsCols: (80, 24),
        hostCols: 80,
        hostRows: 24,
      ),
      isTrue,
    );
    expect(
      cachedGridDriftedFromHost(
        gridRowsCols: (24, 80),
        hostCols: 80,
        hostRows: 24,
      ),
      isFalse,
    );
    expect(
      cachedGridDriftedFromHost(gridRowsCols: null, hostCols: 80, hostRows: 24),
      isFalse,
    );
  });
}
