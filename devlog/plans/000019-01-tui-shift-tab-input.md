# TUI Shift-Tab Input

## Thinking

The outer Ratatui client owns crossterm key events and decides which bytes are forwarded to the selected child PTY. Plain `Tab` already reaches the child terminal, but crossterm reports `Shift+Tab` as reverse-tab input, which currently falls through `key_to_input` and is dropped. Codex uses reverse-tab to switch planning mode, so this should be handled as terminal input rather than an Argus command.

## Plan

1. Add reverse-tab handling in the TUI key-to-input translation.
2. Preserve existing plain-tab behavior.
3. Add focused regression tests for the crossterm event forms.
4. Run formatting and targeted TUI tests.
