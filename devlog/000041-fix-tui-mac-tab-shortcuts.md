# Branch Devlog: fix/fix-tui-mac-tab-shortcuts

- **Agent:** Antigravity
- **Intent:** Add robust and conflict-free alternative keyboard shortcuts for TUI tab/session switching on macOS.

## Intent

Resolve the keyboard shortcut tab switching issue on macOS where the default `Alt + Arrow` shortcuts are intercepted, mapped to word navigation, or treated as diacritic prefixes by standard macOS terminals. We will add `Ctrl + Alt + Arrow` and `F3`/`F4` combinations as safe, conflict-free alternatives.

## What Changed

- Mapped `Ctrl + Alt + Right` and `Ctrl + Alt + Down` to the `AppCommand::Next` command.
- Mapped `Ctrl + Alt + Left` and `Ctrl + Alt + Up` to the `AppCommand::Previous` command.
- Mapped `F3` to the `AppCommand::Next` command and `F4` to the `AppCommand::Previous` command.

## Decisions

- Retain existing `Alt + Arrow` shortcuts for Windows/Linux users who prefer them.
- Introduce `Ctrl + Alt + Arrow` keys which override standard macOS option-diacritic intercept behavior and are parsed reliably by crossterm.
- Introduce `F3` and `F4` keys as a completely universal backup shortcut that does not conflict with any text editing selection shortcuts or terminal emulators.

## Commits

- HEAD — fix(triage): add Ctrl+Alt+Arrow and F3/F4 tab switching shortcuts for macOS
