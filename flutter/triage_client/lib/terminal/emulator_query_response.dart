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
  r'^(?:'
  r'(?:\x1b\[|\u009b)(?:'
  r'\d+;\d+R|' // CPR (Cursor Position Report, e.g. ESC[24;1R)
  r'\?[0-9;]*c|' // DA1 (Primary Device Attributes, e.g. ESC[?1;2c)
  r'>[0-9;]*c|' // DA2 (Secondary Device Attributes, e.g. ESC[>0;276;0c)
  r'!\|[0-9a-fA-F]*~?|' // DA3 (Tertiary Device Attributes)
  r'[03]n|' // DSR (Device Status Report, e.g. ESC[0n ok)
  r'\?[0-9;]*u|' // Kitty keyboard flags query response (e.g. ESC[?0u)
  r'\??[0-9;]*\$y|' // DECRPM mode report (e.g. ESC[?2026;2$y, ESC[2026;2$y)
  r'(?:4|6|8);\d+;\d+t' // Window / cell / text area size reports
  r')|'
  r'(?:\x1b\]|\u009d)(?:4;\d+|10|11|12);rgb:[0-9a-fA-F/]+(?:\x07|\x1b\\|\u009c)|' // OSC 4/10/11/12 color reports
  r'(?:\x1bP|\u0090)(?:>\|[\x20-\x7e]*|!\|[0-9a-fA-F]*|[01]\$[rR][\x20-\x7e]*|[01]\+[rR][0-9a-fA-F=;]*)(?:\x07|\x1b\\|\u009c)|' // DCS XTVERSION / DA3 / DECRQSS / XTGETTCAP responses
  r'(?:\x1b|\x07|\x08)\??[0-9;]*\$y' // Raw DECRPM mode fragments preceded by control byte
  r')+$',
);

final RegExp _cprSequence = RegExp(r'^(?:(?:\x1b\[|\u009b)\d+;\d+R)+$');

/// Returns true if [data] is comprised entirely of synthetic terminal emulator
/// query responses. Hardware keyboard chords ([fromHardwareKey] == true) exempt
/// CPR-shaped sequences so modified `F3` sequences (`\x1b[1;2R`..`\x1b[1;8R`)
/// pass through intact while still blocking DA/Kitty/DECRPM/OSC/DCS replies.
bool isEmulatorQueryResponse(String data, {bool fromHardwareKey = false}) {
  if (data.isEmpty) {
    return false;
  }
  final first = data.codeUnitAt(0);
  if (first != 0x1b &&
      first != 0x07 &&
      first != 0x08 &&
      first != 0x9b &&
      first != 0x9d &&
      first != 0x90) {
    return false;
  }
  if (fromHardwareKey && _cprSequence.hasMatch(data)) {
    return false;
  }
  return _allEmulatorQueryResponses.hasMatch(data);
}

/// Returns true if [data] is comprised entirely of terminal mouse report
/// sequences: SGR (`ESC [ < Cb ; Cx ; Cy M/m`), urxvt (`ESC [ Cb ; Cx ; Cy M`
/// with `Cb >= 32`), or legacy X10 / UTF-8 (`ESC [ M Cb Cx Cy`).
bool isTerminalMouseReport(String data) {
  return _parseTerminalMousePackets(data) != null;
}

/// Returns true if [data] is comprised entirely of unpressed terminal mouse
/// hover motion packets (`?1003` motion with no button held and not wheel).
bool isUnpressedTerminalMouseHover(String data) {
  return _parseTerminalMousePackets(data) == true;
}

/// Parses one or more concatenated terminal mouse packets in [data].
/// Returns `null` if [data] is empty or contains any non-mouse sequence, `true`
/// if every packet is an unpressed hover motion report, or `false` if all
/// packets are valid mouse reports with at least one button/wheel event.
bool? _parseTerminalMousePackets(String data) {
  if (data.isEmpty || !data.startsWith('\x1b[')) {
    return null;
  }
  var allHover = true;
  final runes = data.runes.toList(growable: false);
  var i = 0;
  while (i < runes.length) {
    if (i + 2 >= runes.length || runes[i] != 0x1b || runes[i + 1] != 0x5b) {
      return null;
    }
    final third = runes[i + 2];
    if (third == 0x4d) {
      // Legacy X10 or UTF-8 (?1005): ESC [ M Cb Cx Cy
      if (i + 5 >= runes.length) return null;
      final cbRune = runes[i + 3];
      final cxRune = runes[i + 4];
      final cyRune = runes[i + 5];
      if (cbRune < 0x20 ||
          cbRune > 0x7ff ||
          cxRune < 0x20 ||
          cxRune > 0x7ff ||
          cyRune < 0x20 ||
          cyRune > 0x7ff) {
        return null;
      }
      final rawCb = cbRune - 32;
      final isHover =
          (rawCb & 64) == 0 && (rawCb & 32) != 0 && (rawCb & 3) == 3;
      if (!isHover) allHover = false;
      i += 6;
      continue;
    }

    final isSgr = third == 0x3c; // '<'
    var p = isSgr ? i + 3 : i + 2;
    final params = <int>[];
    while (params.length < 3) {
      if (p >= runes.length || runes[p] < 0x30 || runes[p] > 0x39) {
        return null;
      }
      var val = 0;
      while (p < runes.length && runes[p] >= 0x30 && runes[p] <= 0x39) {
        val = val * 10 + (runes[p] - 0x30);
        if (val > 0x10ffff) return null;
        p++;
      }
      params.add(val);
      if (params.length < 3) {
        if (p >= runes.length || runes[p] != 0x3b) return null;
        p++;
      }
    }
    if (p >= runes.length) return null;
    final term = runes[p];
    if (isSgr) {
      if (term != 0x4d && term != 0x6d) return null; // 'M' or 'm'
      final rawCb = params[0];
      final isHover =
          term == 0x4d &&
          (rawCb & 64) == 0 &&
          (rawCb & 32) != 0 &&
          (rawCb & 3) == 3;
      if (!isHover) allHover = false;
    } else {
      // urxvt (?1015): ESC [ Cb ; Cx ; Cy M with Cb = rawCb + 32
      if (term != 0x4d || params[0] < 32) return null;
      final rawCb = params[0] - 32;
      final isHover =
          (rawCb & 64) == 0 && (rawCb & 32) != 0 && (rawCb & 3) == 3;
      if (!isHover) allHover = false;
    }
    i = p + 1;
  }
  return allHover;
}
