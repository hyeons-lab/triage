import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/copy_button_layout.dart';

void main() {
  const button = Size(104, 36);
  const viewport = Size(400, 600);
  const lineHeight = 18.0;

  // A single-line selection, the common case: it ends one line below its start.
  CopyButtonPlacement? place(Offset anchor, {Size view = viewport}) =>
      placeCopyButton(
        anchor: anchor,
        selectionBottom: anchor.dy + lineHeight,
        lineHeight: lineHeight,
        viewport: view,
        button: button,
      );

  group('placeCopyButton', () {
    test('sits above the selection, centred on it', () {
      final placement = place(const Offset(200, 300));
      // 300 - 36 - 6 = 258 above the anchor; 200 - 104/2 = 148 to centre it.
      expect(placement, const CopyButtonPlacement(148, 258));
    });

    test('flips below the line when the selection starts at the top', () {
      // Only 10px above the anchor: not enough for a 36px button plus its gap,
      // so it drops under the first line rather than off the top edge.
      final placement = place(const Offset(200, 10));
      expect(placement?.top, 10 + lineHeight + 6);
    });

    test('flips below at the exact boundary and not one pixel earlier', () {
      // 42 == button height + gap: the last anchor that still fits above.
      expect(place(const Offset(200, 42))?.top, 0);
      expect(place(const Offset(200, 41))?.top, 41 + lineHeight + 6);
    });

    test('clamps to the left edge rather than overflowing it', () {
      // Centring on x=10 would put the button at -42.
      expect(place(const Offset(10, 300))?.left, 0);
    });

    test('clamps to the right edge rather than overflowing it', () {
      // Centring on x=395 would run past the 400-wide viewport.
      expect(
        place(const Offset(395, 300))?.left,
        viewport.width - button.width,
      );
    });

    test('hides when the selection has scrolled above the viewport', () {
      // Ends above the top edge, so nothing of it is left to point at.
      expect(place(const Offset(200, -100)), isNull);
      expect(place(const Offset(200, -lineHeight)), isNull);
    });

    test('hides when the selection has scrolled past the bottom', () {
      expect(place(const Offset(200, 700)), isNull);
      // Exactly at the bottom edge: room remains above for the button, so the
      // fit check would place it and only the visibility check rejects it.
      expect(place(Offset(200, viewport.height)), isNull);
    });

    test('still shows for a selection just inside the bottom edge', () {
      // One pixel in is visible, so it gets a button (above, where there is
      // room) rather than being treated as scrolled away.
      expect(place(Offset(200, viewport.height - 1))?.top, 557);
    });

    test('hides when the viewport is too short to hold it either way', () {
      expect(place(const Offset(200, 5), view: const Size(400, 40)), isNull);
    });

    test('hides when the viewport is narrower than the button', () {
      expect(place(const Offset(20, 300), view: const Size(80, 600)), isNull);
    });

    group('multi-line selection scrolled off the top', () {
      // The case the button exists for: a long selection whose start has
      // scrolled away but whose body is still on screen.
      CopyButtonPlacement? placeSpanning(double top, double bottom) =>
          placeCopyButton(
            anchor: Offset(200, top),
            selectionBottom: bottom,
            lineHeight: lineHeight,
            viewport: viewport,
            button: button,
          );

      test('still offers a button, anchored to the visible top', () {
        // Starts 500px above the viewport, still covers most of it. Anchoring
        // to the real start would put the button off-screen and hide it.
        final placement = placeSpanning(-500, 400);
        expect(placement, isNotNull);
        // Nothing fits above the clamped top, so it sits below the first
        // visible line.
        expect(placement?.top, lineHeight + 6);
      });

      test('hides only once the whole selection is above the viewport', () {
        expect(placeSpanning(-500, 1), isNotNull);
        expect(placeSpanning(-500, 0), isNull);
      });
    });
  });
}
