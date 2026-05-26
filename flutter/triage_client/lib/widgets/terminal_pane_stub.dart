import 'package:flutter/material.dart';
import 'package:triage_client/models/terminal_models.dart';
import 'terminal_pane.dart';

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.terminalId,
    required this.controller,
    required this.fallbackRows,
    this.initialCursorRow,
    this.initialCursorCol,
    this.isExited = false,
    this.replayRevision = 0,
    this.replayPending = false,
  });

  final String terminalId;
  final TerminalController controller;
  final List<StyledRow> fallbackRows;
  final int? initialCursorRow;
  final int? initialCursorCol;
  final bool isExited;
  final int replayRevision;
  final bool replayPending;

  static void destroySession(String terminalId) {
    // Stub implementation does nothing
  }

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xff0d1113),
      alignment: Alignment.topLeft,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final row in widget.fallbackRows)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: SelectableText.rich(
                  TextSpan(
                    children: [
                      for (final span in row.spans)
                        TextSpan(
                          text: span.text.isEmpty ? ' ' : span.text,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 15,
                            height: 1.35,
                            color:
                                span.style.foreground?.toColor() ??
                                const Color(0xffd9e5e3),
                            backgroundColor: span.style.background?.toColor(),
                            fontWeight: span.style.bold
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontStyle: span.style.italic
                                ? FontStyle.italic
                                : FontStyle.normal,
                            decoration: span.style.underline
                                ? TextDecoration.underline
                                : TextDecoration.none,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
