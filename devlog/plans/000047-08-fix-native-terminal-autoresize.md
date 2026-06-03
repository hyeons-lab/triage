## Thinking

The native Flutter terminal pane still manually resizes `xt.Terminal` from hard-coded average cell dimensions inside `LayoutBuilder`.
`package:xterm` already auto-resizes `TerminalView` from measured glyph metrics during render layout, so the manual resize can run first with an estimated column count and cause initial replay or live prompt text to be interpreted at the wrong width.
That matches the observed symptom: copy/paste can preserve the expected text while the displayed terminal wraps early.

## Plan

1. Remove the constant-based `LayoutBuilder` resize from `terminal_pane_stub.dart` and let `TerminalView`'s measured `autoResize` path drive `xt.Terminal.resize`.
2. Keep the existing `onResize` callback flow so measured native terminal dimensions still trigger daemon PTY resize/reflow snapshots.
3. Run focused Flutter tests for the terminal replay and widget flows.
4. Update the branch devlog with the sizing decision and validation result.

After the first reinstall, the visual layout was still incorrect. The remaining likely cause is font resolution: the native pane used the generic `monospace` family, which can measure cells through one platform font and paint box-drawing or prompt glyphs through fallback fonts. That can preserve the copied terminal text while making the display wrap or render separators incorrectly.

5. Pin the native terminal text style to Menlo with explicit monospace fallbacks so cell measurement and glyph rendering use a stable macOS terminal font.
6. Re-run the focused Flutter tests and rebuild/reinstall the macOS app.

The next observed issue is intermittent blank or stale first paint that resolves after clicking the session row. The native initial replay path currently treats `replayPending` as compatible with initial completion: `_finishInitialContent()` marks `initialContentWritten` before `_writeInitialContent()`, while `_writeInitialContent()` returns immediately during pending snapshot refresh. A replay-revision update can also clear the terminal before the replacement snapshot is ready.

7. Make pending snapshots defer native initial replay without setting `initialContentWritten`.
8. Make pending snapshots defer full replay/reset without clearing the terminal.
9. Re-run focused tests, rebuild macOS, and reinstall `/Applications/Triage.app`.

The critical review found that live output still writes directly into the persistent native terminal from `SessionVm` before or during replay. Since a daemon-backed live session can continue producing output while the UI is restoring, replay must treat live writes as ordered data that is flushed only after snapshot replay finishes.

10. Move persistent terminal write gating into `SessionVm`: buffer writes while initial replay is incomplete or snapshot refresh is pending.
11. Preserve daemon `output_seq` for buffered live writes and drop any buffered write whose sequence is already covered by the replayed snapshot.
12. Add direct tests for first-replay buffering and live snapshot-refresh buffering.

After sequence-aware replay buffering, horizontal separator rows can still appear split when the daemon sends live output chunks that divide a multi-byte UTF-8 glyph. Decoding each `Output` event independently with `allowMalformed: true` turns the incomplete byte fragments into replacement characters before xterm sees them.

13. Add per-session UTF-8 carry state for live daemon output so incomplete trailing sequences are retained until the next output event.
14. Decode only complete byte prefixes before translating line endings and writing to the terminal.
15. Add a regression test for box-drawing glyphs split across output events, then run the focused and full Flutter test suites before rebuilding the macOS app.
16. Associate pending UTF-8 carry bytes with daemon `output_seq` and clear stale carry when a replayed snapshot has already moved past the split glyph.

After the display and replay fixes, restored sessions still open with the terminal viewport at the top of the scrollback. The correct behavior is narrower than always jumping to the bottom: first display should reveal the cursor, session-rail selection should focus the terminal at the cursor, and ordinary replay/resize should preserve the user's scroll position.

17. Add a per-session focus revision that increments on session-rail selection.
18. Pass the revision into both platform terminal panes and scroll/focus only when it changes.
19. Scroll to the cursor after first replay, but avoid forcing scroll on ordinary replay/resize refreshes.
20. Validate native/test behavior with focused and full Flutter tests, and validate the web pane with a web build.

The first cursor-scroll fix still left the terminal unfocused on initial display, and native taps did not reliably focus because `TerminalView` can consume the gesture internally before the wrapper `GestureDetector` runs.

21. Request terminal focus after initial replay, not only after explicit rail focus revisions.
22. Add native pointer-level focus around `TerminalView` and enable `TerminalView` autofocus.
23. Add web mouse-down activation so clicking/tapping the terminal focuses xterm before text input.
24. Re-run focused/full Flutter tests, compile web, then rebuild and reinstall the macOS app.
