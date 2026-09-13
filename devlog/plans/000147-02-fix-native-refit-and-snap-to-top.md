# 000147-02: Fix Native Refit and Snap-to-Top

## Thinking

When resuming or switching to an existing session (e.g. an interactive Codex CLI session in `api-refactor`), the composer layout was covered by text until the user clicked refit, and clicking refit caused the viewport to snap to the top (line 0).

Two primary root causes were identified across both native (`terminal_pane_stub.dart`) and web (`terminal_pane_web.dart`):

1. Platform gating in `main.dart`:
   - In `_selectSession`, the post-frame `_refitActiveSession()` call was guarded by `if (kIsWeb)`. On native desktop (macOS) and mobile, selecting an already-fitted session refreshed metadata but never dispatched a refit or host PTY jiggle. Without SIGWINCH delivery, background-rendered CLI prompts (like Codex question prompts and composers) remained unaligned until manual refit clicks.
   - In native `_refitActiveSession()`, the jiggle resized to `rows - 1` and immediately to `rows` without delay. Adding a 60ms delay ensures POSIX kernels deliver distinct SIGWINCH signals to child processes rather than coalescing them.
   - In `_connectWebSocket`, post-frame refit was also restricted by `kIsWeb`.

2. Refit snap to top:
   - In `terminal_pane_web.dart`, `_onFit()` initialized `wasAtBottom = !_sessionSavedViewportY.containsKey(_sanitizedId)`. If `_sessionSavedViewportY` had previously recorded an offset (e.g. 0 during a transient resize event), `wasAtBottom` evaluated to `false` and was never updated to `true`, even if `_viewportIsAtBottom(_container, viewportY, baseY)` returned true. Consequently, `_onFit()` always executed `scrollToLine(savedY)` with line 0, permanently snapping to the top on every refit.
   - In `terminal_pane_stub.dart` (used on macOS, Android, iOS, Windows, Linux), `_onRefit()` called `setState(() {})` followed by `_scrollToCursor(requestFocus: false)`. During widget rebuild and `TerminalView` layout re-measurement, transient scroll events fired without suppression, saving `0.0` into `_sessionSavedScrollOffsets[widget.terminalId]`. When `_scrollToCursor` evaluated `wasScrolledUp`, it saw `saved != null` (0.0) or `_scrollAnchor.hasAnchor` and jumped to 0.0 rather than maintaining bottom stickiness.
   - In `terminal_pane_stub.dart`, `_scrollToCursor` lacked a bottom-stickiness check (`isCurrentlyAtBottom` or `forceBottom`) and had no scroll save suppression during refit passes.

## Plan

1. Update `terminal_pane_stub.dart`:
   - Add `_suppressScrollSave` and `_suppressScrollSaveTimer` with `_suppressScrollSaveFor(Duration)`.
   - In `_onScrollChanged()`, guard against `_suppressScrollSave`.
   - In `_onRefit()`, check if the viewport is at the bottom (`_isAtBottom`). If at the bottom, clear `_scrollAnchor` and all saved session offsets, suppress scroll saves for 1000ms, call `setState(() {})`, and call `_scrollToCursor(requestFocus: false, forceBottom: wasAtBottom)`.
   - In `_onFit()`, suppress scroll saves for 300ms.
   - In `_scrollToCursor({required bool requestFocus, bool forceBottom = false})`, compute `isCurrentlyAtBottom`. When `forceBottom || isCurrentlyAtBottom || !wasScrolledUp`, clear saved session scroll offsets and anchor, and set `target = position.maxScrollExtent`.
   - In `dispose()`, cancel `_suppressScrollSaveTimer`.

2. Update `terminal_pane_web.dart`:
   - In `_onFit()`, evaluate `wasAtBottom` directly from `_viewportIsAtBottom(_container, viewportY, baseY)`. When true, clear `_sessionSavedViewportY` and invoke `scrollToBottom`.

3. Update `main.dart`:
   - In `_selectSession`, remove `if (kIsWeb)` so `_refitActiveSession()` runs post-frame on all platforms for already-fitted sessions.
   - In `_connectWebSocket`, remove `kIsWeb` on post-frame `_refitActiveSession()`.
   - In `_refitActiveSession()`, insert a 60ms delay between `rows - 1` and `rows` on native to guarantee distinct SIGWINCH signal delivery.

4. Update Tests and Verify:
   - Adjust `test/widget_test.dart` to expect the native refit resize calls during re-selection.
   - Add unit/widget tests for native pane refit preserving bottom scroll when `_sessionSavedScrollOffsets` contains stale data.
   - Run `cargo check --workspace`, `cargo test --workspace`, `flutter analyze`, and `flutter test`.
   - Build, install, reload daemon, rebuild macOS app, install, and deploy.
