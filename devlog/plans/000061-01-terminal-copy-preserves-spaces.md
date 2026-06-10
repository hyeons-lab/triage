# 000061-01 — Terminal copy preserves spaces (native client)

## Thinking

Reported symptom: copying from a terminal session in the native Flutter
client produces text with the spaces stripped — words run together.
Web client is unaffected.

Traced the native copy path:

- `Cmd+C` → xterm.dart `CopySelectionTextIntent`
  (`xterm-4.0.0/lib/src/ui/shortcut/actions.dart:44`)
  → `terminal.buffer.getText(selection)`
  → per-line `BufferLine.getText` (`.../core/buffer/line.dart:325`).

`BufferLine.getText` skips every cell whose `codePoint == 0` and emits
*nothing* for it — not even a space:

```dart
if (codePoint != 0 && i + width <= to) {
  builder.writeCharCode(codePoint);
}
```

A literal space is `0x20` (codePoint 32) and survives. But TUI programs
(ratatui apps like Claude Code, `ls` columns, `git`) lay out columns by
*moving the cursor* (`ESC[C`, tab, `ESC[G`) over the gaps rather than
emitting spaces, leaving those cells at codePoint 0. On copy they all
disappear and the visible columns concatenate.

Web is unaffected because it copies via xterm.js `getSelection()`, which
backfills null cells with spaces. xterm.dart does not.

Cell model (verified in `line.dart`):
- erased / never-written cell: content 0 → codePoint 0, width 0.
- normal glyph: codePoint = char, width = wcwidth (1, or 2 for wide).
- explicit space `0x20`: codePoint 32, width 1 (already preserved).
- wide-char trailing cell: codePoint 0, width 0 — indistinguishable from a
  blank except that the *previous* cell has width 2.

We must NOT patch the vendored pub-cache package. The clean seam is
`TerminalView.onKeyEvent` (`terminal_view.dart:394`): a non-`ignored`
result short-circuits before xterm's shortcut manager runs the broken
copy action. We intercept the copy chord there and rebuild the text
ourselves.

Reconstruction rule (strict superset of xterm's output — only ADDS the
missing interior gap-spaces, changes nothing else):
- glyph cells (codePoint != 0, `i + width <= to`): written verbatim, exactly
  as the original. This preserves explicit spaces and explicit trailing
  spaces.
- blank cells (codePoint 0): emit a single space ONLY when the cell is
  strictly before the last glyph in the range (interior gap). Trailing
  blanks stay dropped, matching the original trim-on-copy behavior, so lines
  are not padded to full width.
- skip a wide-char trailing cell (previous cell width 2) so CJK glyphs do not
  gain a stray trailing space.

Newline / wrapped-line joining mirrors `Buffer.getText`.

Copy chord matches xterm's own `defaultTerminalShortcuts` so Ctrl+C → SIGINT
is untouched:
- macOS / iOS: `meta` only (no ctrl/alt/shift).
- otherwise: `control + shift` only.

## Plan

1. `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`
   - Wire `onKeyEvent:` on the `TerminalView`.
   - `_handleTerminalKeyEvent`: on `KeyDownEvent` of `keyC` with the platform
     copy chord and a live selection, copy the reconstructed text, clear the
     selection, return `KeyEventResult.handled`; otherwise `ignored`.
   - Pure helpers `terminalSelectionText(buffer, range)` and
     `bufferLineSelectedText(line, from, to)` implementing the rule above.
2. Extract the pure reconstruction into a testable top-level function (kept in
   the same library or a small helper file) so it can be unit-tested against a
   real `xt.Terminal` buffer.
3. Test: write cursor-positioned output (`ESC[C`, absolute column) into a
   terminal, select it, assert the copied text keeps the gap spaces; plus
   wide-char and trailing-blank cases.
4. `flutter analyze` + `flutter test` (or `dart` equivalents) green.
5. Devlog, plan, code committed together; push; open PR.
