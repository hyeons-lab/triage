import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/widgets/terminal_scrollbar.dart';

void main() {
  testWidgets('TerminalScrollbar hides when maxScrollExtent <= 0', (
    tester,
  ) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalScrollbar(
            controller: controller,
            child: SingleChildScrollView(
              controller: controller,
              child: const SizedBox(height: 100),
            ),
          ),
        ),
      ),
    );

    // Initial pump with no scrollable overflow (content fits in 600px viewport)
    expect(find.byType(DecoratedBox), findsNothing);
  });

  testWidgets(
    'TerminalScrollbar renders thumb and supports dragging and tapping track',
    (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              width: 400,
              child: TerminalScrollbar(
                controller: controller,
                child: SingleChildScrollView(
                  controller: controller,
                  child: const SizedBox(height: 1500),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // With 1500px content in 300px height, maxScrollExtent = 1200. Thumb should be rendered.
      expect(controller.position.maxScrollExtent, 1200.0);
      expect(controller.offset, 0.0);
      expect(find.byType(DecoratedBox), findsWidgets);

      // Find the scrollbar GestureDetector
      final scrollbarFinder = find.byType(TerminalScrollbar);
      expect(scrollbarFinder, findsOneWidget);

      final scrollbarRect = tester.getRect(scrollbarFinder);
      final trackX = scrollbarRect.right - 7;

      // Drag the scrollbar thumb downwards
      await tester.dragFrom(
        Offset(trackX, scrollbarRect.top + 20),
        const Offset(0, 100),
      );
      await tester.pumpAndSettle();

      expect(controller.offset, greaterThan(0.0));

      // Tap near the bottom of the track (e.g. y = 280)
      await tester.tapAt(Offset(trackX, scrollbarRect.top + 280));
      await tester.pumpAndSettle();

      expect(controller.offset, greaterThan(500.0));
    },
  );
}
