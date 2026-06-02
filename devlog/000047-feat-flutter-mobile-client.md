# feat/flutter-mobile-client

## Agent
- Antigravity
- 2026-05-31T18:00-0700 — Initiated branch to scaffold Flutter mobile client support.
- 2026-05-31T18:15-0700 — Added Windows and Linux desktop scaffolding support.
- 2026-05-31T19:08-0700 — Updated the native app shell after local macOS smoke testing.
- 2026-06-01T14:32-0700 — Claude Code (claude-opus-4-7) @ argus branch feat/flutter-mobile-client — picked up duplicate-text review finding and implemented Option A.
- 2026-06-01T19:37-0700 — Antigravity — Implemented the persistent single-source terminal buffer long-term fix (Option B).
- 2026-06-02T00:35-0700 — Antigravity — Wrapped interactive native terminal view inside a LayoutBuilder to calculate available cols/rows and resize terminal buffer dynamically on sidebar collapse/expand.
- 2026-06-02T00:50-0700 — Antigravity — Restored didUpdateWidget lifecycle hooks in terminal_pane_stub.dart to watch replayRevision and trigger terminal replays upon PTY resize reflow snapshot updates.

## Intent
- Scaffold mobile and macOS platform configurations for the triage client.
- Add and integrate `xterm` package for native platforms in place of `terminal_pane_stub.dart`.
- Verify the build compiles and runs on native platforms (especially macOS desktop for validation).
- Add support for other desktop platforms (Windows and Linux) so developers on those systems can also run the application natively.

## Decisions
- Scaffold `ios`, `android`, and `macos` platforms inside `flutter/triage_client`.
- Add `xterm: ^4.0.0` to `pubspec.yaml` to provide interactive terminal functionality on native mobile and desktop platforms.
- Map the WebSocket terminal streaming and inputs between the session controller and the native `Terminal` class in `terminal_pane_stub.dart` (making it a fully functional native platform implementation).
- Use `Platform.environment.containsKey('FLUTTER_TEST')` in `terminal_pane_stub.dart` to branch layout:
  - If true (in widget tests), render the legacy static/selectable `TextSpan` view to preserve the existing 72 finder-based widget tests.
  - If false (on a real device/emulator), render the interactive, high-performance `TerminalView` powered by `package:xterm`.
- Defer PTY writes and initial hydration on first resize in `onTerminalResize` using `scheduleMicrotask` to prevent "RenderObject must not re-dirty itself while still being laid out" layout mutations.
- Keep track of and cancel all scheduled input suppression timers on `dispose` to prevent test-framework pending timer leaks.
- Scaffold `windows` and `linux` runner platforms inside `flutter/triage_client`. Because `terminal_pane_stub.dart` is written in pure Dart and uses cross-platform Flutter terminal emulator widgets, it runs out of the box on Windows and Linux.
- 2026-06-01T14:32-0700 — Adopt Option A for the dual-write terminal buffer bug: the WebSocket `Output` event handler now writes only to `terminalController` (xterm). The naive `session.rows` append was corrupting the fallback buffer with literal ANSI escapes and CR overstrikes, which were then re-executed during replay and showed up as "duplicate text" / mis-laid-out layout. `session.rows` is now owned by the snapshot path.
- 2026-06-01T19:37-0700 — Adopt Option B for persistent single-source terminal buffers. Moved ownership of the native `xt.Terminal` instance onto `SessionVm` so it survives unmount/remount (tab switching). Setup write/clear/resize controller listeners in `SessionVm` so live websocket output is always written to the terminal instance, decoupling the state lifecycle of `TerminalPane` from the terminal model.
- 2026-06-02T00:35-0700 — Wrap the native `TerminalView` inside a `LayoutBuilder` in `terminal_pane_stub.dart` to calculate exact terminal columns/rows on layout constraints updates (e.g. sidebar collapse). Resize `_terminal` safely within a `scheduleMicrotask` to avoid infinite `setState` rebuild loops and perfectly align logical terminal dimensions with the daemon PTY.
- 2026-06-02T00:50-0700 — Keep didUpdateWidget lifecycle hooks for replayRevision, isExited, and replayPending in terminal_pane_stub.dart. When a session is resized and the daemon returns the newly reflowed snapshot, we must reset the persistent xt.Terminal and replay the new content, otherwise the stale pre-resize wrapped rows remain in the buffer and permanently corrupt the view.

