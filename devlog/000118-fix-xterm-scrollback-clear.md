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
master, which carries three unreleased commits beyond `v4.0.0`, two of them
behavioural (colour 15 rendering in `palette_builder.dart`, and Android
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

## Verification

- `flutter analyze lib/`: no new issues (3 pre-existing, in untouched files).
- `flutter test`: 301 passing, including the 5 new cases.
- The override was proven to be doing work by removing it and re-running: a
  surviving row reports 16 instead of 0, the scroll anchor returns 30.0 instead
  of releasing, and a cleared line reports 0 rather than a negative row, so it
  cannot even be identified. All three pass with the override in place.

## Next Steps

- Comment on upstream PR 225 confirming the analysis with a second reproduction;
  a competing PR would not help, since 225 is already correct and unmerged.
- Drop the override once a release contains the fix.

## Commits

- HEAD: fix(triage_client): keep row indices correct across a scrollback clear
