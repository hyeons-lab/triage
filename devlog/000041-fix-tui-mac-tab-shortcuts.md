# Branch Devlog: fix/fix-tui-mac-tab-shortcuts

- **Agent:** Antigravity
- **Intent:** Add robust and conflict-free alternative keyboard shortcuts for TUI tab/session switching on macOS.

## Intent

Resolve the keyboard shortcut tab switching issue on macOS where the default `Alt + Arrow` shortcuts are intercepted, mapped to word navigation, or treated as diacritic prefixes by standard macOS terminals. We will add `Ctrl + Alt + Arrow` and `F3`/`F4` combinations as safe, conflict-free alternatives.

## What Changed

- Mapped `Ctrl + Alt + Right` and `Ctrl + Alt + Down` to the `AppCommand::Next` command.
- Mapped `Ctrl + Alt + Left` and `Ctrl + Alt + Up` to the `AppCommand::Previous` command.
- Mapped `F3` to the `AppCommand::Next` command and `F4` to the `AppCommand::Previous` command.
- Integrated native macOS `pbcopy` execution inside `write_osc52_clipboard` under a conditional compilation block `#[cfg(target_os = "macos")]`, enabling out-of-the-box clipboard copying on standard macOS terminals (which do not support or enable OSC 52 by default).

## Decisions

- Retain existing `Alt + Arrow` shortcuts for Windows/Linux users who prefer them.
- Introduce `Ctrl + Alt + Arrow` keys which override standard macOS option-diacritic intercept behavior and are parsed reliably by crossterm.
- Introduce `F3` and `F4` keys as a completely universal backup shortcut that does not conflict with any text editing selection shortcuts or terminal emulators.
- Execute the built-in system utility `pbcopy` as a child process when Triage runs locally on macOS, providing a zero-configuration, 100% reliable system clipboard integration.

## Commits

- HEAD — fix(triage): address PR review comments
- 7308c24 — fix(triage): use pbcopy for native macOS clipboard copy support in TUI
- 1aa224d — fix(triage): add Ctrl+Alt+Arrow and F3/F4 tab switching shortcuts for macOS

## Progress

- 2026-05-27T15:15-0700: Addressed PR review comments by switching macOS clipboard spawning to `/usr/bin/pbcopy` and simplifying `Alt + Arrow` modifier guards; `KeyModifiers::contains(KeyModifiers::ALT)` already covers `Ctrl + Alt` combinations. Verified with `cargo fmt --all -- --check` and `cargo test -p triage reserved_control_keys_become_app_commands`.