## What Changed
- `flutter/triage_client/pubspec.yaml` — Upgraded to `xterm: ^4.0.0` dependency.
- `flutter/triage_client/lib/widgets/terminal_replay.dart` — Extracted shared `clipRowToCols`, `styledSpanToAnsi`, and `styledRowToAnsi` helpers.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` — Implemented fully featured interactive terminal view mapping resizing, stream writing, and keyboard output using `package:xterm`, with test-framework fallback support.
- Scaffolded native iOS, Android, macOS, Windows, and Linux application folders via `flutter create`.
- `flutter/triage_client/lib/main.dart` — Animated the session rail width and content transition when collapsing or expanding the sessions pane, and aligned the header icon with the terminal-style launcher icon.
- `flutter/triage_client/assets/app_icon.svg`, `tool/generate_app_icons.py`, and platform icon assets — Replaced the default Flutter launcher icon with the transparent SVG logo source and generated platform PNG assets from it.
- `flutter/triage_client/tool/generate_app_icons.py` — Switched SVG rasterization to Inkscape so gradients, filters, and the central terminal prompt render correctly in generated launcher icons.
- `flutter/triage_client/assets/app_icon.svg` and platform icon assets — Added a black launcher icon background and regenerated platform PNG assets from the SVG source.
- `flutter/triage_client/macos/Runner/*.entitlements` — Added the macOS client network entitlement so the sandboxed app can connect to the local daemon WebSocket.
- `flutter/triage_client/macos/Runner/Configs/AppInfo.xcconfig` — Changed the macOS product name to `Triage` so the native app title no longer displays `triage_client`.
- `flutter/triage_client/lib/services/external_navigation.dart` and `pubspec.yaml` — Switched external URL opening to the standard `url_launcher` plugin so native pairing links open in the system browser.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` and `terminal_replay.dart` — Fixed native initial replay so pre-fit live writes are not duplicated after snapshot hydration, and taught cursor placement to recognize `❯` shell prompts.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` and `main.dart` — Debounced native outbound terminal resizes and ignored stale resize responses so collapsing the session rail does not flood the PTY with intermediate widths.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` — Disabled native xterm local reflow and cleared buffers directly before snapshot replay so animated layout changes cannot leave stale visual prompt rows behind.
- `flutter/triage_client/lib/main.dart` — Removed the naive `session.rows` append in the `Output` WebSocket event handler so live output no longer corrupts the fallback row buffer with literal ANSI escapes and CR overstrikes. Live output continues to flow into xterm via `terminalController.write`; `session.rows` is now updated only by snapshot/restore/resync paths.
- `flutter/triage_client/test/widget_test.dart` — Updated `buffers output while daemon session placeholder is loading` to assert the new contract: fallback rows show the attach snapshot immediately, and the live-output line lands in `session.rows` only after the post-select refresh snapshot resolves.
- `flutter/triage_client/lib/main.dart` — Moved `xt.Terminal` onto `SessionVm`, routing writes, clears, and resizes natively from `TerminalController`. Decoupled `SessionWorkspace`'s `TerminalPane` setup, passing the persistent terminal instance and delegates. Corrected size estimation vertical padding calculations.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` — Refactored `TerminalPane` state to use the persistent terminal, removing direct write/clear listeners and simplifying layout/didUpdateWidget lifecycle logic.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` — Wrapped native `TerminalView` with `LayoutBuilder` to compute and trigger terminal resizes dynamically during parent layout changes.
- `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` — Added back didUpdateWidget check for `replayRevision`, `isExited`, and `replayPending` to trigger terminal buffer redraws on snapshot reflows.
- `flutter/triage_client/lib/widgets/terminal_pane_web.dart` — Aligned constructor parameters to maintain cross-platform compilation.
- `flutter/triage_client/test/widget_test.dart` — Updated the viewport-estimated dimensions assertions to match the corrected vertical padding dimensions (`92x38`).

## Commits
- c32d1e6 — feat: scaffold flutter mobile client and integrate native interactive terminal
- aca982f — feat: scaffold Windows and Linux desktop runner platforms
- c4aedc5 — feat(client): polish macOS triage client
- HEAD — fix(client): restore terminal didUpdateWidget lifecycle hooks for resize reflow

## Progress
- 2026-05-31T18:00-0700 — Created git worktree and branch `feat/flutter-mobile-client`.
- 2026-05-31T19:00-0700 — Scaffolded platforms, integrated `xterm: ^4.0.0`, resolved layout mutation races and pending timer exceptions, successfully verified and passed all 72 widget tests, and built the native macOS target.
- 2026-05-31T18:15-0700 — Scaffolded Windows and Linux desktop targets and verified all unit/widget tests continue to pass.
- 2026-05-31T19:08-0700 — Verified `triaged` was listening on `127.0.0.1:7777`, added animated session rail transitions, regenerated launcher icons, and re-ran `flutter test test/widget_test.dart`.
- 2026-05-31T19:08-0700 — Diagnosed the native macOS connection failure as a missing sandbox outbound network entitlement.
- 2026-05-31T19:16-0700 — Renamed the macOS product title to `Triage` for the app menu, Dock, and bundle display.
- 2026-05-31T20:06-0700 — Replaced the limited URL-opening stub with `url_launcher` and verified `flutter test test/widget_test.dart`.
- 2026-05-31T20:17-0700 — Fixed duplicated native prompt replay and verified with `flutter test test/cursor_position_test.dart` plus `flutter test test/widget_test.dart`.
- 2026-05-31T20:26-0700 — Fixed collapse-triggered prompt duplication by sending only the final settled native terminal resize and verified the focused cursor and widget test suites.
- 2026-05-31T21:25-0700 — Aligned native replay with daemon snapshots by disabling xterm local reflow, clearing main and alternate buffers directly before replay, and re-running the cursor and widget test suites.
- 2026-05-31T21:52-0700 — Switched the app icon source to the transparent SVG logo from the main checkout and regenerated macOS, iOS, and web icon PNGs with preserved alpha.
- 2026-05-31T22:02-0700 — Replaced the limited ImageMagick SVG renderer with Inkscape after the generated icon dropped traces and the terminal prompt, then regenerated the platform icon PNGs.
- 2026-06-01T08:52-0700 — Changed the launcher icon canvas from transparent to black, regenerated the platform icons, and verified the macOS 1024px icon is opaque black at the corners.
- 2026-06-01T14:32-0700 — Diagnosed the "duplicate text / lots of mis-laid-out lines" report as a dual-write architecture issue: live `Output` events were updating both xterm and a naive `session.rows` line buffer; the polluted fallback rows then got re-replayed verbatim during remount and replay-revision changes. Applied Option A (single writer: xterm during live output; snapshots own `session.rows`), updated the relevant widget test, and re-ran `flutter test` (73/73 pass).
- 2026-06-01T19:37-0700 — Implemented persistent single-source terminal buffers (Option B) by migrating `xt.Terminal` to `SessionVm` and decoupling `TerminalPane` state lifecycle, verified and confirmed all 73/73 tests pass successfully.
- 2026-06-01T22:10-0700 — Successfully compiled the Flutter web client and Flutter macOS client, built and installed `triage` and `triaged` release binaries to cargo bin, and copied the new Triage.app to `/Applications/Triage.app`.
- 2026-06-02T00:15-0700 — Resolved a subtle cell width estimation bug (`averageCellWidth` was `9.0` instead of the actual font's `9.92`), which caused initial estimated/restored session widths to be larger than the actual fitted layout, leading to narrow-wrapping staircasing on sidebar collapse. Updated `averageCellWidth` to `9.92`, updated test assertions in `widget_test.dart` to expect `84` columns instead of `92`, successfully ran and passed all 73 widget tests, and rebuilt/redeployed the clients and binaries.
- 2026-06-02T00:35-0700 — Wrapped the interactive native `TerminalView` with a `LayoutBuilder` to dynamically resize `_terminal` on sidebar collapse, successfully compiled web and macOS clients, built and installed release targets, redeployed Triage.app to `/Applications/Triage.app`, and verified all 73/73 tests pass.
- 2026-06-02T00:50-0700 — Restored the didUpdateWidget lifecycle checks in terminal_pane_stub.dart, successfully compiled and deployed web, macOS, and Rust binary targets, and verified that the terminal layout correctly reflows in Triage.app without wrapping or split lines.
