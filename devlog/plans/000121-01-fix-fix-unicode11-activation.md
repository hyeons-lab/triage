## Thinking

In `xterm.js`, character cell width calculation defaults to Unicode 6 (where emojis like 📦, 🦀, ⚡, 🐍 are calculated as 1 cell wide instead of 2).
`Unicode11Addon` registers version 11 character widths with xterm.js's internal `UnicodeService`.
However, accessing `term.unicode` in xterm.js requires `allowProposedApi: true` in the constructor options; otherwise xterm.js throws `You must set the allowProposedApi option to true to use proposed API`.
Furthermore, setting `term.options.unicodeVersion = '11'` does not update the active version on `term.unicode`. Setting `term.unicode.activeVersion = '11'` is required to activate Unicode 11.

## Plan

1. In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Pass `'allowProposedApi': true` in the `options` map when instantiating `Terminal`.
   - After `loadAddon(unicode11Addon)`, access `js_util.getProperty(_term, 'unicode')` and set `js_util.setProperty(unicode, 'activeVersion', '11')`.
2. Build Flutter Web release client (`flutter build web --release`).
3. Run workspace tests and format checks (`cargo check`, `cargo fmt`).
4. Execute `/review-fix-loop high` to verify changes.
5. Commit, push, open PR, and execute zero-downtime handover (`triaged --handover`).
