# Plan: Fix Credential Persistence, Initial Scroll Position, and Draggable Scrollbar Handle

## Thinking

Users observed three concrete regressions/issues:
1. "why does it ask for a pin every time I use the app? It doesn't remember."
   On macOS, `/Applications/Triage.app` is sandboxed (`com.apple.security.app-sandbox`) and ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`).
   `storage_native.dart` exclusively used `FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false))`.
   On modern macOS, sandboxed apps cannot access the legacy file-based keychain (`login.keychain-db`) without entitlements or user prompts, and cannot access the data-protection keychain without an Apple Developer Team ID prefix.
   Because all writes used `_secureStorage.write(...).catchError((_) {})` and `loadCredentials()` had `catch (_) {}`, the errors failed completely silently.
   Credentials (`clientId` and per-server bearer tokens) were never persisted to disk. On every launch, `retrieveClientId()` returned null, generating a brand new client ID and prompting for PIN pairing every single time.
   `SharedPreferences`, by contrast, writes to `~/Library/Containers/com.hyeons-lab.triageClient/Data/Library/Preferences/com.hyeons-lab.triageClient.plist`, which works reliably in sandboxed ad-hoc macOS apps.
   By augmenting `storage_native.dart` to use `SharedPreferences` as the backing storage alongside Keychain, `clientId` and daemon bearer tokens persist reliably across app launches.

2. "it still starts at the top."
   Two compounding causes:
   First, in `xterm.dart` (`lib/src/ui/render.dart`), a recent commit added:
   `if (!_hasCheckedInitialOffset && _maxScrollExtent > 0) { _hasCheckedInitialOffset = true; _stickToBottom = _scrollOffset >= _maxScrollExtent - 0.5; }`
   On initial layout passes, `_scrollOffset` is 0.0 before content dimensions are fully settled, which caused `_stickToBottom` to flip to `false` on the first frame where `_maxScrollExtent > 0`. Once `_stickToBottom` became false, `performLayout()` never adjusted `_offset` to `_maxScrollExtent`, stranding the viewport at offset 0.0 (top).
   Second, in `terminal_pane_stub.dart`:
   `final wasScrolledUp = ... || (lineHeight != null && position.pixels < position.maxScrollExtent - 2 * lineHeight);`
   When opening a fresh session or returning to a session that was at the bottom, there was no saved offset or anchor. However, because `position.pixels` starts at 0.0 before any scroll events, `position.pixels < position.maxScrollExtent - 2 * lineHeight` evaluated to true! The pane interpreted offset 0.0 as an intentional user scroll-up and called `position.jumpTo(0.0)`, locking the terminal to the top!
   Removing the broken initial offset check in `render.dart` and removing the fallback heuristic in `terminal_pane_stub.dart` ensures that sessions without an explicit scrolled-up state always stick to the bottom (`position.maxScrollExtent`).

3. "when scrolling the session, I can't grab and drag the srollpane using the handle on the right."
   When clicking or dragging on the right edge of the terminal pane:
   First, `Listener` in `terminal_pane_stub.dart` received all raw pointer events, and `_cellAtGlobal` clamped the click position to the last column of the terminal buffer, kicking off an unwanted drag-selection of terminal text and auto-scrolling.
   Second, `TerminalGestureDetector` in `xterm.dart` wrapped `Scrollable` with a mouse `PanGestureRecognizer` configured with `DragStartBehavior.down`, which immediately claimed the gesture arena over any scrollbar drag recognizer.
   Third, there was no dedicated, interactive scrollbar widget with a draggable thumb.
   By implementing a custom `TerminalScrollbar` positioned on top in the `Stack` (`Positioned(top: 0, bottom: 0, right: 0, width: 14)`) with `HitTestBehavior.opaque`, pointer down and drag events on the scrollbar are consumed by the scrollbar itself and never leak into `Listener` or `TerminalView` below. The user can smoothly grab and drag the handle, click anywhere on the track to jump/scroll, and hover to see visual feedback.

## Plan

1. **Fix Credential Persistence in `storage_native.dart`**:
   - Update `loadCredentials()` to initialize `SharedPreferences.getInstance()`, read both Keychain and `SharedPreferences`, and populate the in-memory cache.
   - Update `_writeThrough` to write to both `_secureStorage` and `_prefs`.
   - Update `_deleteThrough` to remove from both `_secureStorage` and `_prefs`.
   - Reset `_prefs` in `resetCredentialCacheForTesting()`.
   - Verify unit tests in `server_store_test.dart` and `widget_test.dart`.

2. **Fix Initial Scroll / Start at Bottom**:
   - In `/Users/dberrios/development/xterm.dart/lib/src/ui/render.dart`:
     Revert `_hasCheckedInitialOffset` and keep `_stickToBottom = true` default.
     Commit and push to `xterm.dart` branch `fix/trim-start-reindex-v4`.
     Update `flutter/triage_client/pubspec.yaml` with the new commit SHA and run `flutter pub get`.
   - In `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
     In `_scrollToCursor`, remove the `position.pixels < position.maxScrollExtent - 2 * lineHeight` heuristic so that absence of a saved scroll offset/anchor reliably targets `position.maxScrollExtent`.

3. **Implement Draggable `TerminalScrollbar`**:
   - Create `TerminalScrollbar` in `terminal_pane_stub.dart` (or dedicated widget file):
     - Takes `ScrollController controller`.
     - Observes scroll offset and dimensions.
     - Draws rounded thumb handle with hover/drag state.
     - `GestureDetector(behavior: HitTestBehavior.opaque)`:
       - `onVerticalDragStart`: records drag starting point.
       - `onVerticalDragUpdate`: adjusts `controller.jumpTo(...)` proportionally.
       - `onTapDown`: jumps thumb directly to clicked track position.
     - Placed in `Stack` at `Positioned(top: 0, bottom: 0, right: 0, width: 14)`.
   - Wrap `xt.TerminalView` with `ScrollConfiguration(behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false), ...)` to avoid duplicate scrollbars.

4. **Verify and Test**:
   - Run tests: `flutter test test/widget_test.dart` and `flutter test test/terminal/`.
   - Build macOS release app (`flutter build macos --release`).
   - Copy to `/Applications/Triage.app` and ad-hoc sign (`codesign -s - -f /Applications/Triage.app`).
   - Reload daemon via `triaged reload` (if needed) and run tests.

5. **Update Devlog and Commit**:
   - Update `devlog/000145-fix-mobile-typing-auto-space.md` (no em dashes).
   - Commit and push to `origin HEAD:refs/heads/fix/mobile-typing-auto-space`.
