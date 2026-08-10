# 000118 fix/xterm-scrollback-clear

**Agent:** Claude (claude-opus-5, 1M context) @ triage branch fix/xterm-scrollback-clear

Stacked on `fix/mobile-copy` (000117), which it shares selection code with.

## Intent

Repair what a scrollback clear does to the terminal's row indices, so the
viewport stops jumping and a selection stops reading the wrong lines after any
`clear`. Plan: [plans/000118-01-xterm-scrollback-clear.md](plans/000118-01-xterm-scrollback-clear.md).

## What Changed

2026-08-09T19:07-0700 `flutter/triage_client/pubspec.yaml`, `pubspec.lock`: a
`dependency_overrides` entry pinning `xterm` to `hyeons-lab/xterm.dart` at
commit `1a3e7c4`. That fork branches from the `v4.0.0` tag and carries the fix
(`trimStart` advances `_absoluteStartIndex` alongside `_startIndex`, plus a
test) and one dev-only commit dropping the discontinued `dart_code_metrics`
dependency, whose constraint no longer resolves and so blocked running xterm's
own suite at all. Against the release, `lib/` differs by one file.

2026-08-09T19:07-0700 `flutter/triage_client/lib/terminal/terminal_selection.dart`:
adds `terminalSelectionIsLive`, which reports whether a range still refers to
rows inside the buffer. Needed because a cleared line stays attached, so the
controller keeps offering a range for text that is gone.

2026-08-09T19:07-0700 `flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart`:
`desiredOffset` now releases an anchor whose line reports a negative row, and
the class doc explains that a line can leave the buffer two ways which do not
look alike.

2026-08-09T19:07-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
`_liveCopySelection` additionally requires the selection to be live, and
`_onTerminalContentChanged` clears a selection whose rows have been cleared out
from under it, which takes the stale highlight with it.

2026-08-09T19:07-0700 `flutter/triage_client/test/terminal/scrollback_clear_test.dart`
(new): five cases driving a real `ESC[3J` through the emulator rather than
simulating a trim.

2026-08-09T23:30-0700 `flutter/triage_client/pubspec.yaml`, `pubspec.lock`:
override repinned onto the fork's second fix
(`replaceWith` resets the start index before adopting rather than after). The
comment now describes two fixes instead of one; `lib/` still differs from the
release by the same single file.

2026-08-09T23:30-0700 `flutter/triage_client/test/terminal/scrollback_clear_test.dart`:
a second group covering clear-then-width-change, the path the 21:10 entry below
recorded as uncovered. Six cases at two widths: every row reports its true
position, cleared lines are not handed back out, and neither the selection nor
the anchor guard misfires on rows that are genuinely present.

2026-08-10T02:32-0700 `flutter/triage_client/pubspec.yaml`, `pubspec.lock`:
repinned to `2c09f74`, the fork commit that corrects the second fix's comments
and adds a test at the shape they cite. The pubspec's commit-count
parenthetical is replaced by a `git diff v4.0.0..<ref> -- lib/` instruction,
having been wrong three times.

2026-08-10T02:32-0700 `flutter/triage_client/test/terminal/scrollback_clear_test.dart`:
the scroll-anchor case additionally asserts which line sits at the anchored
row, since the offset alone reads the same on the unfixed emulator.

## Decisions

2026-08-09T18:40-0700 Fork rather than work around locally. Reasoning: the fix
exists upstream only as PR 225, unmerged since 2026-05-08 against a release that
is two years old, and a pull request is not something a build can depend on. The
deciding factor was that the drift also drives `TerminalScrollAnchor`, which
computes its pinned offset as `line.index * lineHeight`; that lives inside
xterm's data model, so no amount of triage-side code can correct it. Retiring
stale selections, by contrast, could have been done locally, and is anyway.

2026-08-09T18:45-0700 Took PR 225's narrowed approach over the obvious one.
Reasoning: the intuitive fix also detaches the trimmed lines, and that version
was already tried and walked back. `CellAnchor.y` and `.offset` guard
`_owner!.index` with `assert(attached)` alone, so in release builds, where the
assert is stripped, a still-held anchor dereferences a null `_absoluteIndex` and
throws. Verified against `line.dart:378` rather than taken on trust. Detaching
would have passed every debug test and crashed on device.

2026-08-09T19:00-0700 Detect a cleared line by a negative row rather than by
`attached`. Reasoning: not detaching is the whole point of the narrow fix, so
`attached` stays true and cannot be the signal. A line dropped by `trimStart`
now sits before the start of the buffer, so its index goes negative, which is
both unambiguous and cheap to test.

