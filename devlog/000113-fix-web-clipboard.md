# 000113 fix/web-clipboard

**Agent:** Claude (claude-opus-5, 1M context) @ triage branch fix/web-clipboard

## Intent

Reported as "copy and paste don't do anything" in the web client at
`localhost:7777`. Measured against a live paired client: **paste is broken,
copy is not.**

## What Changed

2026-08-01T10:20-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
stopped intercepting `Cmd/Ctrl+V` in `_windowKeyDownListener`. The branch is
kept, empty and commented, rather than deleted, so the next reader does not
re-add the interception.

2026-08-01T10:30-0700 same file: the clipboard `writeText` rejection is logged
via `debugPrint` instead of being dropped by an empty `catchError`.

2026-08-01T19:29-0700 `devlog/000113-fix-web-clipboard.md`: addressed both PR
review comments: the captured selection sample now uses a `<local-path>`
placeholder instead of a real home path, and the Agent line spells the model as
`claude-opus-5, 1M context` rather than the bracketed `[1m]` suffix, which read
as a stray terminal escape.

2026-08-01T22:00-0700 same file: reverted the `Cmd/Ctrl+C` selection-fallback
rewrite, restoring `main`'s version verbatim. It was a no-op resting on a false
premise; see Issues.

2026-08-01T22:35-0700 same file: fixed the `_bindContainerEvents` / `dispose`
asymmetry that had been recorded as a follow-up. The cached-container path now
binds too, the four container listeners moved from `late final` to nullable and
are released through a new `_unbindContainerEvents`, and a `_containerEventOwners`
map makes a pane take the container off its predecessor as it adopts it.

2026-08-01T22:50-0700 same file: `dispose` now discards the cached session only
when this pane still owns it, instead of unconditionally. A pre-existing bug that
the change above would have widened; see Issues.

## Decisions

2026-08-01T10:22-0700 Left paste entirely to the browser rather than fixing the
`readText` call. Reasoning: `preventDefault` on the keydown is what suppresses
the native paste action, and with it the `paste` event. The native path needs no
permission at all, while `readText` needs `clipboard-read`, which sits at
`prompt` and is denied permanently by a single dismissal. The branch left behind
is inert: `_keyboardEventToInput` already returns null for a ctrl/meta-modified
"v", so deleting it would behave identically. It is kept as a marker next to the
reason, not because it changes what happens.

2026-08-01T18:08-0700 Did not fix the container-listener binding gap found along
the way (see Research). Reasoning: it does not block paste, and a blind fix
risks double-binding. Recorded as a follow-up instead. **Superseded** by the
22:35 entry below, on the user's call, once the double-binding had somewhere to
go.

2026-08-01T22:00-0700 Dropped the selection-fallback change rather than keeping
it as a latent fix. Reasoning: it changed no behaviour, and the comment
justifying it was wrong on the mechanism (see Issues). Its one real effect was
deleting the `"Instance of 'Selection'"` guard, which is the only thing keeping
that sentinel out of the user's clipboard if it ever does surface. Shipping a
no-op with a false rationale attached is worse than shipping nothing.

2026-08-01T22:35-0700 Fixed the binding gap by binding on both paths rather than
by making `dispose` merely tolerant. Reasoning: tolerance stops the crash but
leaves an adopted container with no paste, focus or Tab handling of its own,
which is a silent half-working terminal. The double-binding that made this look
risky in the first place is real (a rebuild mounts the replacement pane before
disposing the one it replaces, and both hold the same cached element), so it is
handled head-on: `_containerEventOwners` records who is bound per session, and
binding takes the container off the previous owner first. `dispose` gives up the
ownership entry only when it is still ours, so a pane that has already been
superseded cannot unbind its replacement on the way out.

## Research & Discoveries

2026-08-01T17:55-0700 **Measured on a live paired client.** A capture-phase
probe on `window`, registered after the app's own listener so plain
`stopPropagation` does not suppress it, reading `defaultPrevented`:

