import 'package:triage_client/models/terminal_models.dart';

StyledRow trimReplayTrailingWhitespace(StyledRow row) {
  if (row.spans.isEmpty) return row;
  final newSpans = List<StyledSpan>.from(row.spans);
  while (newSpans.isNotEmpty) {
    final lastSpan = newSpans.last;
    final trimmedText = lastSpan.text.trimRight();
    if (trimmedText.isEmpty) {
      newSpans.removeLast();
    } else {
      newSpans[newSpans.length - 1] = StyledSpan(
        text: trimmedText,
        style: lastSpan.style,
      );
      break;
    }
  }
  return StyledRow(spans: newSpans);
}

StyledRow normalizeReplayRow(StyledRow row) {
  final trimmed = trimReplayTrailingWhitespace(row);
  final text = trimmed.spans.map((span) => span.text).join();
  final leadingWhitespace = RegExp(r'^\s+').firstMatch(text);
  if (leadingWhitespace == null || !_isShellPromptOnlyRow(text.trimLeft())) {
    return trimmed;
  }

  var remaining = leadingWhitespace.group(0)!.length;
  final spans = <StyledSpan>[];
  for (final span in trimmed.spans) {
    if (remaining >= span.text.length) {
      remaining -= span.text.length;
      continue;
    }
    if (remaining > 0) {
      spans.add(
        StyledSpan(text: span.text.substring(remaining), style: span.style),
      );
      remaining = 0;
    } else {
      spans.add(span);
    }
  }
  return StyledRow(spans: spans);
}

bool _isShellPromptOnlyRow(String rowText) {
  final trimmed = rowText.trimRight();
  if (trimmed.isEmpty || trimmed.contains('\n')) return false;
  return RegExp(r'^[^\s@]+@[^\s:]+:.+[$#>] ?$').hasMatch(trimmed) ||
      RegExp(r'^[A-Za-z]:\\.*> ?$').hasMatch(trimmed);
}

bool isReplayStatusOrDividerRow(String rowText) {
  final trimmed = rowText.trim();
  if (trimmed.isEmpty) return true;
  if (trimmed.startsWith('─') ||
      trimmed.startsWith('═') ||
      trimmed.startsWith('-')) {
    return true;
  }
  if (trimmed.startsWith('? ') ||
      trimmed.contains('for shortcuts') ||
      trimmed.contains('ctrl+o to')) {
    return true;
  }
  if (trimmed.startsWith('●') ||
      trimmed.startsWith('■') ||
      trimmed.startsWith('○')) {
    return true;
  }
  return false;
}

bool isReplayPromptRow(String rowText) {
  if (isReplayStatusOrDividerRow(rowText)) return false;
  final trimmed = rowText.trim();
  return trimmed.contains('\$') || trimmed.contains('>');
}

int replayCursorColForRow(String rowTextRaw) {
  final rowTextTrimmed = rowTextRaw.trimRight();
  var cursorCol = rowTextTrimmed.length;
  final lastDollar = rowTextTrimmed.lastIndexOf('\$');
  final lastChevron = rowTextTrimmed.lastIndexOf('>');
  final promptIndex = lastDollar > lastChevron ? lastDollar : lastChevron;
  if (promptIndex == rowTextTrimmed.length - 1 &&
      promptIndex + 1 < rowTextRaw.length &&
      rowTextRaw[promptIndex + 1] == ' ') {
    cursorCol += 1;
  }
  return cursorCol;
}

ReplayCursorPlacement computeReplayCursorPlacement({
  required List<StyledRow> fallbackRows,
  required int fittedRows,
  int? initialCursorRow,
  int? initialCursorCol,
}) {
  final rowCount = fallbackRows.length;
  var cursorRow = initialCursorRow ?? 0;
  int? cursorCol = initialCursorCol;

  var lastActiveRow = -1;
  for (var i = fallbackRows.length - 1; i >= 0; i--) {
    final rowText = fallbackRows[i].spans.map((s) => s.text).join().trimRight();
    if (isReplayPromptRow(rowText)) {
      lastActiveRow = i;
      break;
    }
  }
  if (lastActiveRow == -1) {
    for (var i = fallbackRows.length - 1; i >= 0; i--) {
      final rowText = fallbackRows[i].spans
          .map((s) => s.text)
          .join()
          .trimRight();
      if (rowText.isNotEmpty) {
        lastActiveRow = i;
        break;
      }
    }
  }
  final bool allRowsEmpty = lastActiveRow == -1;
  if (lastActiveRow == -1) {
    lastActiveRow = 0;
  }

  var shouldClamp =
      cursorRow < 0 ||
      cursorRow >= rowCount ||
      (!allRowsEmpty && cursorRow > lastActiveRow);
  if (!shouldClamp && cursorRow >= 0 && cursorRow < rowCount && !allRowsEmpty) {
    final cursorRowText = fallbackRows[cursorRow].spans
        .map((s) => s.text)
        .join()
        .trimRight();
    shouldClamp = isReplayStatusOrDividerRow(cursorRowText);
  }
  if (shouldClamp) {
    for (var i = lastActiveRow + 1; i <= cursorRow; i++) {
      if (i < fallbackRows.length) {
        final rowText = fallbackRows[i].spans
            .map((s) => s.text)
            .join()
            .trimRight();
        if (rowText.isNotEmpty && !isReplayStatusOrDividerRow(rowText)) {
          shouldClamp = false;
          break;
        }
      }
    }
  }

  if (shouldClamp) {
    cursorRow = lastActiveRow;
    cursorCol = replayCursorColForRow(
      fallbackRows[cursorRow].spans.map((s) => s.text).join(),
    );
  }
  if (cursorCol == null && lastActiveRow >= 0) {
    cursorRow = lastActiveRow;
    cursorCol = replayCursorColForRow(
      fallbackRows[cursorRow].spans.map((s) => s.text).join(),
    );
  }
  if (cursorRow >= 0 && cursorRow < rowCount) {
    final rowTextRaw = fallbackRows[cursorRow].spans.map((s) => s.text).join();
    if (isReplayPromptRow(rowTextRaw)) {
      final promptCol = replayCursorColForRow(rowTextRaw);
      if (cursorCol == null || cursorCol < promptCol) {
        cursorCol = promptCol;
      }
    }
  }

  var startRow = rowCount - fittedRows > 0 ? rowCount - fittedRows : 0;
  if (cursorRow < startRow) {
    startRow = cursorRow;
  } else if (cursorRow >= startRow + fittedRows) {
    startRow = cursorRow - fittedRows + 1;
  }
  if (startRow < 0) {
    startRow = 0;
  } else if (startRow > rowCount) {
    startRow = rowCount;
  }

  final terminalRow = ((cursorRow - startRow) + 1).clamp(1, fittedRows);
  return ReplayCursorPlacement(
    sourceRow: cursorRow,
    sourceCol: cursorCol ?? 0,
    startRow: startRow,
    endRow: (startRow + fittedRows).clamp(0, rowCount),
    terminalRow: terminalRow,
    terminalCol: (cursorCol ?? 0) + 1,
  );
}

class ReplayCursorPlacement {
  const ReplayCursorPlacement({
    required this.sourceRow,
    required this.sourceCol,
    required this.startRow,
    required this.endRow,
    required this.terminalRow,
    required this.terminalCol,
  });

  final int sourceRow;
  final int sourceCol;
  final int startRow;
  final int endRow;
  final int terminalRow;
  final int terminalCol;
}
