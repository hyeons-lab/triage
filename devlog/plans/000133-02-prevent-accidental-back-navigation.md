# Plan: Prevent Accidental Back Navigation and Prompt on Webapp Exit

## Thinking

In web browsers (especially on macOS trackpads and mobile browsers), scrolling or overscrolling down/horizontally at the boundary of a scroll view or terminal can easily trigger the browser's default gesture for history back navigation, immediately leaving the web application and dropping active sessions.

To address this issue thoroughly and robustly:
1. **Prevent scroll/swipe back navigation**:
   Configure CSS `overscroll-behavior: none` on `html`, `body`, and `.xterm-viewport` in `web/index.html` and `web/xterm.css`. This tells the browser engine to disallow chaining boundary scroll gestures into history navigation or pull-to-refresh.

2. **Intercept back navigation and prompt the user**:
   Wrap the root scaffold in `PopScope` within `_MainState` in `lib/main.dart`.
   When a back navigation is triggered (browser back button, mouse back button, keyboard shortcut, or mobile back gesture), `PopScope` intercepts the pop when `canPop` is false.
   Present a styled `AlertDialog` ("Exit Triage?") asking the user to confirm whether they want to leave Triage and go back to the previous page.
   - If the user selects "Stay", dismiss the dialog and remain on the page.
   - If the user selects "Leave", set `_allowExit = true`, invoke `allowWebExit()` to prevent a secondary browser dialog, and invoke `SystemNavigator.pop()`.

3. **Browser Unload Guard (`beforeunload`)**:
   Add a `beforeunload` listener in `web/index.html` as a fallback for direct tab closes or browser-level page unloads. Integrate `allowWebExit()` in `platform_env_web.dart` (and a no-op in `platform_env_io.dart`) to allow intentional exits without double-prompting.

4. **Testing and Verification**:
   Add widget tests in `test/widget_test.dart` validating that `handlePopRoute()` triggers the confirmation dialog, selecting "Stay" leaves the app running, and selecting "Leave" allows the exit. Verify all existing tests, formatting, and clippy checks pass.

## Plan

1. **CSS Overscroll Mitigation**:
   - Update `flutter/triage_client/web/index.html` to add `overscroll-behavior: none`, `overscroll-behavior-y: none`, and `overscroll-behavior-x: none` to `html, body`.
   - Update `flutter/triage_client/web/xterm.css` to add `overscroll-behavior: none` to `.xterm-viewport`.

2. **Platform Environment Exit Handlers**:
   - Add `void allowWebExit()` in `flutter/triage_client/lib/platform_env_io.dart` (no-op).
   - Add `void allowWebExit()` in `flutter/triage_client/lib/platform_env_web.dart` updating `window._allowUnload`.
   - Add `beforeunload` script in `flutter/triage_client/web/index.html` guarded by `window._allowUnload`.

3. **Flutter PopScope and Confirmation Dialog**:
   - In `flutter/triage_client/lib/main.dart`, wrap root scaffold in `PopScope`.
   - Implement `_showExitConfirmationDialog()` and `_handlePopInvoked()`.

4. **Test Suite**:
   - Add widget tests in `flutter/triage_client/test/widget_test.dart` covering back navigation prompt and both user choices (Stay / Leave).
   - Run `flutter test` and workspace checks (`cargo fmt`, `cargo clippy`, `cargo test`).

5. **Devlog and Git Push**:
   - Update `devlog/000133-feat-siderail-custom-label.md`.
   - Commit and push to `feat/siderail-custom-label`.
