# Plan: Address PR 166 Review Comments and Rebase onto origin/main

## Thinking

PR 166 (`fix/codex-session-switch-input`) addresses web terminal input loss after switching sessions. Following review feedback from Copilot and Antigravity Code Review:

1. Inline feedback from Copilot:
   - Line 377: Post-frame focus retries (50ms and 150ms) were scheduled unconditionally, causing focus churn on fresh container mounts. Retries should be limited to cached container adoption (`cachedContainer != null`) and deduplicated.
   - Line 643: `_activateTerminal()` can execute from delayed callbacks after navigating away. A route liveness check (`ModalRoute.isCurrent` or `_currentRoute?.isCurrent == false`) must guard focus requests to avoid stealing focus from newly pushed routes.

2. Antigravity Code Review:
   - Section 3 (Warnings & Correctness Risks): Intercepting window keydowns when activeElement is `<body>` or `<flt-glass-pane>` can hijack keyboard accessibility if other Flutter widgets on the same route hold focus. Navigation keys like Tab and Escape should not be intercepted, and ambient keystrokes must yield when `FocusManager.instance.primaryFocus` is held by an external Flutter widget.
   - Section 4 (Suggestions & Optimization Opportunities): Raw closures in `Future.delayed` retain `_TerminalPaneState` references in the Dart event loop, delaying garbage collection during rapid session switching. They should be converted to explicit `Timer` instances, stored in an instance field, and cancelled on `dispose()`.

3. Rebase:
   - Rebase `fix/codex-session-switch-input` onto the latest `origin/main`.

## Plan

1. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Replace raw `Future.delayed` calls with `final List<Timer> _focusRetryTimers = []` tracked on state.
   - Restrict the 50ms and 150ms retries to `cachedContainer != null` and loop through delay durations.
   - In `_activateTerminal()`, check `if (_currentRoute?.isCurrent == false) return;` before requesting Flutter or DOM focus.
   - In `_eventTargetsTerminal()`, yield if another Flutter widget holds `primaryFocus`, yield if the event is Tab or Escape from outside the terminal, and verify `_currentMountedPane` identity.
   - In `didUpdateWidget()`, ensure `_currentMountedPane = this;`.
   - In `dispose()`, cancel and clear all `_focusRetryTimers` and reset `_currentMountedPane`.
2. Synthesize learnings into `~/.gemini/review-refinements.md` under Pillar 2.
3. Validate locally:
   - `flutter analyze`
   - `flutter test`
   - `cargo fmt --all -- --check`
   - `cargo clippy --all-targets --all-features -- -D warnings`
   - `cargo test --workspace`
4. Update branch devlog `devlog/000141-fix-codex-session-switch-input.md`.
5. Commit and push to `origin/fix/codex-session-switch-input`.
6. Resolve GitHub PR review threads on PR 166.
