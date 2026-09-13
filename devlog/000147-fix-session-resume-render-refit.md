# 000147: fix/session-resume-render-refit

**Agent:** Antigravity (Gemini 3.8 Flash) @ triage branch fix/session-resume-render-refit

## Intent

Resolve terminal rendering and layout corruption when resuming sessions (especially Codex CLI interactive prompts and questions) and fix the bug where tapping refit snaps the terminal scrollback to the top.

## What Changed

- `2026-09-13T07:55-0400 devlog/plans/000147-01-session-resume-render-refit.md`: Authored implementation plan for fixing session resume refit, web ResizeObserver lifecycle, and refit scroll snap to top.
- `2026-09-13T08:04-0400 flutter/triage_client/lib/widgets/terminal_pane_web.dart`: Extracted _setupResizeObserver helper, called _triggerFitWithDelayedRetries and post-frame _onFit on cached container adoption in initState, checked wasAtBottom, suppressed scroll saving across fit and refit passes, cleared _sessionSavedViewportY and scrolled to bottom when at bottom, and repainted rows with term.refresh.
- `2026-09-13T08:04-0400 flutter/triage_client/lib/widgets/terminal_pane_stub.dart`: Bound widget.controller.addRefitListener and removeRefitListener in initState, didUpdateWidget, and dispose, and added _onRefit to rebuild and align scroll position with _scrollToCursor(requestFocus: false).
- `2026-09-13T08:04-0400 flutter/triage_client/lib/main.dart`: Added post-frame callback in _selectSession under kIsWeb to refit active session when switching back to an already-fitted session, automatically re-measuring and prompting child CLIs to redraw via SIGWINCH without manual refit button clicks.
- `2026-09-13T08:04-0400 flutter/triage_client/test/widget_test.dart`: Added widget tests verifying that tapping the refit button while at the bottom preserves bottom scroll without jumping to top, and that controller refit triggers the pane refit listener and maintains bottom stickiness.

## Decisions

- 2026-09-13T07:55-0400 Suppress scroll save and preserve bottom viewport during web refit: In xterm.js, resizing during FitAddon reflow triggers transient scroll events with unadjusted scroll tops. Suppressing scroll saves and enforcing bottom stickiness when the terminal was at the bottom prevents refit from saving line 0 and jumping to the top.
- 2026-09-13T07:55-0400 Re-attach ResizeObserver on cached container adoption in web terminal pane: When switching away from a session, dispose disconnects the observer. Re-attaching the observer on container adoption ensures that as soon as the element receives layout dimensions in the DOM, it fits automatically.
- 2026-09-13T07:55-0400 Schedule automatic refit post-frame on session selection in main.dart: When resuming an already-fitted session, scheduling an automatic refit ensures the terminal emulator re-measures its visible container and dispatches a SIGWINCH resize jiggle to the host, forcing interactive tools like Codex to redraw their question prompts cleanly without requiring manual button taps.

## Issues

- 2026-09-13T07:55-0400 Refit button snaps to top: Diagnosed that during FitAddon.fit in xterm.js, viewport scrollTop and scrollHeight are momentarily out of sync. onScrollCallback saw viewportY < baseY, saved line 0 to _sessionSavedViewportY, and refocus invoked scrollToLine(0). Resolved by tracking wasAtBottom, suppressing scroll saves across fit passes, and clearing saved viewport when at bottom.
- 2026-09-13T07:55-0400 Layout corruption on session resume: Diagnosed that cached containers on web had their ResizeObserver disconnected on session switch and never re-attached on resume, leaving clientWidth 0 on initial fit and missing all subsequent DOM resizes. In addition, resuming an existing session never sent SIGWINCH to the host, leaving background-rendered CLI prompts corrupted until a manual refit. Resolved by re-binding ResizeObserver, adding delayed retry ladders on adoption, and scheduling automatic refit on session resume.

## Commits

- HEAD: fix(terminal): resolve session resume layout corruption and refit snap to top
