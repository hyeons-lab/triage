# 000144-12: Fix the pane binding to a stale TerminalController on session swap

## Thinking

After the `output_seq` epoch fix and two xterm.dart fixes, every session rendered blank.
Four hypotheses were wrong before the pipeline was instrumented, and each was killed by
measurement rather than by reading:

- **`output_seq` defaulting to 0.** Live `Output` events carry `self.output.output_seq`,
  the same monotonic counter the snapshot reports, and `readUint64` decodes it exactly.
- **The store.** Driven with a real 366KB capture it renders 347K chars of history,
  applies live chunks, and survives a re-select without a fresh `Attach`.
- **Main-thread starvation from the xterm fix.** With `SessionVm`'s settings
  (`maxLines: 50000`, `reflowEnabled: true`) history writes in 48ms, live chunks in
  4-48 *micro*seconds, and reflow in 1ms.
- **The epoch fix itself.** A bisect build with the store reverted and both xterm fixes
  kept was still blank, and the rolled-back embedded bundle — which predates every change
  in this branch — was blank too.

Instrumenting the five seams the bytes cross (store, sink, controller, pane, xterm.js)
answered it on the first run. On a blank session:

```
pane.bind     | triage___session-201 BIND ctrl#92859691
ctrl.addWrite | ctrl#92859691 now 2 listeners      <- pane wired here
ctrl.addWrite | ctrl#250931763 now 1 listeners     <- new controller
vm.applyHistory | triage / session-201 1165788B seq=163
sink.write    | ctrl#250931763 3021B ...           <- store writes HERE
```

Two different `TerminalController` instances, and no `pane.didUpdate` line at all.
`_loadDaemonSessionInto` replaces the placeholder `SessionVm` with the real one, and the
replacement constructs its own controller in its initializer. The mounted pane is not
necessarily rebuilt by that `setState`, and without a rebuild `didUpdateWidget` never
fires, so the pane keeps listening to the placeholder's controller while the store writes
to the new one. Everything upstream is correct — the emulator is created, history is
replayed, bytes are decoded — and they land on a controller nobody is listening to.

`flutter-spike` rendered throughout because it is a local session that is never swapped:
its bind and its writes were both `ctrl#437865805`. That is why the fault looked like it
tracked session *content* (Codex, then Antigravity) rather than session *lifecycle*.

The rebind cannot be hung off the widget lifecycle, because the case that breaks is
exactly the one where no rebuild happens. It has to be reachable by session id.

Two aggravating factors made three different root causes present identically as "blank",
and both are worth removing regardless:

1. `TerminalController.write` iterated its listeners unguarded. xterm.dart is listener #0
   and xterm.js is #1, so *any* throw in the emulator stopped the pane from ever being
   written. Both xterm bugs fixed earlier in this branch reached the user this way.
2. `onWrite` wrapped its xterm.js call in `catch (_) {}`, so a write that threw left a
   blank pane and a clean console — indistinguishable from bytes that never arrived.

## Plan

1. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Make the persistent binder addressable by session id
     (`_bindPersistentSessionControllerFor(sanitizedId, controller)`), keeping the
     instance method as a wrapper.
   - Add `TerminalPane.rebindSessionController(terminalId, controller)`, which re-points
     the persistent write/clear listeners and, when a pane is mounted for that id, moves
     its view listeners via `_rebindViewListenersTo` (tracked by `_boundViewController`).
   - Log the swallowed xterm.js error instead of discarding it.
2. In `terminal_pane_stub.dart`: a no-op `rebindSessionController`, so callers need no
   platform branch. The native pane binds through the widget tree, where a controller
   swap arrives with the rebuild.
3. In `terminal_pane.dart`: isolate write listeners so one throwing consumer cannot stop
   the others.
4. In `main.dart`: call `TerminalPane.rebindSessionController` at the swap site in
   `_loadDaemonSessionInto`, after `_sessions[existingIndex] = session`.
5. Add `lib/terminal/debug_log.dart` — a `kTerminalDebug`-gated `TDBG` trace across the
   five seams. Left in, switched off: the seams that hid this are still seams.
6. Restore the epoch fix reverted during the bisect, and verify: `flutter analyze`,
   455 tests, and a real reload.