| Chord | App handler ran | `term.getSelection()` | `window.getSelection()` | Native event |
| --- | --- | --- | --- | --- |
| `Cmd+C` in terminal | yes | `"EMSDK_NODE = <local-path>"` | `""` | suppressed |
| `Cmd+V` in terminal | yes | n/a | `""` | **never fired** |
| `Cmd+V` in a plain input | no | n/a | `""` | fired, text delivered |

**Copy works.** Pasting into a scratch input afterwards returned exactly the
selected terminal text, so the whole chain including `writeText` is intact.
`navigator.clipboard.writeText` resolves, and `clipboard-write` is granted.

**Paste is broken**, and the cause is confirmed: the app calls `preventDefault`,
so no `paste` event is ever generated. The probe blocked delivery anyway, so
nothing reached the live session during the test.

The original report is explained by copy and paste being tested together: the
copy succeeded, the paste back into the terminal did not, and both looked dead.

2026-08-01T17:58-0700 `window.getSelection()` is always empty over the terminal
because xterm's DOM renderer sets `user-select: none` and draws its own
selection overlay. That is why the copy fallback is unreachable:
`term.getSelection()` always wins when a highlight is visible.

2026-08-01T18:08-0700 **Follow-up found, fixed at 22:35 rather than deferred.**
`_bindContainerEvents()`
runs only on the container-creation path. The cached-container path (line ~162)
skips it, yet `dispose()` unconditionally reads `_containerMouseDownSubscription`
and `_containerPasteListener`, which are `late final` and would throw
`LateInitializationError` there. That throw aborts the rest of `dispose()`, so
the paste listener, the input router unbind, the resize observer, the focus node
and the controller all leak with it, and `_discardCachedSession` at the end never
runs either. That last one turned out to matter more than the leaks: see the
22:50 entry under Issues. Paste still works regardless, because with
the keydown interception gone xterm's own paste handling reaches `onData`, so
delivery has a second path.

## Issues

2026-08-01T10:12-0700 **A wrong hypothesis, recorded so it is not re-run.** The
pane mounts inside `flt-glass-pane`'s shadow root, and a synthetic test
suggested `window.getSelection()` could not see a selection inside a shadow
tree, returning `""` with `rangeCount == 1`. A `ShadowRoot.getSelection()`
fallback was written on that basis. Re-testing with a **real drag selection**
rather than a programmatically added `Range` returned the full text, so the
premise was false and the change was reverted. A programmatic
`Selection.addRange` into a shadow tree does not behave like a user selection.

2026-08-01T10:18-0700 The local `flutter test --platform chrome` suite fails 65
tests on clean `main`, identical counts to this branch (213 passed, 2 skipped,
65 failed), while CI is green on the same commit. Pre-existing and
environmental. Recorded because it means the local web suite is not currently a
usable gate.

2026-08-01T17:50-0700 **A second wrong hypothesis.** Before measuring, the copy
failure was attributed to the broken `"Instance of 'Selection'"` fallback. The
live probe showed `term.getSelection()` returning the text and copy working end
to end. Two rounds of plausible reasoning about this file were both wrong; the
probe settled it in one keystroke.

2026-08-01T22:00-0700 **A third wrong hypothesis about the same fallback, caught
in review.** Having established the fallback was unreachable, it was rewritten
anyway as a "latent" fix, on the reasoning that `html.window.getSelection()`
returns a Dart wrapper whose `toString` yields `"Instance of 'Selection'"`. That
is not what the old code did. It already passed the object to
`js_util.callMethod(obj, 'toString', [])`, the identical call the rewrite used,
so the stringify never changed and the rewrite was a runtime no-op. Its only
real effect was deleting the sentinel guard, which made the hypothetical case it
claimed to fix strictly worse: instead of copying nothing, copy would put the
literal `Instance of 'Selection'` on the clipboard. Reverted to `main`'s version.

