# 000105 — investigation: web scrollback collides after resize

**Agent:** Claude Code (claude-opus-4-8[1m]) @ triage branch
docs/web-scrollback-width-investigation

## Intent

"Resizing the Flutter web session doesn't seem to reflow the contents."

This branch carries **no code change**. Three candidate fixes were designed and
each was rejected on evidence; the value here is the evidence, so the next
attempt does not repeat the same three dead ends. Full derivation in
`devlog/plans/000105-01-web-scrollback-investigation.md`.

## Research & Discoveries

2026-07-22T13:20-0700 Reproduced against the live daemon by driving an isolated
Brave instance over the DevTools Protocol (the web pane sets
`window.activeTerm`, which makes xterm.js's buffer directly inspectable).

2026-07-22T13:28-0700 **xterm.js reflow is not broken.** 1200px → 92 cols, 1029
buffer rows, 271 wrapped; 700px → 36 cols, 1029 rows, 671 wrapped; 1400px → 114
cols, 490 rows, 132 wrapped. Narrowing re-split wrapped lines and widening
rejoined them, which is correct reflow. At 760px the pane rendered cleanly, and
the live frame is correct at every width.

2026-07-22T13:34-0700 **Only the scrollback breaks.** At 1600px a Claude Code
status line captured near 200 columns collided on the same rows with shell output
at ~90 columns.

2026-07-22T13:40-0700 The web pane reconstructs history by re-emulating the raw
PTY byte tail — `styledRows` / `visibleRows` reach the client but are never drawn
by the terminal — and `terminal_store.dart` replays it at the *client's* grid
size, not the host capture size, which it states explicitly.

2026-07-22T14:26-0700 **The anchors that would make a bounded tail coherent do
not occur in this workload.** Across the eight largest session logs on this
machine, within a 1 MiB window, `\x1b[2J`, `\x1b[3J`, `\x1b[?1049h` and `\x1bc`
each occur **zero** times.

2026-07-22T14:28-0700 The only structure present is `\x1b[H` (10–24 per tail),
and it is not a clear. Dumping the bytes at the last one shows Claude Code homing
the cursor and repainting downward with relative column moves (`\x1b[3G`,
`\x1b[6G`, `\r\r\n`) with **no erase**.

2026-07-22T14:33-0700 **Root cause, and why it is not just a replay artefact:**
Claude Code repaints without erasing, so anything already on screen that is wider
than the new frame survives underneath it. Combined with history authored at the
host PTY width and re-emulated at the client's, that is the collision. It follows
that no amount of tail trimming or anchoring fixes it.

## Decisions

2026-07-22T14:08-0700 **Rejected: serve the daemon's reflowed grid as
`StyledRow`s.** That path was deleted in #63 ("Fix terminal corruption:
unidirectional MVI raw-byte pipeline") because `styledRowToAnsi` dropped
codepoint-0 gap cells, rendering `Claude Code` as `ClaudeCode` — a
width-*independent* corruption. Raw bytes are the single source of truth
precisely to remove that stringification.

2026-07-22T14:10-0700 **Rejected: shrink `RAW_OUTPUT_TAIL_CAP`** (implemented as
1 MiB → 128 KiB, then reverted). `devlog/000056` sized the 1 MiB deliberately —
"~16× headroom for full-screen TUIs (vim/less)" — and the 64 KiB spike figure is
Claude-Code-specific (~1.4 KB synchronized frames). A truecolor per-cell frame
can exceed 250 KB, so a small cap can start replay mid-redraw, and it makes
"alt-screen enter falls outside the tail" — the headline risk `devlog/000056`
names — *more* likely, not less.

2026-07-22T14:35-0700 **Rejected: the coherent-anchored tail** that
`devlog/000056` specced and deferred ("snap start to the last
`?1049h`/`\x1b[2J`/RIS when present, else a raw tail"). Implemented, then
reverted before commit, for three independent reasons:

1. *It regresses the case it exists for.* Snapping to the last anchor takes the
   maximum offset over all of them, and vim/less/btop emit `?1049h` followed by
   `\x1b[H\x1b[2J`, so the last anchor is a `2J` **inside** the alternate screen.
   Verified on the canonical byte pattern: the `?1049h` at offset 16 is dropped
   in favour of the `2J` at offset 47, so alt-screen frames replay into the
   client's *normal* buffer and become permanent scrollback — worse than today's
   plain tail, which at 1 MiB usually contains the `?1049h`.
2. *`\x1b[3J` is not a screen-clearing anchor at all.* ED 3 erases saved
   scrollback and leaves the visible frame intact.
3. *Only RIS actually makes prior state irrelevant.* `2J` and `?1049h` leave
   DECSTBM scroll regions, DECAWM autowrap, cursor-key mode, charset selection,
   mouse tracking and SGR state untouched, and anchoring moves the replay start
   strictly later — so it strictly increases the chance of dropping the sequences
   that set them.

   It also measured as a no-op for the real logs (no anchors present) while
   costing a ~7 ms synchronous scan per history-bearing snapshot.

2026-07-22T14:36-0700 Landing nothing beats landing a plausible-looking
regression. The live frame already self-heals; only historical scrollback is
affected, and every candidate fix so far trades a cosmetic artefact for a
correctness one.

## Lessons Learned

2026-07-22T14:37-0700 `devlog/000056` had already recorded both the root cause
and the intended fix. Reading it *before* proposing a fix would have skipped two
of the three dead ends — and the third (anchoring) is the one it recommended,
which turns out not to survive contact with how alt-screen TUIs actually emit
their clears. A deferred decision in a devlog is a hypothesis, not a verified
design.

2026-07-22T14:38-0700 Escape-sequence semantics are worth checking individually
rather than by category: `2J`, `3J`, `?1049h` and RIS look interchangeable as
"screen is gone" markers and behave quite differently.

## Next Steps

- Two distinct causes remain, and a real fix must address both: history is
  authored at the host PTY width and re-emulated at the client's, and Claude Code
  repaints without erasing so wider stale content survives underneath a narrower
  frame.
- Candidate with the best odds: have the daemon synthesize a clear
  (`\x1b[2J\x1b[3J\x1b[H`) ahead of the replayed history and start at the last
  frame boundary (`\x1b[H` where no real clear exists), so the client renders one
  coherent frame onto a blank grid at its own width. Cost: scrollback is lost on
  attach in the web client. Needs a product call, not just an engineering one.
- If scrollback must be preserved, the only path is host-side reflow, which
  requires fixing `styledRowToAnsi`'s gap-cell corruption first — i.e. reopening
  what #63 closed, deliberately and with tests this time.
