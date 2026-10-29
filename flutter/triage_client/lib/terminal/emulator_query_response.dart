// Utilities for detecting and filtering synthetic terminal query auto-responses.

/// Regex matching terminal-generated auto-responses (e.g. Cursor Position Reports,
/// Device Attributes, Kitty keyboard protocol query responses, DECRPM mode reports,
/// OSC color reports, and window size reports).
///
/// When an interactive application running in the remote session emits a query sequence
/// in its output stream (such as CPR \x1b[6n, DA \x1b[c, Kitty query \x1b[?u, DECRQM \x1b[?2026$p),
/// the client-side terminal emulator (xterm.js or xterm.dart) automatically produces an
/// answer on its output channel.
///
/// In Triage's architecture (where the daemon owns the PTY and the client is a remote display),
/// these synthetic answers must never be routed back to the host PTY as fake user keyboard input.
final RegExp _allEmulatorQueryResponses = RegExp(
  r'^(?:(?:\x1b\[?|\x07|\x08)(?:'
  r'\[\d+;\d+R|' // CPR (Cursor Position Report, e.g. ESC[24;1R)
  r'\[\?[0-9;]*c|' // DA1 (Primary Device Attributes, e.g. ESC[?1;2c)
  r'\[>[0-9;]*c|' // DA2 (Secondary Device Attributes, e.g. ESC[>0;276;0c)
  r'\[!\|[0-9a-fA-F]*~?|' // DA3 (Tertiary Device Attributes)
  r'\[[03]n|' // DSR (Device Status Report, e.g. ESC[0n ok)
  r'\[\?[0-9;]*u|' // Kitty keyboard flags query response (e.g. ESC[?0u)
  r'\[\??[0-9;]*\$y|' // DECRPM mode report (e.g. ESC[?2026;2$y, ESC[2026;2$y)
  r'\](?:4;\d+|10|11|12);rgb:[0-9a-fA-F/]+(?:\x07|\x1b\\)|' // OSC 4/10/11/12 color reports
  r'P(?:>\|[\x20-\x7e]*|!\|[0-9a-fA-F]*|[01]\$[rR][\x20-\x7e]*|[01]\+[rR][0-9a-fA-F=;]*)(?:\x07|\x1b\\)|' // DCS XTVERSION / DA3 / DECRQSS / XTGETTCAP responses
  r'\[(?:4|6|8);\d+;\d+t|' // Window / cell / text area size reports
  r'\??[0-9;]*\$y' // Raw DECRPM mode fragments preceded by control byte
  r'))+$',
);

final RegExp _terminalMouseReports = RegExp(
  r'^(?:\x1b\[<\d+;\d+;\d+[Mm]|\x1b\[M[\x20-\xff]{3})+$',
);

/// Returns true if [data] is comprised entirely of terminal emulator query responses.
bool isEmulatorQueryResponse(String data) {
  if (data.isEmpty) {
    return false;
  }
  if (!data.startsWith('\x1b') &&
      !data.startsWith('\x07') &&
      !data.startsWith('\x08')) {
    return false;
  }
  return _allEmulatorQueryResponses.hasMatch(data);
}

/// Returns true if [data] is comprised entirely of terminal mouse report sequences
/// (SGR `ESC [ < Cb ; Cx ; Cy M/m` or legacy X10 `ESC [ M Cb Cx Cy`).
bool isTerminalMouseReport(String data) {
  if (data.isEmpty || !data.startsWith('\x1b[')) {
    return false;
  }
  return _terminalMouseReports.hasMatch(data);
}
