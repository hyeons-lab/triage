# Plan 000091-01 — Fix mobile scroll stealing focus / raising the soft keyboard

## Thinking

Symptom (mobile): scrolling up through the terminal scrollback keeps giving the
text input focus, which raises the soft keyboard. The keyboard forces the
Scaffold to inset (resize-to-avoid-bottom-inset), so the scroll position shifts
and the user has to fight the viewport while scrolling.

Root cause is in `terminal_pane_stub.dart` `_handlePointerDown`:

```dart
void _handlePointerDown(PointerDownEvent event) {
  _focusTerminal();              // fires on EVERY raw pointer-down
  if ((event.buttons & kPrimaryButton) == 0) return;
  if (_isMobile) return;         // mobile bails, but only AFTER focusing
  ...
}
```

`_handlePointerDown` is wired to `Listener.onPointerDown`, which fires at the
start of *any* pointer interaction — including the pointer-down that begins a
scroll swipe. On mobile, `_focusTerminal()` → `_focusNode.requestFocus()` puts
focus on the xterm IME connection (mobile uses `hardwareKeyboardOnly: false`),
which raises the soft keyboard. So every swipe-to-scroll re-raises the keyboard
and jumps the viewport.

The `_focusTerminal()` call there is only needed on desktop, where a mouse click
should focus the terminal before a drag-select. On mobile, tap-to-focus is
already provided by the `GestureDetector(onTap: _focusTerminal)` that wraps the
view — and a tap (not a swipe) is exactly when the keyboard *should* come up.

Fix: only focus on pointer-down for non-mobile. Mobile keeps tap-to-focus via
the gesture detector; a scroll swipe no longer touches focus, so the keyboard
stays as-is while scrolling.

Scope check: no other user-scroll path requests focus. `_onScrollChanged` only
captures the scroll anchor; `_scrollToCursor(requestFocus: true)` fires on
init / session-swap / focusCursorRevision change, not on user scroll. Desktop
behavior is unchanged (still focuses on any pointer-down).

## Plan

1. In `terminal_pane_stub.dart` `_handlePointerDown`, guard the `_focusTerminal()`
   call with `if (!_isMobile)` so it runs on desktop only; document why.
2. Validate: `flutter analyze --no-fatal-infos --no-fatal-warnings` and
   `flutter test` (mirror CI ci.yml).
3. Run `/review-fix-loop max`.
4. Devlog, commit, PR (push only after explicit confirmation).
