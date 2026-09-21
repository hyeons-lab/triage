# 000152-01 — reconciliation-and-carry-fix

## Thinking

Bug A is a stuck state, not a single broken call: the web term sits at 46
cols, the PTY at 80, the pane at ~110, and no trigger reconciles them while
the tab stays focused. The initial 46 is unknowable post-hoc (narrow-layout
moment, font-fallback metrics, or one of several silent forward drops), so
the fix must make the stuck state unrepresentable going forward rather than
replay one hypothesized drop:

- The pane must re-assert grid==pixels at every point where layout may have
  settled since the last fit: after history replay lands, on session
  (re)select with a cached term, and when webfonts finish loading (cell
  metrics change with no pixel change, so the ResizeObserver never fires).
- A fit that lands just before unmount must not die in the 100 ms debounce:
  flush it synchronously in `dispose` (safe — routes are per-session-id, so a
  same-id rebind receives its own size and a destroyed session no-ops).
- The VM-level reclaim (`_reclaimTerminalSizeIfDrifted`, foreground path)
  must also fire when the term's *actual* grid (via the existing
  `getCachedTerminalSize`) disagrees with the host, not only when the host
  disagrees with the last size this device *sent*. That is the exact blind
  spot the diagnosed state sits in (term 46, host 80, own 80).

All of these reuse existing machinery (`_onFit`, `_onRefit` force-send,
`sendResizeOut`, the foreground reclaim) and keep every existing guard
(size-changed checks, the foreground gate, the jiggle dedup), so a healthy
session performs no extra resizes.

F1 is independent and synchronous: `_reduceHistory` cancels the carry
watchdog via `_closeSyncBlockAndFlush` after `_writeDecoded` may have armed
it, stranding a trailing partial escape until the next live chunk (or
forever on idle sessions). Flushing the carry at end of replay through the
watchdog's own path restores the every-byte-reaches-sink invariant; empty
carry is a no-op. Regression test: history ending mid-escape, no live
follows, assert the sink holds every byte with no timer wait.

## Plan

1. `terminal_store.dart`: extract the watchdog's carry flush into
   `_flushEscapeCarry()`; call it at the end of `_reduceHistory` after
   `_closeSyncBlockAndFlush()`. No other call-site changes.
2. `terminal_store_test.dart`: add a regression test pinning F1 (history
   tail cut mid-escape + no live → sink byte-complete synchronously).
3. `terminal_pane_web.dart`:
   a. `_onHistoryReplayed`: schedule a post-frame reconcile (fit from real
      pixels; send resize-out when the grid disagrees with the proposal,
      bypassing the debounce).
   b. Fresh-term init: one-shot `document.fonts.ready.then(...)` → `_onFit()`
      so a font-fallback fit is re-measured once webfonts land.
   c. `dispose()`: synchronously flush a pending debounced resize-out.
4. `main.dart`: extend the foreground reclaim to also compare the cached web
   term grid against the host size (web only; native `TerminalView` auto-fit
   already owns its grid).
5. Validate: `flutter test` (full client suite), `flutter analyze`,
   `dart format` on touched files; `cargo fmt --check` for the untouched
   Rust side (should be a no-op) — plus the repo's clippy gate if time is
   cheap. Update this devlog, commit, push with explicit refspec, open PR.
6. Report manual-verification steps (hard-refresh, stuck-session heal check)
   and the two T2 questions in the PR description and the final message.
