## Thinking

The review feedback identified a coverage gap rather than a production bug: `styled_row_to_line` had a trailing-background regression test, but `styled_selected_row_to_line` could regress independently. The selected-row path should be covered with an active selection on a row whose final style has a background, while asserting that background padding remains span-local.

## Plan

- Fetch current PR review threads and confirm actionable comments.
- Add a selected-row regression test for trailing background padding.
- Run formatting and focused TUI tests.
- Update the branch devlog before committing.
