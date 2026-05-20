## Thinking

The symptom suggests the terminal emulator model has stale styled cells in rows that Codex expects to clear when a prompt is submitted. The fix should preserve terminal geometry and raw PTY logging while ensuring the daemon snapshot reflects cleared cells and the TUI renders rows without keeping old text in background-padded areas.

## Plan

1. Inspect the daemon terminal snapshot extraction around physical cells, clear-to-end handling, and styled row spans.
2. Add a regression test that models Codex submitting input and clearing/redrawing the composer area.
3. Patch the snapshot extraction or TUI projection at the narrowest layer that removes stale text while preserving background styling and cursor placement.
4. Run format, targeted tests, workspace check/clippy/tests, and update the branch devlog before committing.
