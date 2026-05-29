# Plan: Platform-Specific Flutter Shell Menu

## Thinking

The Flutter web client currently exposes a plus-button popup menu on every platform because every platform gets both `cmd.exe` and `bash` shell options. This makes macOS show a Windows-only `cmd.exe` choice and adds unnecessary interaction for a platform that should just create a bash shell.

## Plan

1. Make the shell option list platform-specific: Windows gets `cmd.exe` and `bash`; other platforms get only `bash`.
2. Render the plus control as a direct button when there is only one shell option, while keeping the popup menu for Windows.
3. Update widget tests to cover Windows menu behavior and macOS direct-create behavior.
4. Run focused Flutter tests and update this devlog before committing.