The lesson is the same one this file already records twice, applied to a
narrower target: three hypotheses about this fallback, none of them measured,
all three wrong. The unreachable path was never worth reasoning about at all.

Note that the body of commit fa6de9a still asserts the false rationale. It is
already pushed, so it is left alone rather than force-pushed over; this entry is
the correction.

2026-08-01T22:50-0700 **An unconditional discard that predates this branch,
caught in the second review round.** `dispose` ends with
`_discardCachedSession`, which disposes the xterm instance and drops the
container, terminal and input route from the shared maps. A rebuild mounts the
replacement before disposing the pane it replaces, so the pane on its way out
destroys the terminal the incoming one adopted a frame earlier, leaving a live
session drawn on a dead grid.

That is `main`'s behaviour, not something this branch introduced: a pane that
took the creation path always had its listeners assigned, so its `dispose` always
ran to the end. What this branch changed is the reach. Panes on the cached path
used to throw before that line, and the binding fix removed the throw, so the
destructive call went from one class of pane to every pane. It had to be fixed
here either way.

The `_containerEventOwners` map added for the listeners already answers exactly
the question that decides this, "is anyone else holding this session", so the
discard now sits behind the same ownership check. Ending a session for real still
goes through `TerminalPane.destroySession`, which is unconditional and unchanged.
Worth recording that the ownership map was written for a one-frame double-paste
window and turned out to be load-bearing for something considerably worse.

## Verification

- `flutter analyze`: 4 issues, all pre-existing on `main`, none in the touched file.
- `flutter test`: 280 passed.
- `flutter test --platform chrome`: unchanged from `main` (see Issues).
- Live measurement against the running daemon, above.

2026-08-01T18:35-0700 **Confirmed end to end against a rebuilt client.** Built
the web bundle, installed via `scripts/install.sh`, and handed over: PID 34122,
PPID 1, running inode matching the installed binary, HTTP 200 in 6.8ms. The
daemon serves the new bundle (`main.dart.js` sha256 `96390af6d2575386`, against
`752af328883b55d0` for the pre-fix build), so the test exercised the fix rather
than a cached client.

| Check | Before | After |
| --- | --- | --- |
| `Cmd+V` sets `defaultPrevented` | true | **false** |
| native `paste` event | never fired | **fires, payload intact** |
| paste reaches the session | no | **yes, text appeared at the prompt** |
| copy round-trip | worked | **still works, exact text** |

Delivery was verified on a scratch session and the pasted characters removed
afterwards. The earlier probe runs used a window-capture listener that called
`stopImmediatePropagation`, so nothing reached any live session during
diagnosis.

The 2026-08-01T22:00-0700 revert does not disturb this: it restores `main`'s
code on a path the table above never exercised.

2026-08-01T22:40-0700 **The teardown fix has no automated cover.**
`terminal_pane_web.dart` imports `dart:html`, so the VM suite that all 280 tests
run under cannot load it, and the chrome suite that could is the one failing
wholesale on `main` (see above). Both the adopted-container binding and the
ownership handover are therefore argued from the code rather than demonstrated,
which is the weakest part of this branch. Worth exercising by hand: switch
between two sessions repeatedly, then confirm a single paste inserts once.

## Next Steps

- Exercise the adopted-container path by hand: switch sessions repeatedly, then
  paste, and confirm the text arrives exactly once.
- Investigate why the local chrome test suite fails wholesale.

## Commits

- fa6de9a: fix(triage_client): stop swallowing paste in the web terminal
- 8feb148: docs(devlog): record the end-to-end paste verification
- 280a130: docs(devlog): address review comments on the clipboard devlog
- HEAD: fix(triage_client): give an adopted web terminal its own container listeners

Rebased onto `origin/main` at 6fa9793, so the three hashes above are the
post-rebase ones. The pre-rebase commits were 4ca2edf, 84ae739 and 635ee4f.
