# 000109-01 — Show the terminal accessory-key row on the mobile web client

## Thinking

Native iOS/Android already render an on-screen accessory bar above the terminal
(`terminal_pane_stub.dart` `_buildAccessoryBar`, gated on `_isMobile`): esc, a
sticky ctrl, tab, ⇧tab, enter, arrows, ^C, and common shell symbols — the keys a
soft keyboard lacks. On the **web** client none of this exists, so a phone/tablet
browser can't send Esc/Tab/arrows/^C at all.

The web client uses a **different** widget from native: `terminal_pane.dart`
conditionally exports `terminal_pane_web.dart` (xterm.js in an `HtmlElementView`)
on web and `terminal_pane_stub.dart` elsewhere. They are mutually exclusive
conditional-import variants, so the web pane can't import the stub's bar or its
`controlByteForChar`. Adding the row to web therefore means giving the web pane
its own bar — but we want *the same* row, not a fork.

### Scope (confirmed with the user)

Show it on web **only on touch/small screens** — i.e. a mobile-OS browser
(`defaultTargetPlatform == iOS || android`), the same signal `isMobilePlatform()`
already uses. Desktop browsers keep the full-height terminal. This matches the
native gate and needs no viewport-size heuristic (which would wrongly trigger on a
narrow desktop window).

### Design: extract a shared bar, don't duplicate

1. Move `controlByteForChar` (a self-contained pure fn, today private to the stub)
   into a shared `lib/terminal/control_bytes.dart`. Both panes import it; it
   becomes VM-unit-testable in its own right.
2. Extract the row UI into a shared `TerminalAccessoryBar` widget
   (`lib/widgets/terminal_accessory_bar.dart`) taking `onSend(bytes)`,
   `onToggleCtrl()`, `ctrlArmed`. It renders the identical key list. The stub
   swaps its inline `_buildAccessoryBar`/`_accessoryKey` for it (behavior-
   preserving); the web pane uses the same widget — so "the same row" is literal.
3. Web pane wiring:
   - Port the sticky-ctrl state (`_ctrlArmed`, `_armCtrl`/`_disarmCtrl`/
     `_toggleCtrl`) and `_sendAccessory` (→ `_sendInput`, then disarm + refocus),
     mirroring the stub.
   - Fold sticky-ctrl into the next typed char at the web input choke point — the
     xterm `onData` callback in `_bindTerminalSubscriptions`: if `_ctrlArmed` and
     the chunk is a lone char, send `controlByteForChar(c)` and disarm; a
     multi-char chunk consumes+disarms without folding (identical to the stub's
     `_onTerminalOutput`).
   - `build()`: wrap the `HtmlElementView` in a `Column` — `Expanded(terminal)`
     then, when `_isMobile`, the `TerminalAccessoryBar`, padded by
     `MediaQuery.viewInsetsOf(context).bottom` so it floats above the soft
     keyboard when the browser reports the inset.

### Testability

The web pane imports `dart:js_util`/`dart:html`, so it never compiles under the
VM test runner (that's why widget tests exercise the stub). So the *shared*
pieces carry the tests: `control_bytes_test.dart` for `controlByteForChar`, and
`terminal_accessory_bar_test.dart` pumping the widget in isolation (tap esc/^C →
`onSend` bytes; tap ctrl → `onToggleCtrl`; `ctrlArmed` → active highlight). The
web-pane glue (the onData fold, the `_isMobile` gate) can't be VM-tested and is
verified by building the web bundle + manual check.

## Plan

1. `lib/terminal/control_bytes.dart` (new) — move `controlByteForChar` here.
2. `lib/widgets/terminal_accessory_bar.dart` (new) — `TerminalAccessoryBar`
   (`onSend`, `onToggleCtrl`, `ctrlArmed`) + the private key-button builder,
   rendering the exact esc/ctrl/tab/⇧tab/enter/▲▼◀▶/^C//|-~ list.
3. `terminal_pane_stub.dart` — import shared `controlByteForChar` (drop the local
   copy); replace inline bar with `TerminalAccessoryBar`. No behavior change.
4. `terminal_pane_web.dart` — sticky-ctrl state + `_sendAccessory`; fold in the
   `onData` callback; `_isMobile` getter; render the bar at the bottom of
   `build()` when `_isMobile`, padded by the keyboard inset.
5. Tests — `control_bytes_test.dart`, `terminal_accessory_bar_test.dart`.
6. Validate: `dart format`, `flutter analyze`, `flutter test`; build the web
   bundle to confirm the web pane compiles. Then `/review-fix-loop max`, then PR.
