import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/terminal/terminal_cell_buffer.dart';
import 'package:triage_client/widgets/terminal_accessory_bar.dart';
import 'package:triage_client/widgets/terminal_composer_bar.dart';
import 'package:triage_client/widgets/terminal_pane.dart';

void main() {
  const androidVariant = TargetPlatformVariant({TargetPlatform.android});

  Future<(TerminalController, TerminalCellBuffer, List<String>)>
  pumpNativeAndroidPane(
    WidgetTester tester, {
    bool pendingApproval = false,
    String? pendingApprovalReason,
    bool bracketedPasteEnabled = false,
  }) async {
    final previousForce = TerminalPane.debugForceNativeTerminalView;
    TerminalPane.debugForceNativeTerminalView = true;
    final controller = TerminalController();
    final terminal = TerminalCellBuffer(cols: 80, rows: 24);
    final sent = <String>[];
    void captureInput(String data) => sent.add(data);
    controller.addInputListener(captureInput);

    addTearDown(() {
      TerminalPane.debugForceNativeTerminalView = previousForce;
      controller.removeInputListener(captureInput);
      controller.dispose();
      terminal.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalPane(
            terminalId: 'composer-chips-test',
            controller: controller,
            terminal: terminal,
            fallbackRows: const [],
            onTerminalResizeBind: (_) {},
            bracketedPasteEnabled: bracketedPasteEnabled,
            pendingApproval: pendingApproval,
            pendingApprovalReason: pendingApprovalReason,
          ),
        ),
      ),
    );
    await tester.pump();
    return (controller, terminal, sent);
  }

  testWidgets('TerminalAccessoryBar renders compose toggle when wired', (
    WidgetTester tester,
  ) async {
    final sent = <String>[];
    var toggles = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TerminalAccessoryBar(
              onSend: sent.add,
              onToggleCtrl: () {},
              onPaste: () {},
              ctrlArmed: false,
              composeOpen: true,
              onToggleComposer: () => toggles++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('compose'));
    await tester.pump();
    expect(toggles, 1);
    expect(sent, isEmpty);
  });

  testWidgets(
    'composer bar toggles cleanly, preserves draft across close, and sends single and multiline drafts',
    variant: androidVariant,
    (WidgetTester tester) async {
      final (_, _, sent) = await pumpNativeAndroidPane(
        tester,
        bracketedPasteEnabled: true,
      );

      expect(find.byType(TerminalComposerBar), findsNothing);
      await tester.tap(find.text('compose'));
      await tester.pump();

      expect(find.byType(TerminalComposerBar), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'git status');
      await tester.pump();

      // Closing composer preserves draft for when it is reopened.
      await tester.tap(find.text('compose'));
      await tester.pump();
      expect(find.byType(TerminalComposerBar), findsNothing);

      await tester.tap(find.text('compose'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'git status',
      );

      // Sending single-line draft sends text + CR and clears the draft.
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(sent, ['git status\r']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      sent.clear();

      // Sending multiline draft wraps in bracketed paste and submits CR.
      await tester.enterText(find.byType(TextField), 'line one\nline two');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(sent, ['\x1b[200~line one\nline two\x1b[201~', '\r']);
    },
  );

  testWidgets(
    'approval chips appear for pending approval and send choice on tap',
    variant: androidVariant,
    (WidgetTester tester) async {
      final (_, _, sent) = await pumpNativeAndroidPane(
        tester,
        pendingApproval: true,
        pendingApprovalReason: 'Run migration? [y/N]',
      );

      expect(find.text('Run migration? [y/N]'), findsOneWidget);
      expect(find.text('Yes (y)'), findsOneWidget);
      expect(find.text('No (n)'), findsOneWidget);

      await tester.tap(find.text('Yes (y)'));
      await tester.pump();

      expect(sent, ['y\r']);
      // Dismisses immediately after tap so stale chips do not linger.
      expect(find.text('Yes (y)'), findsNothing);
    },
  );
}
