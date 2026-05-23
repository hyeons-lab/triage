## Thinking

The goal is to integrate `xterm.js` into the Flutter Web client (`experiment/flutter-spike`). We have already downloaded `xterm.js` (5.5.0), `xterm.css`, and the `xterm-addon-fit` (0.10.0) locally to `web/` to comply with the `--no-web-resources-cdn` environment constraint.

We need to:
1. Reference the local assets in `web/index.html`.
2. Design a platform-branched widget boundary for `TerminalPane`. We'll use conditional imports so that compiling for native targets doesn't crash on web-specific imports (`dart:html`, `dart:ui_web`).
3. Define the interface `TerminalController` to allow the parent UI to send incremental writes, clear terminal state, and request resize events.
4. Implement `TerminalPaneWeb` which instantiates `Terminal` and `FitAddon` via `dart:js_util` and manages the `HtmlElement` life-cycle.
5. Store terminal controllers/elements per-session to prevent re-rendering scrollback from scratch on tab switches.

## Plan

- Update `web/index.html` to reference `xterm.css`, `xterm.js`, and `xterm-addon-fit.js`.
- Design the platform-branched boundary for `TerminalPane` using conditional imports:
  - `lib/widgets/terminal_pane.dart` (common interface & conditional exports)
  - `lib/widgets/terminal_pane_stub.dart` (fallback implementation for testing/native)
  - `lib/widgets/terminal_pane_web.dart` (web implementation using `xterm.js` and `dart:js_util`)
- Create a `TerminalController` inside `terminal_pane.dart` to decouple terminal actions (write, resize, clear) from the widget tree.
- Wire `TerminalController` into `SessionVm` or `_ArgusHomeState` so incoming WebSocket output events write directly to the terminal.
- Re-run widget tests and static analysis.
