# 000088-01 — Mobile touch input: soft keyboard + key accessory bar

## Thinking

Goal: make the native Flutter app usable from a phone (iOS + Android). The
rendering engine (`xterm.dart` via `terminal_pane_stub.dart`) already drives
desktop builds, and all six platform runners exist — but there is no
mobile-specific input path.

**The blocker.** `terminal_pane_stub.dart` passes `hardwareKeyboardOnly: true`
to `xt.TerminalView`. That flag was added to fix a *macOS desktop* IME desync
("physical key already pressed"), but it disables xterm's hidden IME
`TextInput` connection — which is the exact path that raises the **soft
keyboard** on iOS/Android. So on a phone the terminal renders and connects, but
you cannot type. Fix: make the flag platform-conditional — `true` on desktop
(keep the macOS fix), `false` on iOS/Android (use the IME → soft-keyboard path).

**Missing keys.** Soft keyboards have no Esc/Ctrl/Tab/arrows, which a terminal
needs constantly. Add a mobile-only, horizontally-scrollable **key accessory
bar** pinned below the terminal. Sticky Ctrl is applied to the next character by
intercepting `_onTerminalOutput` (soft-key input flows terminal.onOutput ->
sendInput), converting a single letter to its control code (`codeUnit & 0x1f`).

**Placement.** The bar lives in the native pane (`terminal_pane_stub.dart`), not
`SessionWorkspace` in `main.dart`, so it stays off the web client (which uses
`terminal_pane_web.dart`). Native build becomes
`Column[Expanded(terminal), if (mobile) accessoryBar]`. With
`Scaffold.resizeToAvoidBottomInset` (default true), the bar sits directly above
the keyboard; the terminal auto-fits into the remaining space.

**Focus.** Accessory taps use raw gesture handling (no focus node), and
re-request terminal focus after each tap, so tapping a key never dismisses the
keyboard.

Scope kept to input only — touch scroll/selection polish, on-device VT
validation, and push are separate PRs.

## Plan

1. In `terminal_pane_stub.dart`:
   - Add an `_isMobile` helper (`defaultTargetPlatform` iOS/Android).
   - Make `hardwareKeyboardOnly: !_isMobile`.
   - Restructure `build()` to `Column[Expanded(terminal), if (_isMobile) bar]`.
   - Implement the accessory bar (Esc, Tab, sticky Ctrl, arrows, common
     symbols, Ctrl+C) sending bytes via `widget.controller.sendInput`.
   - Intercept `_onTerminalOutput` to apply sticky Ctrl to the next char.
2. Widget test for the accessory bar's byte output + sticky-Ctrl transform
   (drive with `defaultTargetPlatform = iOS`).
3. Run `flutter analyze` + `flutter test`; build iOS + Android to confirm the
   shared codebase still compiles for both.
