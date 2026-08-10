# 000119-01 resize arbitration

## Thinking

Reported as three separate bugs: duplicated scrollback with history missing on
Android, history not reflowing on a web window resize, and character-level
corruption in the live frame (`~/.pub-cache/hosted` rendering as
`~/.pus-cache+hosted`, `Agent` and `Running…` colliding into `AgeRunning…`).

They are one bug. The evidence that settles it is a paste where the same
passage appears four times, each wrapped at a different width, one of them at
roughly 28 columns. Nothing on a desktop is 28 columns wide; that is a phone.

The mechanism: `SessionActor::resize` takes whatever size arrived last, with no
arbitration across attached clients, and every client asserts its own fitted
size automatically. So the shared PTY's width follows whichever device most
recently fitted. Each change makes a full-screen program repaint, and because
the previous frame occupied a different number of physical rows the new one
does not land on top of it, so both stay in the scrollback. Repeat per device
switch and the same text accumulates at several widths, crowding real history
out of a bounded buffer.

Things ruled out along the way, each of which had looked plausible:

- Animation churn. Resize-out is debounced 100ms and the timer captures the
  latest size, so a sidebar animation collapses to one resize.
- A feedback loop between host and client. Clients ignore the host's size
  broadcast for their own terminal (`main.dart`, the `Snapshot` branch) and only
  record it, so there is nothing to oscillate.
- The single-client path. Measured directly: 120 to 137 to 147 columns, `stty
  size` agreeing each time, and a 127-character line re-wrapping cleanly with no
  corruption.

Of the arbitration policies, smallest-client-wins (what tmux does) was rejected
in favour of foreground-owns: a phone in a pocket should not shrink a desktop
terminal. The cost is one repaint per device switch, which is unavoidable under
any policy that lets both devices render at their own width.

Half of this already exists. `_refitActiveSession` is documented as reclaiming
the PTY "for the device they are now on", and runs on resume from occlusion.
What is missing is the other half: a backgrounded client never goes quiet.

Two details make the difference between this working and this thrashing. First,
`inactive` has to count as background, because a blurred desktop window and an
unfocused browser tab both report it and both are cases where the user is
looking elsewhere. Second, reclaiming must be conditional: `_refitActiveSession`
deliberately jiggles the host to force a repaint, and doing that on every
alt-tab would be its own churn. So reclaim only when the PTY has actually
drifted from this device's size, which needs a record of *this device's* size,
which `lastFittedCols` cannot provide since it is also written from host
broadcasts.

## Plan

1. `SessionVm.ownFittedCols/Rows`: the size this device fitted to, written only
   where this client fits, never from a host broadcast.
2. `_clientForeground`, driven by the lifecycle handler. `resumed` is the only
   foreground state; `inactive`, `hidden`, `paused` and `detached` are not.
   Defaults true so a platform that reports nothing behaves as before.
3. Gate the automatic resize-out on it, recording the fit either way.
4. On regaining focus without occlusion, reclaim only when own size and the
   host's settled size disagree.
