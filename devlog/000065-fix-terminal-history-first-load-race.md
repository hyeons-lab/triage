# 000065 — fix/terminal-history-first-load-race

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/terminal-history-first-load-race

## Intent

When loading/tapping a session in the Flutter client, terminal history often
does not render on first show. Switching to another session and back (and
sometimes resizing) makes the history appear. The user identified it as a race
condition.

## Research & Discoveries

2026-06-11T06:39-0700 Root cause is a first-fit handshake race in the web
terminal view, spanning three files:

- `lib/main.dart` — `SessionVm` stages history in `_pendingHistory` and only
  replays it once `_viewReady` is true. `_viewReady` is set exclusively by
  `noteViewFit`, which is called only from the web view's `onViewFit`.
- `lib/widgets/terminal_pane_web.dart` — `onViewFit` is called only inside
  `_finishInitialContent()` (via `_writeInitialContent`). `_finishInitialContent`
  is gated by `_styleSheetLoaded` AND a 250ms size-stability debounce
  (`_stabilityTimer`). The stability timer is cancelled+restarted on every size
  change during initial layout settling, so the 250ms quiet window can keep
  slipping. The only callers of `_onFit` are a one-shot retry ladder
  (0/50/200/600/1500ms), stylesheet onLoad, a 600ms fallback, ResizeObserver,
  and fonts.ready. Once those expire there is no further finalize attempt, so
  staged history stays unflushed until a resize or tab-switch (dispose+reinit)
  forces a fresh fit cycle.

This matches the symptom exactly: a tab-switch reinitializes the view and forces
a new fit → finalize → flush; and once finalized `_viewReady` stays true on the
SessionVm so re-selecting renders instantly.

## Decisions

2026-06-11T06:39-0700 Fix in the web view rather than main.dart — add a
max-deadline force-finalize safety net. The replay-after-real-size design is
intentional (replaying at the default 80x24 shows nothing), so we keep deferring
but guarantee the deferral terminates. A one-shot deadline timer armed at the
first valid sized fit, NOT reset on subsequent size changes, force-finalizes with
the last fitted size if the stability window never settles.

## What Changed

2026-06-11T06:41-0700 `lib/widgets/terminal_pane_web.dart` — added
`Timer? _forceFinalizeTimer` backstop for the first-fit handshake. Armed once
(`??=`) in `_onFit` at the first valid sized fit (rows≥5, cols≥10) while content
is unwritten, with an 800ms deadline; it is NOT reset on subsequent size changes
(unlike `_stabilityTimer`). On fire, if still unwritten with a valid last fitted
size, it calls `_finishInitialContent(_lastFittedCols!, _lastFittedRows!)` —
which calls `onViewFit`, setting `SessionVm._viewReady` and flushing staged
history. Cancelled+nulled in `_finishInitialContent`, in both stylesheet-reset
paths (onLoad +150ms, 600ms fallback) so it re-arms for the fresh fit cycle, and
in `dispose()`. `flutter analyze` clean.

2026-06-11T08:40-0700 `lib/widgets/terminal_pane_web.dart` — addressed PR #72
review (Copilot): `_writeInitialContent` re-read `rows`/`cols` from `_term` at
finalize time, ignoring the size passed into `_finishInitialContent`. Under the
churn the backstop guards against, `_term` can momentarily sit below the minimum
grid; signaling that too-narrow size leaves the store unsized
(`_reduceHistory`/`_reduceResize` skip below `kMinTerminalCols`/`kMinTerminalRows`),
which suppresses the live-output flush. Added optional `overrideCols/overrideRows`
to `_writeInitialContent`; `_finishInitialContent` now passes its validated
`fittedCols/fittedRows` (the backstop only finalizes with a last fit ≥ minimums),
so `onViewFit` and the daemon resize-out agree on the intended size. The
re-replay path (`_triggerFullReplayOrReset`, content already written, layout
settled) still re-reads `_term`, which is correct there.

## Verification

2026-06-11T08:40-0700 Built the real Flutter Web app and drove it headless
(Playwright, `?mock=true`, reading `window.activeTerm.buffer`). Benign cold loads:
8/8 render history on both branch and pre-fix main (a fixed viewport never
triggers the race). Discriminator — continuous sub-250ms viewport churn (never
switching sessions): pre-fix main NEVER renders during 4s of churn (bug
reproduced); branch renders despite churn (backstop fires ~by t=2s), confirmed
again after the Copilot fix.

## Commits

HEAD — fix(client): use validated fit size when force-finalizing first-fit
a3c492e — fix(client): force-finalize first-fit so session history renders on load
