# 000113 fix/web-clipboard

**Agent:** Claude (claude-opus-5[1m]) @ triage branch fix/web-clipboard

## Intent

Reported as "copy and paste don't do anything" in the web client at
`localhost:7777`. Measured against a live paired client: **paste is broken,
copy is not.**

## What Changed

2026-08-01T10:20-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`
— stopped intercepting `Cmd/Ctrl+V` in `_windowKeyDownListener`. The branch is
kept, empty and commented, rather than deleted, so the next reader does not
re-add the interception.

2026-08-01T10:34-0700 same file — the `Cmd/Ctrl+C` fallback now reads the
document selection through raw `js_util` interop instead of
`html.window.getSelection()`, and the `"Instance of 'Selection'"` blanking is
gone with it. **Latent only:** measurement showed this path is never reached in
the current setup (see Research).

2026-08-01T10:30-0700 same file — the clipboard `writeText` rejection is logged
via `debugPrint` instead of being dropped by an empty `catchError`.

## Decisions

2026-08-01T10:22-0700 Left paste entirely to the browser rather than fixing the
`readText` call — reasoning: `preventDefault` on the keydown is what suppresses
the native paste action, and with it the `paste` event. The native path needs no
permission at all, while `readText` needs `clipboard-read`, which sits at
`prompt` and is denied permanently by a single dismissal.
`_keyboardEventToInput` returns null for anything ctrl/meta-modified, so letting
the event fall through sends no stray literal.

2026-08-01T18:05-0700 Kept the selection-fallback fix even after proving it is
unreachable — reasoning: it is code that provably cannot return text, so if the
renderer ever changes (a canvas or WebGL addon would put the selection back in
the DOM) it would fail silently again. Cheap to fix now, invisible to fix later.

2026-08-01T18:08-0700 Did not fix the container-listener binding gap found along
the way (see Research) — reasoning: it does not block paste, and a blind fix
risks double-binding. Recorded as a follow-up instead.

## Research & Discoveries

2026-08-01T17:55-0700 **Measured on a live paired client.** A capture-phase
probe on `window`, registered after the app's own listener so plain
`stopPropagation` does not suppress it, reading `defaultPrevented`:

| Chord | App handler ran | `term.getSelection()` | `window.getSelection()` | Native event |
| --- | --- | --- | --- | --- |
| `Cmd+C` in terminal | yes | `"EMSDK_NODE = /Users/..."` | `""` | suppressed |
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
selection overlay. That is why the fallback is unreachable: `term.getSelection()`
always wins when a highlight is visible.

2026-08-01T18:08-0700 **Follow-up found, not fixed.** `_bindContainerEvents()`
runs only on the container-creation path. The cached-container path (line ~162)
skips it, yet `dispose()` unconditionally reads `_containerMouseDownSubscription`
and `_containerPasteListener`, which are `late final` and would throw
`LateInitializationError` there. Paste still works regardless, because with the
keydown interception gone xterm's own paste handling reaches `onData`, so
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

2026-08-01T17:50-0700 **A second wrong hypothesis.** Before measuring, the copy
failure was attributed to the broken `"Instance of 'Selection'"` fallback. The
live probe showed `term.getSelection()` returning the text and copy working end
to end. Two rounds of plausible reasoning about this file were both wrong; the
probe settled it in one keystroke.

2026-08-01T10:18-0700 The local `flutter test --platform chrome` suite fails 65
tests on clean `main`, identical counts to this branch (213 passed, 2 skipped,
65 failed), while CI is green on the same commit. Pre-existing and
environmental. Recorded because it means the local web suite is not currently a
usable gate.

## Verification

- `flutter analyze` — 4 issues, all pre-existing on `main`, none in the touched file.
- `flutter test` — 280 passed.
- `flutter test --platform chrome` — unchanged from `main` (see Issues).
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

## Next Steps

- Fix the `_bindContainerEvents` / `dispose` asymmetry.
- Investigate why the local chrome test suite fails wholesale.

## Commits

- 4ca2edf — fix(triage_client): stop swallowing paste in the web terminal
- HEAD — docs(devlog): record the end-to-end paste verification
