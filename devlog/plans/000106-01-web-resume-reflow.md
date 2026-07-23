# 000106-01 — Web refit/resume leaves the terminal too narrow

## Thinking

Reported: on the web client, resuming a backgrounded tab leaves the terminal too
narrow; the header **refit button does not fix it either**; only resizing the
browser window reflows correctly. A manual resize is the workaround.

### Confirmed by measurement, not inference

Drove the real running web client over the DevTools Protocol (the pane exposes
`window.activeTerm`). With the window wide, the xterm.js grid was correctly
fitted: 114 cols × 9px cell = 1026px screen. Then, simulating the stale-narrow
state a bad-timing fit leaves on resume:

```
force xterm grid to 40 cols
  _refitActiveSession source  (session.terminal.viewWidth) -> 40   (stays narrow)
  FitAddon.proposeDimensions()                             -> 114  (correct)
```

So the two paths diverge exactly at the fit:

- **Window resize works** — the pane's `ResizeObserver` fires `_onFit` →
  `FitAddon.fit()`, which recomputes the grid from actual pixels (114) and, on a
  size change, sends it to the host via `sendResizeOut`.
- **Refit button and resume do not** — both run
  `_refitActiveSession`, which reads `session.terminal.viewWidth` and jiggles the
  *host* PTY to it. It never re-fits the client's xterm.

### Why `viewWidth` is the wrong source on web

`session.terminal` is a Dart `xt.Terminal` (xterm.dart). On **native** the
`TerminalView` auto-fits it, so `viewWidth` is authoritative — which is why the
host-jiggle works on native and only web is broken. On **web** the real grid is
xterm.js; `session.terminal` is a shadow emulator resized only when
`controller.resize()` fires (via the store's `resize`, a documented no-op on
web). So its `viewWidth` does not track the xterm.js FitAddon size and goes stale
after a resume-time mis-fit.

The other candidate source, `session.lastFittedCols`, is no better: it is written
from host-snapshot broadcasts too (`main.dart:2250`), i.e. potentially another
device's width on a shared PTY. That is precisely why the jiggle avoided it.

Conclusion: **no value in platform-agnostic `main.dart` reliably reflects this web
client's real render grid.** The refit has to run inside the pane, where the grid
lives.

### Fix

Add a `refit()` seam to `TerminalController`, mirroring the existing `fit()`
listener pattern, and have the **web pane** implement it as:

1. `FitAddon.fit()` — recompute the grid from actual pixels (fixes the stale
   narrow grid on resume / refit-when-wrong-size).
2. Force-send the fitted size to the host by jiggling through `sendResizeOut`
   (`rows-1` then `rows`). The jiggle guarantees a SIGWINCH even when the fitted
   size equals the host's current size, so a device-reclaim (host stuck at
   another device's width) also corrects, and the program repaints over the live
   stream.

`main.dart`'s `_refitActiveSession` calls `controller.refit()` and then, on web
only, returns — the pane has already re-fitted and re-synced the host, so running
the old `viewWidth`-based jiggle afterward would nudge the host straight back to
the stale value. Native keeps its existing, working jiggle unchanged.

This reuses the existing resize-out plumbing
(`sendResizeOut` → input router → controller resize-out listener →
`_client.resizeSession`) and touches native behavior not at all.

## Plan

1. `terminal_pane.dart` — add `_refitListeners`, `addRefitListener`,
   `removeRefitListener`, `refit()`, and clear the list in `dispose()`.
2. `terminal_pane_web.dart` — bind `_onRefit` in `_bindController` /
   `_unbindController`; implement it as fit + force-send (jiggle).
3. `main.dart` — `_refitActiveSession` calls `session.terminalController.refit()`,
   then `if (kIsWeb) return;` before the native jiggle. Update the doc comment.
4. Verify in the browser via the CDP harness: force the grid narrow, invoke the
   refit path, confirm it returns to the fitted width and the host follows. Add a
   Dart test for the controller seam / main.dart wiring where practical.
5. Validate: `flutter analyze`, `flutter test`, and the Rust gates if any Rust is
   touched (none expected). Then `/review-fix-loop max`.

Not in scope: the #123 scrollback-collision / repaint-without-erase issue. That
is a different mechanism (history re-emulation, and Claude Code not erasing) and
is recorded there.
