## Thinking
To expand Triage's Flutter client support to native platforms (iOS, Android, macOS), we need to:
1. Scaffold the native platform directories (`ios`, `android`, `macos`) under `flutter/triage_client` using `flutter create`.
2. Add the `xterm` package dependency to `pubspec.yaml` to power the native interactive terminal view.
3. Update `terminal_pane_stub.dart` to implement a real interactive `TerminalView` backed by the `xterm` package instead of a static read-only text view, wiring data writes, resize commands, inputs, and cursor styling.
4. Verify the native target compiles and runs properly.

Let's do this step-by-step.

## Plan
1. Write the branch devlog and the initial plan file.
2. Run `flutter create --platforms=ios,android,macos .` inside the `flutter/triage_client` workspace.
3. Update `pubspec.yaml` to add `xterm: ^3.2.6`. Run `flutter pub get`.
4. Inspect `terminal_pane_web.dart` to match the exact controller API (onData, onResize, writes, cursor adjustments) and design system colors.
5. Implement interactive terminal rendering in `terminal_pane_stub.dart` using the `xterm` package.
6. Verify compilation and test suite runs correctly.
