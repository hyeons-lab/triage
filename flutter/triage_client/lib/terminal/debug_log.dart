import 'package:flutter/foundation.dart';

/// Whether the terminal pipeline emits its stage-by-stage trace.
///
/// The pipeline hands bytes across five seams — store, sink, controller, pane,
/// xterm.js — and three of them swallow failures (`catch (_) {}`) or silently
/// buffer, so a blank pane looks identical whether the bytes never arrived,
/// arrived and were queued, or arrived and threw on the way to the emulator.
/// This trace names which seam the bytes reached.
const bool kTerminalDebug = false;

/// One greppable line per pipeline stage. Filter the console on `TDBG`.
void tdbg(String stage, String message) {
  if (!kTerminalDebug) return;
  debugPrint('TDBG $stage | $message');
}

/// Short, log-safe rendering of a chunk: length plus an escaped head, so a
/// control-heavy redraw stays on one line.
String tdbgPreview(String data, [int head = 48]) {
  final clipped = data.length <= head ? data : data.substring(0, head);
  final escaped = clipped
      .replaceAll('\x1b', r'\e')
      .replaceAll('\r', r'\r')
      .replaceAll('\n', r'\n');
  return '${data.length}B "$escaped"${data.length > head ? '…' : ''}';
}
