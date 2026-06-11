# 000065-01 — Force-finalize the first-fit handshake

## Thinking

The deferred-history replay depends on `_finishInitialContent()` running at least
once, because that is the only path that calls `widget.onViewFit` →
`SessionVm.noteViewFit` → `_flushPendingHistory`. The finalize is gated by a
250ms size-stability debounce that is reset on every size change. During Flutter
Web's initial layout settling the size can keep changing, so the quiet window
never elapses within the one-shot retry ladder (which ends at 1500ms). After the
ladder + stylesheet load + fonts.ready + 600ms fallback all expire, nothing else
calls `_onFit`, so the finalize — and the history flush — never happens until an
external resize or a dispose+reinit (tab switch).

We must keep deferring until we have a real fitted size (replaying at the default
80x24 renders nothing — this is intentional), but guarantee the deferral
terminates. The minimal, low-risk change: a max-deadline force-finalize timer.

## Plan

1. Add field `Timer? _forceFinalizeTimer;` next to `_stabilityTimer` in
   `terminal_pane_web.dart`.

2. In `_onFit`, inside the `if (!_initialContentWritten)` block, after the
   `_styleSheetLoaded` and `fittedCols < 10` guards pass (i.e. we have a valid
   sized fit), arm `_forceFinalizeTimer` exactly once (only if it is currently
   null) with an ~800ms deadline. When it fires: if still mounted and
   `!_initialContentWritten` and we have valid `_lastFittedCols`/`_lastFittedRows`
   (>= the minimums), call `_finishInitialContent(_lastFittedCols!, _lastFittedRows!)`.
   Do NOT reset/cancel this timer on subsequent size changes — that is the whole
   point; it is the backstop the stability debounce lacks.

3. In `_finishInitialContent`, cancel `_forceFinalizeTimer` (and null it) so the
   normal stability path and the backstop can't both fire.

4. Where stylesheet load / 600ms fallback reset `_initialContentWritten = false`
   and null `_stableWidth/_stableHeight`, also cancel+null `_forceFinalizeTimer`
   so the backstop re-arms for the fresh fit cycle.

5. Cancel `_forceFinalizeTimer` in `dispose()`.

6. Validate: `dart analyze` (or `flutter analyze`) on triage_client; build the
   web client if feasible. Manual: load app, tap a session that has history,
   confirm history renders on first show without switching/resizing.

## Notes

- Deadline of 800ms > the 600ms retry but comfortably within perceptible load.
  It only fires when the stability path failed, so it does not delay the normal
  case (which finalizes via the 250ms debounce once size settles).
- The backstop uses `_lastFittedCols/_lastFittedRows`, which are set on every
  valid fit (line ~640), so they reflect the most recent real size.