2026-08-09T19:02-0700 Pinned the override to a branch and let `pubspec.lock`
record the commit. Reasoning: the lock is committed, so builds are reproducible
against `0f83735` regardless, while the branch name keeps the pubspec readable.
(Superseded at 21:05, see Issues: the pin is now the commit `1a3e7c4` on a
branch cut from the `v4.0.0` tag. A branch ref would let a force-push change the
emulator with no diff here, and `0f83735` sat on upstream master and so carried
unreleased commits beyond the release.)

## Issues

2026-08-09T18:30-0700 The first version of the fork's patch was the broad one
(detach plus advance). It passed all 113 of xterm's tests, and would have
shipped a release-only crash. It was reading the existing upstream PR that
caught it, not the test suite. Worth remembering that a green suite says nothing
about `assert`-guarded invariants, because the asserts are exactly what a
release build removes.

2026-08-09T18:50-0700 First attempt to measure the drift compared the branch
against itself: the fix was already committed, so `git stash` had nothing to
stash and both runs used patched code, printing identical output. Re-ran with
`git checkout <upstream sha> -- lib/src/utils/circular_buffer.dart` for the
control. The real numbers: a surviving row 0 reports 16 without the fix and 0
with it. Second time this session that a self-designed probe quietly measured
nothing; the tell both times was a result that agreed too neatly.

2026-08-09T19:05-0700 `dart format lib/terminal/ test/terminal/` reformatted
`terminal_state.dart` and `terminal_scroll_anchor_test.dart`, neither of which
this branch touches. Reverted. This is the second occurrence on this branch's
parent, so it is now recorded as a standing note: format explicit file paths,
never directories, and check `git diff --stat` before committing.

2026-08-09T21:05-0700 Review loop: the fork was first branched from upstream
master, which carries five commits beyond `v4.0.0` (four non-merge), two of
them behavioural (colour 15 rendering in `palette_builder.dart`, and Android
enter-key handling in `terminal_view.dart`). The pubspec, this devlog and the
commit message all described the override as "one fix", so nothing signalled
that colour and keyboard behaviour were also changing, and `pubspec.lock` still
reports version `4.0.0`. Rebranched from the `v4.0.0` tag so `lib/` differs from
the release by exactly one file, and repinned by commit rather than branch name:
a branch ref would let a force-push swap the terminal emulator this app ships
with no diff in this repo.

2026-08-09T21:10-0700 Review loop, and worth recording as a limit of this fix
rather than a defect in it: a reviewer showed empirically that a width-changing
`resize` after a clear resurrects the cleared lines, because `replaceWith`
computes cyclic indices from a `_startIndex` that `trimStart` left non-zero.
Every live row then reports a negative index. Both guards added here therefore
misfire in that path, conservatively: the anchor is dropped and the selection is
treated as dead when both are in fact valid. The resurrection is pre-existing
and present in stock 4.0.0 too, so this branch does not introduce it, but the
"negative row means cleared away" invariant is narrower than the doc comments
claim and no test covers resize-after-clear.

2026-08-09T23:30-0700 Fixed the above rather than leaving it documented.
Reproduced it first, since it was a reviewer's claim and not yet my own
measurement: on a buffer of 6 with 2 trimmed, `replaceWith` of 3 items reads
back `[old0, old1, new0]`. So it is worse than "resurrects the cleared lines":
the tail of the replacement is also unreachable, because the list is rotated
against itself. `replaceWith` adopts through `_getCyclicIndex`, which offsets by
`_startIndex`, and only reset `_startIndex` afterwards, so it wrote at one
rotation and read at another. Moving the reset before the adopt loop fixes it.

The reset has a consequence worth stating: adopting into a slot detaches its
previous occupant, and after a trim those slots hold the trimmed lines, so the
naive fix would detach them, which is exactly the release-build crash the whole
narrow approach exists to avoid. Cleared the leftover slots without detaching
instead, so the "trimmed stays attached, reports a negative index" contract
holds through a reflow too. That also let the loop dropping buffer slots on an
oversized replacement go: it indexed the list rather than the replacement, and
could reach and detach those same trimmed lines.

Five of the six new triage-side tests fail against the previous pin, including
`terminalSelectionIsLive` returning false for a row that is genuinely present.
So the invariant the doc comments claim is now true on the resize path, rather
than narrowed.

