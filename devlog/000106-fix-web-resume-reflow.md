# 000106 — fix/web-resume-reflow

**Agent:** Claude Code (claude-opus-4-8[1m]) @ triage branch fix/web-resume-reflow

## Intent

On the web client, resuming a backgrounded tab leaves the terminal too narrow,
and the header refit button does not fix it; only resizing the browser window
reflows correctly. Make the refit button and resume actually re-fit on web.
Derivation in `devlog/plans/000106-01-web-resume-reflow.md`.

## Research & Discoveries

2026-07-22T16:05-0700 Confirmed the mechanism by driving the real running web
client over the DevTools Protocol (`window.activeTerm` is exposed). With the
window wide the grid was correctly fitted (114 cols × 9px = 1026px screen). Then,
simulating the stale-narrow grid a resume-time mis-fit leaves:

- forcing the grid to 40 cols, `session.terminal.viewWidth` (what
  `_refitActiveSession` read) returns **40** — it would re-assert the narrow
  width to the host;
- `FitAddon.proposeDimensions()` returns **114** — the correct width from the
  real pixels.

So window resize works (ResizeObserver → `_onFit` → `FitAddon.fit()`), while the
refit button and resume do not (`_refitActiveSession` jiggles the host to the
grid without ever re-fitting the grid).

2026-07-22T16:12-0700 Root cause: on web the real grid is xterm.js;
`session.terminal` is a Dart `xt.Terminal` shadow, resized only via
`controller.resize()` (a documented no-op on web through the store sink), so its
`viewWidth` does not track the FitAddon size. On native `TerminalView` auto-fits
`session.terminal`, so `viewWidth` is authoritative there — which is why only web
is broken. `session.lastFittedCols` is no better: it is also written from
host-snapshot broadcasts (`main.dart:2250`), i.e. potentially another device's
width on a shared PTY.

## Decisions

2026-07-22T16:18-0700 The refit must run inside the pane, where the real grid
lives; no value in platform-agnostic `main.dart` reliably reflects the web
render grid. Added a `refit()` seam to `TerminalController` mirroring the
existing `fit()` listener pattern.

2026-07-22T16:20-0700 `refit` is a distinct channel from `fit`, not an overload.
`fit` is what the ResizeObserver fires — recompute the grid from pixels. `refit`
additionally force-sends the fitted size to the host (jiggle one row shorter and
back), so a stale-narrow grid on resume corrects *and* a device-reclaim (host at
another device's width, own grid unchanged, so no plain-fit resize fires) also
corrects. Keeping them separate avoids the ResizeObserver spamming host resizes.

2026-07-22T16:22-0700 Native path left byte-for-byte unchanged. The native pane
registers no refit listener, so `controller.refit()` is a no-op there, and
`_refitActiveSession` returns after it only on web; on native it runs the same
`viewWidth`-based jiggle as before. Running that jiggle on web after the pane
re-fit would nudge the host straight back to the stale shadow width, which is why
the `kIsWeb` early return sits between them.

## What Changed

2026-07-22T16:31-0700 `flutter/triage_client/lib/widgets/terminal_pane.dart` —
added `_refitListeners`, `addRefitListener`/`removeRefitListener`, `refit()`, and
clear the list in `dispose()`.

2026-07-22T16:31-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`
— bind `_onRefit` in `_bindController`/`_unbindController`; it runs `_onFit()`
(FitAddon recompute) then force-sends the fitted `_term.cols/rows` to the host via
`sendResizeOut` (rows-1 then rows) to guarantee a SIGWINCH repaint.

2026-07-22T16:31-0700 `flutter/triage_client/lib/main.dart` —
`_refitActiveSession` now calls `session.terminalController.refit()` and returns
on web before the native jiggle. Rewrote the doc comment to explain the web
shadow-terminal problem and the native/web split.

2026-07-22T16:33-0700 `flutter/triage_client/test/terminal_controller_refit_test.dart`
— new: `fit` and `refit` are distinct channels, removal stops delivery, dispose
clears listeners.

2026-07-22T16:52-0700 `terminal_pane_web.dart` (review round 1) — `_onRefit` now
retries on the init fit ladder (0/50/200/600/1500ms), because resume fires before
the tab's layout settles and a single-shot refit would force-send the stale size
while the element is still 0-width. A `_refitGeneration` counter cancels a
superseded refit's pending retries, and `_lastRefit{Cols,Rows}` dedupes host
resize-outs so a settled refit jiggles the host once, not per tick (the first
pass still force-sends unconditionally, for device-reclaim). Added a
`!_initialContentWritten` guard so a refit during the first-fit handshake does
not bypass that path's history-flush gate. Also routed `didUpdateWidget`'s
controller-swap teardown through a shared `_unbindControllerFrom`, which had
omitted `removeRefitListener` and would have leaked a listener on the old
controller.

2026-07-22T17:08-0700 Verified end-to-end against the running daemon, re-run
after the review-round-1 rework: built the web bundle, served it via the
per-request override dir (`~/.local/share/triage/web`, read live so no daemon
restart), reloaded the browser. Forced the grid to 40 cols, clicked the actual
header refit button, and the grid returned to 114 with the content rendering
full-width — meaning the host PTY repainted at 114, so the whole chain (button →
`controller.refit()` → `_onRefit` → FitAddon + force-send → host resize → live
repaint) works. Removed the override afterward so the daemon reverts to the
embedded bundle. `flutter analyze` clean on the touched files; `flutter test`
173 pass.

The `_onRefit` retry ladder, `_refitGeneration` guard, and `_lastRefit` dedup
live in `_TerminalPaneState` and are `dart:html`/JS-interop-bound, so they are
covered by the manual end-to-end run above rather than a unit test; the
controller-seam test covers only the `fit`/`refit` dispatch plumbing.

## Commits

- HEAD — fix(triage_client): re-fit the web terminal on refit and resume

## Next Steps

- Unaddressed and separate: the scrollback width-collision from #123 (history
  re-emulated at the client width, and Claude Code repainting without erasing).
  This fix corrects the *live* frame's width on refit/resume; it does not reflow
  historical scrollback authored at other widths.
