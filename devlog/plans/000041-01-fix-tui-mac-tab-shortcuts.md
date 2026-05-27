# Plan: Add Robust TUI Tab Switching Shortcuts for macOS

This plan covers adding `Ctrl + Alt + Arrow` and `F3`/`F4` keyboard shortcuts to enable smooth tab switching on macOS, complementing the existing `Alt + Arrow` shortcuts.

## Thinking

1.  **Requirement**:
    *   macOS default terminals intercept `Alt + Arrow` keys or interpret Option as a diacritic modifier, preventing them from being received by Triage as standard `Alt` keyboard events.
2.  **Alternatives**:
    *   `Ctrl + Alt + Arrow` keys: The addition of the Control modifier overrides diacritics typing and is correctly forwarded by terminal emulators (macOS Terminal, iTerm2, etc.) as standard keyboard event sequences.
    *   `F3` and `F4` keys: Fully conflict-free backup keys that work out-of-the-box in all terminals without needing manual option-key configuration.
3.  **Key mappings in `key_to_command` inside `crates/triage/src/main.rs`**:
    *   Update the `Next` case to check for:
        *   `KeyCode::Right` | `KeyCode::Down` with `KeyModifiers::ALT`
        *   `KeyCode::Right` | `KeyCode::Down` with `KeyModifiers::CONTROL | KeyModifiers::ALT`
        *   `KeyCode::F(3)`
    *   Update the `Previous` case to check for:
        *   `KeyCode::Left` | `KeyCode::Up` with `KeyModifiers::ALT`
        *   `KeyCode::Left` | `KeyCode::Up` with `KeyModifiers::CONTROL | KeyModifiers::ALT`
        *   `KeyCode::F(4)`

## Plan

1.  **Modify `crates/triage/src/main.rs`**:
    *   Update the key handler patterns to match the new shortcuts.
2.  **Verify & Test**:
    *   Verify all tests in the workspace still compile and pass perfectly (`cargo test --workspace`).
