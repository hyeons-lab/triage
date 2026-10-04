# 000160: fix/shift-enter-newline

## Agent

2026-10-04T00:42-0700.

## Intent

Shift+Enter inserts a newline instead of submitting: send LF rather
than CR when Shift (and no other modifier) accompanies Enter, on both
the web and native panes. Stacked on `perf/lazy-history`.

## What Changed

- `bytesForEnterKey` in `lib/terminal/control_bytes.dart`: LF for
  shift-only Enter, null to keep the default path.
- Native pane intercepts Enter/numpadEnter in
  `_handleTerminalKeyEvent`; web capture listener uses the helper in
  its Enter branch (Alt+Enter ESC+CR preserved).
- Tests: helper unit tests (all modifier combos) + native widget tests
  (Shift+Enter LF, plain/Ctrl+Shift fall-through).

## Decisions

- LF (`\n`), not kitty `CSI 13;2u`: raw-mode apps distinguish CR/LF
  with no negotiation, and cooked shells treat both as accept-line,
  so the fallback is harmless where unsupported.
- Alt+Enter keeps its existing ESC+CR on web; plain Enter keeps the
  emulator default on both panes.
- Soft-keyboard (IME) Enter is out of scope: no shift state is
  observable there.

## Issues

(none yet)

## Commits

- HEAD: fix(client): shift+enter inserts a newline instead of submitting

## Progress

- Worktree created on `perf/lazy-history` (8f43dfd).
- Discovery: web already intercepts all Enter in a window-capture
  listener; native falls through to xterm's handler.
- Implemented + gates green (analyze clean, 666 flutter tests).

## Research & Discoveries

(none yet)

## Lessons Learned

(none yet)

## Next Steps

- Shared helper + unit tests, both pane wirings, widget test, gates,
  commit, stacked PR.
