# 000062 — fix: terminal copy preserves spaces (native client)

> Renumbered from 000061 → 000062 to avoid colliding with PR #68's
> `000061-selection-autoscroll`, which claimed the number first.

**Agent:** Claude (claude-opus-4-8) @ argus branch fix/terminal-copy-preserves-spaces

## Intent

Copying selected text from a terminal session in the **native** Flutter client
strips the spaces — words and columns run together ("everything is concatenated
without spaces"). Restore the spaces on copy. A follow-up applied the same fix
to the **web** client, which had a latent variant of the bug.

## Research & Discoveries

- Native copy path: `Cmd+C` → xterm.dart `CopySelectionTextIntent`
  (`xterm-4.0.0/lib/src/ui/shortcut/actions.dart:44`) →
  `terminal.buffer.getText(selection)` → per-line `BufferLine.getText`
  (`.../core/buffer/line.dart:325`).
- `BufferLine.getText` emits **nothing** for any cell whose `codePoint == 0` —
  not even a space:

  ```dart
  if (codePoint != 0 && i + width <= to) { builder.writeCharCode(codePoint); }
  ```

- A literal space is `0x20` (codePoint 32) and survives. But ratatui-style TUIs
  (Claude Code, `ls`, `git`) lay out columns by **moving the cursor** (`ESC[C`,
  tab, `ESC[G`) over the gaps rather than writing spaces, leaving those cells at
  codePoint 0 → they vanish on copy and the columns concatenate.
- Web is unaffected because it copies via xterm.js `getSelection()`, which
  backfills null cells with spaces.
- Cell model (verified in `line.dart`): blank/erased cell = content 0
  (codePoint 0, width 0); explicit space = codePoint 32, width 1; wide glyph =
  width 2 with a codePoint-0 trailing cell — distinguishable from a blank only
  by the previous cell's width being 2.
- We must not patch the vendored pub-cache package. Clean seam:
  `TerminalView.onKeyEvent` (`terminal_view.dart:394`) is consulted before the
  shortcut manager and a non-`ignored` result short-circuits it. All needed
  buffer APIs (`Buffer.lines/height`, `BufferLine.getCodePoint/getWidth/length`,
  `BufferRange.normalized/toSegments`) are publicly exported via
  `package:xterm/xterm.dart`.

## Decisions

- 2026-06-09T23:58-0700 Reconstruct copied text ourselves rather than patch the
  package — keeps the dependency stock and survives `pub get`.
- 2026-06-09T23:58-0700 Output is a strict superset of `Buffer.getText`'s: glyph
  cells (literal spaces included) verbatim; interior blanks → one space;
  trailing blanks stay dropped (no full-width padding); wide-glyph trailing cell
  skipped. Only the missing interior gap-spaces are added; nothing else changes.
- 2026-06-09T23:58-0700 Copy chord mirrors xterm's `defaultTerminalShortcuts`
  (meta-only on Apple, control+shift elsewhere) so plain Ctrl+C → SIGINT is
  untouched.
- 2026-06-10T06:10-0700 Web: flip the copy source priority to prefer xterm.js's
  own `getSelection()` over `window.getSelection()`. No renderer addon is loaded
  so xterm.js uses its default DOM renderer; `window.getSelection().toString()`
  serializes the per-cell row spans and drops the inter-column spaces, while
  xterm.js rebuilds the row text from the buffer with spaces intact. The
  browser-native selection stays as a fallback for when xterm has no selection.

## What Changed

- 2026-06-09T23:58-0700 `flutter/triage_client/lib/terminal/terminal_selection.dart`
  — new pure helpers `terminalSelectionText(buffer, range)` and
  `bufferLineSelectedText(line, from, to)` implementing the reconstruction rule;
  kept package-level and dependency-free so they unit-test without a widget.
- 2026-06-09T23:58-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`
  — wired `onKeyEvent` on the `TerminalView`; `_handleTerminalKeyEvent` copies
  the reconstructed text, sets the clipboard, and clears the selection on the
  platform copy chord, otherwise returns `KeyEventResult.ignored`; added the
  `flutter/foundation` import for `defaultTargetPlatform`/`TargetPlatform` and
  expanded the `flutter/services` show list (`Clipboard`, `ClipboardData`,
  `KeyDownEvent`, `KeyEvent`, `LogicalKeyboardKey`).
- 2026-06-09T23:58-0700 `flutter/triage_client/test/terminal/terminal_selection_test.dart`
  — unit tests for interior gaps, trailing-blank trimming, literal-space
  preservation, wide-glyph handling, sub-ranges, and a real-`Terminal`
  integration case (cursor-move gap + multi-row newline join).
- 2026-06-10T06:10-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`
  — Ctrl/Cmd+C handler now reads xterm.js `getSelection()` first and only falls
  back to `window.getSelection()` when xterm reports nothing selected. No
  automated coverage: the web pane is conditionally imported behind
  `dart.library.js_util` and needs a browser with xterm.js loaded; verified by
  `flutter analyze` only, pending manual check in a browser.
- 2026-06-10T07:17-0700 (PR #69 review) `terminal_pane_stub.dart` — wrapped the
  fire-and-forget `Clipboard.setData` in `unawaited(...)` (`dart:async`) so the
  synchronous key handler does not leave a dangling future
  (`unawaited_futures`). Renumbered this devlog 000061 → 000062 to avoid a
  number collision with PR #68's `000061-selection-autoscroll`.

## Issues

- `defaultTargetPlatform` was undefined under the `material` import alone
  (`TargetPlatform` resolved, the const did not); added an explicit
  `package:flutter/foundation.dart` show import to resolve it.

## Testing

- `flutter analyze` on the three changed files: no issues.
- `flutter test`: full suite green (80 tests), including the 9 new selection
  tests.

## Commits

- 5883345 — fix(client): preserve spaces when copying terminal selection
- 270a7f1 — fix(client): prefer xterm.js getSelection on web to keep spaces
- HEAD — fix(client): unawait clipboard write; renumber devlog (PR #69 review)