2026-08-09T23:55-0700 Review loop, correcting the entry above: scoping this
defect to "after a clear" was wrong, and it understated it twice over. The
trigger is a rotated backing array, and `push` rotates it every time it evicts
from a full scrollback, so no clear is needed at all. Measured against stock
4.0.0: with `maxLines: 30`, 60 lines written and then a width change, row 11
reports index 10 and row 0 reports 29. Worse, when the reflow result is shorter
than the rotation, the leading slots are never written and reading row 0 throws
`Null check operator used on a null value` from `operator []`; widening a
window whose wrapped scrollback has overflowed reproduces it. Both are present
in the released 4.0.0 and neither needs `ESC[3J`.

That makes this fix considerably more valuable than "a companion to the clear
fix", and it is a better candidate for the original report of duplicated
content and missing history than the clear path was, since it needs nothing but
a full scrollback and a resize. Added four regression cases in the fork (two at
the buffer level, two driving a real `Terminal`), all of which fail on stock.
Commit message, pubspec comment and this entry now describe the real scope.

2026-08-10T02:32-0700 Round 3, and the same comment wrong a second time. The
21:05 rewrite said that when the replacement is shorter than the rotation "the
leading slots are never written at all". Measured on the unfixed code with a
list of 4 rotated by 2 and a replacement of 3, it reads back as the third
replacement element, then a null dereference, then the first: slot 0 is
written, and it is row 1 that throws. So a row can hand back the wrong new
element, a dropped one, or throw, and the ordering is not worth predicting.
Reworded in the fork, the pubspec and here, and pinned with a test at that
exact shape so the prose has something holding it to the behaviour.

2026-08-10T02:32-0700 Round 3: three factual claims in this file and the
pubspec were wrong, all of them counts. Master carries five commits beyond
`v4.0.0` (four non-merge), not three. The fork's tests fail 9 against stock,
not 7. The devlog recorded a pin two commits behind the one actually shipped.
The pubspec's commit-count parenthetical has now been wrong three times, so it
is gone: the comment describes what `lib/` contains and tells the reader to run
`git diff v4.0.0..<ref> -- lib/` instead of trusting a number that drifts every
time the branch gains a commit.

2026-08-10T02:32-0700 Round 3: strengthened the scroll-anchor case, which was
still passing against the old pin even after being made to assert its offset.
The offset reads 20 either way, because the rotation happens to give that line
the same absolute index; what differs is which line actually sits at row 2. It
now asserts that identity too, and all six width-change cases fail against the
previous pin rather than five.

## Verification

- `flutter analyze lib/`: no new issues (3 pre-existing, in untouched files).
- `flutter test`: 301 passing, including the 5 new cases.
- The override was proven to be doing work by removing it and re-running: a
  surviving row reports 16 instead of 0, the scroll anchor returns 30.0 instead
  of releasing, and a cleared line reports 0 rather than a negative row, so it
  cannot even be identified. All three pass with the override in place.

2026-08-09T23:30-0700, after the `replaceWith` fix:

- xterm fork: 121 tests passing. Run against stock 4.0.0's
  `circular_buffer.dart`, 9 of them fail, so every test this fork adds is
  load-bearing and nothing else in the emulator regresses.
- `flutter analyze lib/`: unchanged, 3 pre-existing issues (one of them in
  `main.dart`, which this branch does not touch on the lines concerned).
- `flutter test`: 307 passing, up from 301.
- The six new cases were run against the previous pin first, where all six now
  fail (5 pass, 6 fail of 11), which is what says they test the fix rather than
  passing vacuously.

## Next Steps

- Comment on upstream PR 225 confirming the analysis with a second reproduction;
  a competing PR would not help, since 225 is already correct and unmerged. The
  `replaceWith` rotation is a separate defect that 225 does not cover and that
  reproduces on stock 4.0.0 with no clear involved, including as a crash, so it
  is worth its own upstream issue and probably its own PR.
- The fork's `analysis_options.yaml` still lists `dart_code_metrics` under
  `analyzer: plugins:` with its config block, left behind when `1a3e7c4` dropped
  the dev dependency. Dev-only and outside `lib/`, so it does not reach this
  app, but it means the analysis server cannot load the plugin in the fork.
- Drop the override once a release contains both fixes.

## Commits

- d148cce: fix(triage_client): keep row indices correct across a scrollback clear
- 88c9473: fix(triage_client): pin the xterm fork to the release plus one commit
- fa1ab34: docs(triage_client): state exactly what the xterm pin carries
- 3e863f5: fix(triage_client): repair the reflow that rotates the scrollback
- HEAD: fix(triage_client): describe the reflow rotation accurately
