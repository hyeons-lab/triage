# 000140-01: sync live flush

## Thinking

`agy` wraps entire streaming responses in a single Mode 2026 block (measured up to 844KB in daemon session logs). `TerminalStore` buffers an open block until its end marker, and every chunk re-arms the 50ms idle watchdog, so the screen freezes for the whole generation. Typing appears to unstick it only because the keystroke ends the block. The daemon actor loop, websocket drain, client socket, TUI poll, and fork repaint were all audited and forward promptly, so the store buffer is the single input-correlated stall.

A byte-threshold flush would tear legitimately large single repaint frames, so a time-based flush is the better trade: small frames complete well inside the interval and stay atomic, while sustained streams paint at a bounded cadence.

## Plan

1. Add `kSyncOutputLiveFlushInterval` (100ms) and a `_syncLiveFlushTimer` to `TerminalStore`; arm on block open, flush-but-stay-open on tick, cancel on close/cap/reset/dispose.
2. Add a regression test: progressive flushes during a sustained stream, atomic close at the end marker with no loss/duplication, no further writes after close.
3. Verify: standalone reducer harness under plain Dart with FakeAsync (sandbox blocks `flutter test`), `dart analyze`, `dart format`.
4. Move the change into this worktree with devlog + plan, then build the release APK and sideload onto the Pixel 10 Pro Fold for on-device confirmation.
