# 000160-01: Shift+Enter sends LF

## Thinking

Both panes send CR for Shift+Enter today (web: the capture listener
maps every non-Alt Enter to `\r`; native: the key falls through to
xterm's handler, which ignores shift), so apps read it as submit.
Raw-mode apps distinguish CR (submit) from LF (newline insert), and
cooked shells accept both identically, so sending `\n` for
Shift-with-no-other-modifier is the correct, degradation-safe encoding.
The Alt+Enter ESC+CR branch and plain-Enter defaults stay untouched.

## Plan

1. Add `bytesForEnterKey` to `lib/terminal/control_bytes.dart` (the
   existing shared key-byte helper): `\n` for shift-only, null to keep
   the default path.
2. Unit-test the helper for every modifier combination.
3. Native: intercept Enter/numpadEnter in `_handleTerminalKeyEvent`;
   send on non-null, else fall through to xterm.
4. Web: use the helper in the capture listener's Enter branch.
5. Widget-test Shift+Enter (sends `\n`) and plain Enter (sends nothing
   from our layer) on the native pane.
6. `flutter analyze`, `flutter test`, commit, push with explicit
   refspec, stacked PR on 187, extend the gh-stack tracking.
