# Session Pane Scroll

## Thinking

The TUI sidebar builds rows for every session and renders them from the top of a `Paragraph`. Ratatui clips rows past the sidebar area, so once enough sessions exist, newly created or selected sessions can be below the viewport with no visual feedback. The minimal fix is to keep the selected session's row group inside the sidebar viewport before rendering.

## Plan

1. Add focused coverage for sidebar row windowing when the selected session is below the visible pane.
2. Add a helper that converts the full sidebar rows into the visible viewport while preserving the selected session's full row group when it fits.
3. Wire `draw_sidebar` through the helper and run focused TUI tests plus formatting.
