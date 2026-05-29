# Branch Devlog: fix/web-shell-menu-platforms

- **Agent:** Codex
- **Intent:** Restrict the Flutter web new-session shell picker to platforms that need multiple shell choices.

## Intent

Fix the plus button behavior so macOS and Linux create a bash session directly instead of showing a Windows-oriented shell dropdown with `cmd.exe`.

## What Changed

- Limited non-Windows new-session shell options to `bash`.
- Changed the new-session plus control to render as a direct button when only one shell option exists.
- Kept the dropdown menu on Windows, where users can choose between `cmd.exe` and `bash`.
- Added widget coverage for macOS direct creation and Windows dropdown creation.

## Decisions

- Do not offer `cmd.exe` on macOS or Linux because it is Windows-specific and makes the UI misleading.
- Use the same `New session` tooltip for both the direct button and the Windows dropdown so existing tests and user expectations stay stable.
- Scope test platform overrides with `try/finally`; Flutter checks debug platform variables before normal tear-down callbacks run.

## Commits

- HEAD — fix(client): hide shell menu off Windows

## Progress

- 2026-05-29T08:42-0700: Started from `main` to fix platform-specific new-session shell behavior in the Flutter client.
- 2026-05-29T08:42-0700: Implemented the platform shell option split and direct plus button for single-shell platforms. Validated with `flutter test test/widget_test.dart` and `flutter test`.
