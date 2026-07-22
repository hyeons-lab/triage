# 000105-01 — Why the web scrollback collides after a resize

## Thinking

Reported symptom: resizing a Flutter *web* session does not reflow the contents.

### What the browser actually showed

Reproduced by driving an isolated Brave instance over the DevTools Protocol
against the live daemon and reading xterm.js's buffer directly (the web pane
exposes `window.activeTerm`).

xterm.js reflow is **not** broken:

| viewport | cols | buffer lines | wrapped lines |
| -------- | ---- | ------------ | ------------- |
| 1200px   | 92   | 1029         | 271           |
| 700px    | 36   | 1029         | 671           |
| 1400px   | 114  | 490          | 132           |

Narrowing re-split wrapped lines (271 → 671); widening rejoined them
(1029 → 490 rows). At 760px the pane rendered cleanly, and the *live* frame is
correct at every width — the host re-sync on first fit makes the program repaint.

What breaks is the **scrollback**: at 1600px a Claude Code status line captured
near 200 columns (`new task? /clear to save 177.6k tokens`, `current: 2.1.205`)
sat collided with shell output at ~90 columns, on the same rows.

### Why the obvious fixes are wrong

**Styled rows.** Serving the daemon's own reflowed grid as `StyledRow`s is the
path deleted in #63 ("Fix terminal corruption: unidirectional MVI raw-byte
pipeline"). The Phase 0 spike in `devlog/000056` pinpointed `styledRowToAnsi`
dropping codepoint-0 gap cells, rendering `Claude Code` as `ClaudeCode` — a
width-*independent* corruption. Raw bytes are the single source of truth
precisely to remove that stringification.

**Shrinking `RAW_OUTPUT_TAIL_CAP`.** Attempted first, then abandoned. The 1 MiB
was deliberately sized: "1 MiB is ~16× headroom for full-screen TUIs (vim/less)"
(`devlog/000056`). The 64 KiB spike figure is Claude-Code-specific (~1.4 KB
synchronized frames) and does not generalize — a truecolor per-cell frame can
exceed 250 KB, so a small cap can begin replay *mid-redraw*. Worse,
`devlog/000056` names "alt-screen enter falls outside the tail" as the headline
risk of a bounded tail, dismissed only because Claude Code never emits `?1049h`;
shrinking makes that likelier for vim/less/btop, and then alt-screen frames
replay into the *normal* buffer and become permanent scrollback — the same damage
class, made worse.

### What `devlog/000056` already decided

> Decision: send a **coherent-anchored tail** (snap start to the last
> `?1049h`/`\x1b[2J`/RIS when present, else a raw tail) capped at ~256 KiB–1 MiB
> … This kills the "alt-screen enter falls outside the tail" headline risk.

Anchoring was specced and deferred ("anchor-snap noted as a future option"). It
is strictly better than shrinking: history always begins at a boundary after
which the prior screen no longer matters, and the cap stays large enough for
heavy frames.

### Measured against the real logs — a no-op for this workload

Before committing, scanned the eight largest session logs on this machine for the
anchors, within a 1 MiB window:

| anchor | occurrences |
| ------ | ----------- |
| `\x1b[2J` (ED 2) | 0 |
| `\x1b[3J` (ED 3) | 0 |
| `\x1b[?1049h` (alt screen) | 0 |
| `\x1bc` (RIS) | 0 |

None, in any of them — so anchoring changes nothing for these sessions and falls
back to the plain bounded tail every time.

The only structure present is `\x1b[H` (10–24 per tail). It is **not** a valid
anchor: dumping the bytes at the last one shows Claude Code homing the cursor and
repainting downward with relative column moves (`\x1b[3G`, `\x1b[6G`, `\r\r\n`)
and no erase at all.

That is the actual collision mechanism, and it is worth stating plainly: **Claude
Code repaints without erasing**, so anything already on screen wider than the new
frame survives underneath it. The observed fragments are that, not merely an
artefact of replaying multi-width history — which also means no amount of tail
trimming fixes them.

### Decision

Ship the anchoring anyway, and describe it accurately. It is a correctness guard
for sessions that *do* clear or use the alternate screen (vim, less, btop), where
it prevents two real failures — replay starting mid-frame, and alt-screen frames
leaking into the normal buffer. For Claude Code it is a no-op. It does **not**
fix the reported symptom, and neither the plan nor the code may pretend otherwise.

## Plan

1. Add `HISTORY_ANCHORS` (`\x1b[2J`, `\x1b[3J`, `\x1b[?1049h`, `\x1bc`) and snap
   `read_raw_output_tail`'s start to the last one inside the capped window,
   including the sequence itself so the client's emulator performs the clear.
2. Fall back to the plain bounded tail when the window holds no anchor.
3. Leave `RAW_OUTPUT_TAIL_CAP` at 1 MiB, and record that it is now a *search
   window* — shrinking it would push anchors out of range for exactly the heavy
   TUIs that need one.
4. Tests: anchors to the last clear (and includes it); anchors to alt-screen
   entry; falls back when the anchor is outside the window; `rfind_bytes` edges.
5. Validate: `cargo fmt --check`, `clippy -D warnings`, `cargo doc -D warnings`,
   `cargo test --workspace`. Then `/review-fix-loop max`.

Not in scope, and recorded as follow-up: the repaint-without-erase collision, and
the underlying width mismatch (history authored at the host PTY width,
re-emulated at the client's).

## Outcome — plan abandoned, 2026-07-22T14:36-0700

Steps 1–5 were implemented and then reverted before commit. Review found the
anchoring regresses the case it was written for.

`last_anchor_offset` takes the maximum offset across all anchors, and alt-screen
TUIs emit `?1049h` followed by `\x1b[H\x1b[2J` — so the last anchor is a `2J`
*inside* the alternate screen. Verified on that byte pattern: the `?1049h` at
offset 16 is discarded in favour of the `2J` at offset 47, so alt-screen frames
would replay into the client's normal buffer and become permanent scrollback.
That is worse than the plain 1 MiB tail this replaced, which usually contains the
`?1049h`.

Two further defects, either of which alone would have blocked it:

- `\x1b[3J` was listed as an anchor on the belief that it erases the display. It
  does not — ED 3 clears saved scrollback and leaves the visible frame intact.
- Only RIS makes prior terminal state irrelevant. `2J` and `?1049h` leave DECSTBM
  scroll regions, DECAWM autowrap, cursor-key mode, charset selection, mouse
  tracking and SGR state in force, so moving the replay start later strictly
  increases the chance of dropping the sequences that establish them.

It also measured as a no-op on the real logs while adding a ~7 ms synchronous
scan to every history-bearing snapshot.

Nothing ships from this branch except the investigation record. See the devlog's
Next Steps for the two candidates that remain, both of which have real costs and
need a product decision rather than an engineering one.
