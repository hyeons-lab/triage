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
- `2026-09-13T08:17-0400 devlog/plans/000147-01-session-resume-render-refit.md`: Updated plan with staggered PTY jiggle, container adoption refit, and buffer clear details.
- `2026-09-13T08:17-0400 flutter/triage_client/lib/widgets/terminal_pane_web.dart`: In _onClear, wrote escape sequence \x1b[H\x1b[2J\x1b[3J to erase the active screen buffer and reset the cursor to home alongside term.clear; on cached container adoption in initState, called _onRefit; in _refitAndSend, restored saved viewport offset via scrollToLine when not at bottom, avoided latching _lastRefitCols and _lastRefitRows when DOM width or height is 0, and staggered the restoring sendResizeOut(targetId, cols, rows) by 60ms after rows - 1 to guarantee distinct SIGWINCH delivery to the host.
- `2026-09-13T08:17-0400 flutter/triage_client/lib/main.dart`: Scheduled post-frame _refitActiveSession in _connectWebSocket under kIsWeb after daemon sessions finish loading.
- `2026-09-13T08:54-0400 flutter/triage_client/lib/widgets/terminal_pane_web.dart`: Tracked _jiggleRestoreTimer, _pendingJiggleCols, _pendingJiggleRows, and _pendingJiggleTargetId, flushed pending restore in didUpdateWidget and dispose prior to route unbinding to prevent PTY stranding, shifted refit retry ladder to [120, 300, 700, 1500] outside the 60ms jiggle window, tracked retries in _refitRetryTimers, guarded zero DOM dimensions in _refitAndSend before refresh and resize, reset _lastRefitCols and _lastRefitRows on refit, cancelled _resizeDebounceTimer in _refitAndSend, re-attached _setupResizeObserver on cached container adoption in initState, restored non-bottom lines in _onFit via scrollToLine, and added alternate buffer exit \x1b[?1049l in onClear.
- `2026-09-13T08:54-0400 flutter/triage_client/lib/main.dart`: Guarded post-frame refit callback in _connectWebSocket with generation == _connectGeneration and serverId == _activeServerId.

## Decisions

- 2026-09-13T07:55-0400 Suppress scroll save and preserve bottom viewport during web refit: In xterm.js, resizing during FitAddon reflow triggers transient scroll events with unadjusted scroll tops. Suppressing scroll saves and enforcing bottom stickiness when the terminal was at the bottom prevents refit from saving line 0 and jumping to the top.
- 2026-09-13T07:55-0400 Re-attach ResizeObserver on cached container adoption in web terminal pane: When switching away from a session, dispose disconnects the observer. Re-attaching the observer on container adoption ensures that as soon as the element receives layout dimensions in the DOM, it fits automatically.
- 2026-09-13T07:55-0400 Schedule automatic refit post-frame on session selection in main.dart: When resuming an already-fitted session, scheduling an automatic refit ensures the terminal emulator re-measures its visible container and dispatches a SIGWINCH resize jiggle to the host, forcing interactive tools like Codex to redraw their question prompts cleanly without requiring manual button taps.
- 2026-09-13T08:17-0400 Stagger PTY jiggle by 60ms: When sendResizeOut(cols, rows - 1) and sendResizeOut(cols, rows) were sent back-to-back in the same microtask, POSIX kernels coalesced the pending SIGWINCH signals. Node.js (used in interactive CLIs like Codex and Ink) processed TIOCGWINSZ after rows had already returned to its original value, suppressing the resize event. Staggering the restoration by 60ms ensures two separate signals are handled, forcing Ink to re-measure and redraw.
- 2026-09-13T08:17-0400 Wipe active screen buffer on clear: xterm.js term.clear only deletes lines from scrollback above the viewport, leaving active rows and cursor coordinates untouched. Writing \x1b[H\x1b[2J\x1b[3J in onClear wipes active screen lines before history replay, preventing text duplication.
- 2026-09-13T08:17-0400 Defer refit size latching until DOM layout has non-zero dimensions: When adopting or mounting, clientWidth and clientHeight can briefly report 0. Not latching _lastRefitCols when dimensions are 0 allows subsequent retry passes to execute once the DOM settles.
- 2026-09-13T08:54-0400 Flush pending PTY restore before unbinding input routes: When dispose or didUpdateWidget unbinds a controller from _sessionInputRouter, any pending jiggle restore must be flushed beforehand, otherwise _routes no longer contains the session id and the restoring resize is dropped.
- 2026-09-13T08:54-0400 De-overlap refit retry ladder from jiggle duration: Shifting retry ladder intervals to [120, 300, 700, 1500] prevents the first retry from firing during the 60ms jiggle cycle, avoiding signal coalescing when initial DOM layout is 0ms.
- 2026-09-13T08:54-0400 Reset last refit dimensions at the start of each refit generation: When resuming from sleep with zero initial dimensions, clearing _lastRefitCols and _lastRefitRows allows the first retry that measures positive dimensions to send the SIGWINCH jiggle.

## Issues

- 2026-09-13T07:55-0400 Refit button snaps to top: Diagnosed that during FitAddon.fit in xterm.js, viewport scrollTop and scrollHeight are momentarily out of sync. onScrollCallback saw viewportY < baseY, saved line 0 to _sessionSavedViewportY, and refocus invoked scrollToLine(0). Resolved by tracking wasAtBottom, suppressing scroll saves across fit passes, and clearing saved viewport when at bottom.
- 2026-09-13T07:55-0400 Layout corruption on session resume: Diagnosed that cached containers on web had their ResizeObserver disconnected on session switch and never re-attached on resume, leaving clientWidth 0 on initial fit and missing all subsequent DOM resizes. In addition, resuming an existing session never sent SIGWINCH to the host, leaving background-rendered CLI prompts corrupted until a manual refit. Resolved by re-binding ResizeObserver, adding delayed retry ladders on adoption, and scheduling automatic refit on session resume.
- 2026-09-13T08:17-0400 Duplicate text blocks in Codex CLI: Diagnosed that immediate PTY jiggle resizes were coalesced by the host kernel, preventing Node.js/Ink from detecting the window size change and refreshing DECSTBM scroll margins. As a result, cursor positioning sequences drew over existing text, producing duplicate blocks. Resolved by adding a 60ms delay before restoring rows and clearing the active screen buffer on history replays.
- 2026-09-13T08:17-0400 Native test failure on session selection: Guarded post-frame refit calls with kIsWeb so desktop/native platforms (which auto-fit via TerminalView and test mock assertions) are not subjected to redundant PTY jiggles.
- 2026-09-13T08:54-0400 PTY stranding hazard on unmount during jiggle: Identified that if a pane was disposed within the 60ms jiggle window, unmanaged delayed futures bailed out on unmount, leaving the remote PTY at rows - 1. Resolved by tracking timers and flushing pending restores synchronously before route destruction.
- 2026-09-13T08:54-0400 Resumed sessions missing window resize events: Identified that cached containers had their ResizeObserver disconnected on session switch and never re-bound on resume. Resolved by calling _setupResizeObserver on cached container adoption in initState.

## Commits

- b6eb059: fix(terminal): resolve session resume layout corruption and refit snap to top
- ab85b52: fix(terminal): eliminate duplicate text blocks on session resume via staggered pty jiggle and buffer clear
- HEAD: fix(terminal): harden web refit lifecycle, prevent pty stranding, and rebind resize observer
