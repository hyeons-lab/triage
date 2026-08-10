# 000118-01 xterm scrollback clear

## Thinking

`CircularList.trimStart` advances the list's start index without advancing
`_absoluteStartIndex`, the base every element measures its index from. Its only
caller is `Buffer.clearScrollback`, which runs on `ESC[3J`, i.e. whenever
anything runs `clear`. Afterwards the buffer holds a mixed index space:
surviving lines report a row too high by the number trimmed, while lines written
later report correctly.

Two consumers read `BufferLine.index`, and both misbehave:

- `TerminalScrollAnchor` pins the viewport at `line.index * lineHeight`, so a
  scrolled-up viewport jumps after a clear.
- Selection anchors resolve rows through it, so a held selection renders and
  copies from the wrong lines.

The second could be handled locally by dropping the selection. The first cannot:
it is arithmetic inside xterm's own data model. That asymmetry is what justifies
patching xterm rather than working around it.

Upstream has the fix only as PR 225, unmerged since 2026-05-08, against a
release that is two years old. A pull request is not something a build can
depend on, so shipping it means a fork.

PR 225 also records something important. The intuitive fix detaches the trimmed
lines as well, and that version was tried and reverted: `CellAnchor.y` and
`.offset` guard `_owner!.index` with `assert(attached)` alone, so in a release
build, where asserts are stripped, an anchor still holding a detached line
dereferences a null `_absoluteIndex` and throws. The narrow fix therefore leaves
trimmed lines attached, and makes retiring stale holders the caller's job.

That decides how to detect a cleared line on our side. `attached` stays true, so
it cannot be the signal; but a trimmed line now sits before the start of the
buffer, so its index is negative. That is unambiguous and cheap.

## Plan

1. Fork `TerminalStudio/xterm.dart`; on a branch, advance `_absoluteStartIndex`
   in `trimStart` and add a test. Do not detach.
2. Point `dependency_overrides` at the fork; let `pubspec.lock` pin the commit.
3. `terminalSelectionIsLive`: does a range still refer to rows in the buffer.
4. `TerminalScrollAnchor.desiredOffset`: release an anchor on a negative row.
5. Pane: require liveness before offering a copy, and clear a selection whose
   rows were cleared out from under it.
6. Test by driving a real `ESC[3J` through the emulator, and prove the override
   matters by re-running the same tests without it.
