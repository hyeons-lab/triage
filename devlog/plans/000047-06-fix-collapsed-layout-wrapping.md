## Thinking

We are addressing the issue where the layout around the prompt is split/wrapped across lines on native macOS on sidebar collapse, even though copying and pasting shows it correctly formatted.
As discovered:
- `xt.TerminalView` does not automatically call `_terminal.resize(...)` when its layout constraints change.
- Because `_terminal` was never resized, it remained at its default size of 80 columns, while the PTY was running at a wider estimated size (e.g. 97 or 110 columns).
- When the PTY printed a line longer than 80 characters, the terminal buffer wrapped it, causing visual split lines around the prompt.
- Copy-pasting worked correctly because `session.rows` contained the actual PTY rows before the terminal buffer wrapped it.

### Action Plan
1. **Implement layout constraints tracking using LayoutBuilder**:
   - Done. We wrapped the native terminal view inside a `LayoutBuilder` in `terminal_pane_stub.dart`.
   - On constraints changes, we calculate the dynamic fitted columns and rows, and call `_terminal.resize(cols, rows)` safely within a microtask.
   - This ensures the frontend terminal's logical columns are perfectly synchronized with the PTY columns at all times.
2. **Rebuild all targets**:
   - Rebuild the Flutter web client: `flutter build web` inside `flutter/triage_client`.
   - Rebuild the Flutter macOS client: `flutter build macos` inside `flutter/triage_client`.
   - Recompile cargo release workspace packages: `cargo build --release -p triage && cargo build --release -p triaged`.
   - Install cargo release binaries: `cargo install --path crates/triage && cargo install --path crates/triaged`.
   - Copy the new macOS app: `rm -rf /Applications/Triage.app && cp -R flutter/triage_client/build/macos/Build/Products/Release/Triage.app /Applications/`.
3. **Verify all tests pass**:
   - Already done: all 73 tests passed perfectly. We will verify again after builds if needed.

## Plan

1. **Build Flutter Web Client**:
   Run `flutter build web` inside `flutter/triage_client`.
2. **Build Flutter macOS Client**:
   Run `flutter build macos` inside `flutter/triage_client`.
3. **Build Rust Crates**:
   `cargo build --release -p triage`
   `cargo build --release -p triaged`
4. **Install Rust Binaries**:
   `cargo install --path crates/triage`
   `cargo install --path crates/triaged`
5. **Copy macOS App to Applications**:
   `rm -rf /Applications/Triage.app`
   `cp -R flutter/triage_client/build/macos/Build/Products/Release/Triage.app /Applications/`
