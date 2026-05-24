# Plan - Fix Terminal Layout and Coordinate Mismatches

## Thinking
We discovered that during the PR merge of the `remote-pairing-auth` branch to `main`, several critical terminal layout, state caching, and historical scrollback styling changes were left uncommitted in the local workspace, causing a regression in how the terminal sizes, wraps text, and renders colors (e.g. stripping colors from the startup Antigravity banner/logo).
Additionally, the padding on `_container` in `terminal_pane_web.dart` is currently applied directly to the xterm.js parent element via native CSS padding. This causes xterm.js's FitAddon to measure a larger width (including the 32px horizontal padding) when calculating columns (`clientWidth / characterWidth`), leading to coordinate mismatches and awkward line-wrapping at the boundaries when the PTY wraps lines at the expected PTY width.

To resolve these issues:
1. Re-enable `convertEol: true` in the xterm.js options.
2. Maintain terminal container caching to avoid platform view detachments.
3. Query the `styledRows` API on session attach to restore colors of all visible scrollback history lines.
4. Replace the direct container CSS padding with a nested layout: an outer native `DivElement` (which spans 100% width/height and acts as the Platform View container) and an inner native `DivElement` terminal wrapper (which has `width: calc(100% - 32px)`, `marginLeft: 16px`, `marginRight: 16px`, and no padding). xterm.js will be opened inside the inner container, allowing FitAddon to calculate columns correctly while maintaining the required visual padding.

## Plan
1. Apply the nested HTML outer/inner container layout in `flutter/triage_client/lib/widgets/terminal_pane_web.dart`.
2. Ensure `convertEol` is set to `true` inside xterm.js options.
3. Validate scrollback history color parsing in `flutter/triage_client/lib/main.dart` with the `styledRows` API.
4. Verify Flutter client build and check for layout coordinate alignment.
