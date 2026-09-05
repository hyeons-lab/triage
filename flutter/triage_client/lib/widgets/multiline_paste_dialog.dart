import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:triage_client/terminal/terminal_paste.dart';

/// Shows a confirmation dialog when pasting multi-line text into a session where
/// bracketed paste mode is disabled.
///
/// Returns:
/// - The original multi-line [text] if the user chooses "Paste (Execute Commands)".
/// - The flattened single-line text if the user chooses "Paste as Single Line".
/// - `null` if the user cancels or dismisses the dialog.
Future<String?> showMultiLinePasteDialog(BuildContext context, String text) {
  final lines = lineCount(text);
  final previewLines = text.split(RegExp(r'\r\n|\r|\n'));
  final displayCount = math.min(previewLines.length, 6);
  final previewSnippet =
      previewLines.take(displayCount).join('\n') +
      (previewLines.length > displayCount
          ? '\n... (${previewLines.length - displayCount} more lines)'
          : '');

  final byteCount = text.length;
  final sizeLabel = byteCount < 1024
      ? '$byteCount B'
      : '${(byteCount / 1024).toStringAsFixed(1)} KB';

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xff161b1d),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Color(0xffffb86c), size: 22),
          SizedBox(width: 8),
          Text(
            'Multi-Line Paste Warning',
            style: TextStyle(
              color: Color(0xffd9e5e3),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The active shell does not have bracketed paste enabled. Pasting $lines lines ($sizeLabel) will execute commands line by line.',
              style: const TextStyle(color: Color(0xffa2b4b1), fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xff0d1112),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xff232c2f)),
              ),
              child: Text(
                previewSnippet,
                style: const TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 11,
                  color: Color(0xff7fd1c7),
                ),
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text(
            'Cancel',
            style: TextStyle(color: Color(0xffa2b4b1)),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(flattenToSingleLine(text)),
          child: const Text(
            'Paste as Single Line',
            style: TextStyle(color: Color(0xff7fd1c7)),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(text),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xff2b6a63),
          ),
          child: const Text(
            'Paste (Execute Commands)',
            style: TextStyle(color: Color(0xffd9e5e3)),
          ),
        ),
      ],
    ),
  );
}
