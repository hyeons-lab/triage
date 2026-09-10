# 000144-11: Fix xterm.dart crash replaying scroll-region history

## Thinking

With the `output_seq` epoch fix deployed, `stuck-codex` (`session-218`) stopped being
deaf and started reporting `load failed` instead. Two false leads came first, and both
are worth recording because each cost a round trip.

The console line was `main.dart.js:28559`. That line turned out to be `console.log(a)`
*inside `debugPrint` itself* — a console line number for a logged string always points at
the logger, never at the throw site. Hunting statically from that number found nothing,
because there was nothing there to find.

The second lead was the message alone: `Null check operator used on a null value`. The
`catch` in `_loadDaemonSessionInto` spans the entire load — attach, the swap `setState`,
`_regroupRail`, `_drainPendingEvents`, resize — and discarded the stack, so the message
did not say which step threw. The server showed the attach had *succeeded* (the PTY was
resized 99→108 cols and a keystroke landed), so the failure was somewhere after it.

Capturing the stack was the step that resolved it. Release stack frames are minified, so
the build was made with `--source-maps` and the frames mapped back:

```
IndexedItem._move                     circular_buffer.dart:350
IndexAwareCircularBuffer._moveChild   circular_buffer.dart:52
IndexAwareCircularBuffer.insert       circular_buffer.dart:192
Buffer.index                          buffer.dart:239
Buffer.lineFeed                       buffer.dart:264
```

The crash is in the vendored xterm.dart, not in client code. `_move` asserts `attached`
and reads `_owner!`; in release the assert is compiled out, so it dereferences null.

Root cause, established by recording the detach site on the item rather than by reading:

```
IndexedItem._detach
IndexAwareCircularBuffer._adoptChild   circular_buffer.dart:41
IndexAwareCircularBuffer.[]=           circular_buffer.dart:119
Buffer.scrollDown                      buffer.dart:211
Buffer.reverseIndex                    buffer.dart:274
EscapeParser._escHandleReverseIndex    (ESC M)
```

`Buffer.scrollUp` and `scrollDown` shift lines with `lines[i] = lines[i +/- n]`, which
routes through `_adoptChild` and leaves one line object referenced by both its old and its
new slot. The `_detach` inside a later `_adoptChild` then detaches an element that is still
reachable from the other slot, so the backing array holds an element that is present but
detached. The next `insert` shifts that slot with `_moveChild`, and `_move` fails on it.

Codex reaches this because its redraws set and clear scrolling regions constantly
(`ESC[1;27r`, `ESC[r`, `ESC[1;39r`, `ESC[1;9r`) and issue reverse index.

Two facts ruled out the epoch fix as the cause before any of this was diagnosed: every
read of `historyHighWaterSeq` in `lib/` is null-safe (there is no `historyHighWaterSeq!`
anywhere), and the crash reproduces against a bare `Terminal` with no triage_client code
involved. It is also not a capacity problem — it throws at `maxLines` 100 and at 200000
alike. Any fresh load of this session would have crashed before the epoch fix too; the two
bugs were independent and stacked, which is why the session looked deaf rather than broken.

The fix belongs in `_moveChild`, which is where the invariant is violated, but the honest
framing is that `_moveChild` is the victim: it is handed an element the buffer already
poisoned. Placing the element with `_attach` rather than `_move` is the same assignment for
an element still attached to this buffer, and repairs one that is not. `_move` had no other
caller and goes with it, so nothing is left holding that precondition. There is no patch
mechanism for pub dependencies in this repo — the only patch machinery
(`scripts/generate-dart-flatbuffers.sh`) rewrites generated flatbuffers output — so the fix
goes in the fork and the pin moves.

## Plan

1. In the `hyeons-lab/xterm.dart` fork, on `fix/trim-start-reindex-v4`:
   - In `_moveChild`, place the element with `_attach(this, toIndex)` instead of
     `_move(toIndex)`, and return early when a shift resolves to its own slot (that
     sequence clears the slot it just wrote and drops the element).
   - Remove the now-unused `_move`.
   - Add regression coverage to `test/src/utils/circular_buffer_test.dart`: an aliasing
     assignment that leaves an element detached, then an `insert` that shifts it.
2. Verify: the new test fails without the fix with the exact assertion; the full xterm
   suite passes; the real 366KB capture replays at every size the client uses.
3. In `flutter/triage_client`:
   - Bump the `xterm` `dependency_overrides` ref to the pushed fork commit.
   - Keep the stack trace in the `_loadDaemonSessionInto` catch — the message alone cost
     two round trips.
4. Rebuild and deploy via `triage client upgrade`, clearing the override directory first
   so the diagnostic source map is not left behind to mis-symbolicate a later trace.
