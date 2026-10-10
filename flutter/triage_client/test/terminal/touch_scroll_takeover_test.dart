import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/touch_scroll_takeover.dart';

void main() {
  TouchScrollTakeover takeover() => TouchScrollTakeover(quietWindowMs: 120);

  int move(
    TouchScrollTakeover t,
    int nowMs,
    double y, {
    double rowPx = 20,
    bool canDrive = true,
  }) => t.onPointerMove(nowMs: nowMs, y: y, rowPx: rowPx, canDrive: canDrive);

  test('first move anchors without scrolling', () {
    final t = takeover();
    t.onPointerDown(1000);
    expect(move(t, 1010, 250), 0);
  });

  test('drag down scrolls toward older lines', () {
    final t = takeover();
    t.onPointerDown(1000);
    expect(move(t, 1010, 250), 0);
    expect(move(t, 1020, 290), -2);
  });

  test('drag up scrolls toward newer lines', () {
    final t = takeover();
    t.onPointerDown(1000);
    expect(move(t, 1010, 250), 0);
    expect(move(t, 1020, 210), 2);
  });

  test('sub-row movement accumulates across moves', () {
    final t = takeover();
    t.onPointerDown(1000);
    expect(move(t, 1010, 250), 0);
    expect(move(t, 1020, 262), 0);
    expect(move(t, 1030, 274), -1);
  });

  test('yields while xterm touch path is alive', () {
    final t = takeover();
    t.onPointerDown(1000);
    expect(move(t, 1010, 250), 0);
    t.onTouchMove(1015);
    expect(move(t, 1020, 350), 0);
    t.onTouchMove(1025);
    expect(move(t, 1030, 450), 0);
  });

  test('takes over once the touch stream goes quiet', () {
    final t = takeover();
    t.onPointerDown(1000);
    expect(move(t, 1010, 250), 0);
    t.onTouchMove(1015);
    expect(move(t, 1020, 300), 0);
    // 120ms after the last touchmove the stream is dead: the same drag
    // continues from the live anchor with no jump.
    expect(move(t, 1135, 350), -2);
    expect(move(t, 1145, 390), -2);
  });

  test('carry resets while yielding so takeover starts clean', () {
    final t = takeover();
    t.onPointerDown(1000);
    expect(move(t, 1010, 250), 0);
    expect(move(t, 1020, 262), 0); // -0.6 rows carried
    t.onTouchMove(1025);
    expect(move(t, 1030, 300), 0); // xterm owns it; carry dropped
    expect(move(t, 1150, 312), 0); // -0.6 from the live anchor only
    expect(move(t, 1160, 324), -1);
  });

  test('canDrive false tracks the anchor without scrolling', () {
    final t = takeover();
    t.onPointerDown(1000);
    expect(move(t, 1010, 250), 0);
    expect(move(t, 1020, 350, canDrive: false), 0);
    expect(move(t, 1030, 370), -1);
  });

  test('non-positive row height scrolls nothing', () {
    final t = takeover();
    t.onPointerDown(1000);
    expect(move(t, 1010, 250), 0);
    expect(move(t, 1020, 350, rowPx: 0), 0);
  });

  test('pointer down resets the gesture', () {
    final t = takeover();
    t.onPointerDown(1000);
    expect(move(t, 1010, 250), 0);
    expect(move(t, 1020, 262), 0);
    t.onTouchMove(1025);
    t.onPointerDown(2000);
    expect(move(t, 2010, 400), 0);
    expect(move(t, 2020, 440), -2);
  });
}
