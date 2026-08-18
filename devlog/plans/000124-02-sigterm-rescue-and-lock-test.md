# Plan 000124-02: Close the SIGTERM loss vector, and pin the lock discipline

## Thinking

Plan 000124-01 closed the two defects that *wedged* a handover. It deliberately
left the vector that actually destroyed sessions on 2026-08-13: the daemon owns
every PTY master, and a signal that kills it closes all of them, which SIGHUPs
every child. `launchctl bootout` sends SIGTERM. So does `launchctl stop`,
`launchctl unload`, a system logout, and a plain `kill`. Today all of them are
fatal to 40-odd live sessions, and no amount of handover hardening helps, because
handover is something a *successor* initiates and nothing initiates one here.

The daemon currently installs no signal handling at all, so SIGTERM takes the
default disposition: immediate death, no chance to hand anything off.

### Which design

Three ways to make a signal survivable, in ascending order of cost:

1. **Raise `ExitTimeOut` in the plist.** Necessary but useless alone: a longer
   grace period is only worth having if the daemon does something with it.
2. **On the signal, spawn a detached successor and hand over to it.** The
   successor is a normal `triaged --handover`, so the entire three-phase protocol,
   its timeouts, its single-flight guard and its adopt/refuse contract are reused
   as-is. The signal path adds only "start a process, then wait for the handover
   the existing IPC server is already able to serve". This is the pattern that
   rescued the daemon by hand three times on 2026-08-13.
3. **Move the masters into a keeper process that outlives the daemon.** The only
   design that also survives `SIGKILL`, because the descriptors never live in the
   daemon alone. It needs a new process mode, a deposit/reclaim protocol, eager
   registration on the session-create path, and a reaper for entries whose child
   has exited.

Going with (2) plus (1). (3) is stronger on paper and worse in practice right
now: it puts a new process in the hot path of session creation, which is the code
least safe to change without live testing, and it defends a case (`SIGKILL`) that
nothing in the incident history actually hit. Every real loss came from SIGTERM.
(2) reuses a protocol that has been exercised repeatedly instead of inventing a
second one, and its failure mode is "no worse than today".

What (2) costs is time: the successor replays every historical session's log
before it can send its adoption byte, measured at ~22.6s and growing. That is why
(1) has to come with it: launchd's default grace period is far too short for a
successor to finish starting, and the SIGKILL that follows is exactly the death
we are trying to avoid.

### Signal-handling mechanics

A handler cannot do this work: spawning a process, taking locks, and allocating
are all forbidden in a signal handler. Two ways out, and the choice matters:

- **`sigwait` on a dedicated thread** requires blocking the signal in every
  thread, which means blocking it *before* any thread is spawned. A blocked
  signal mask survives `fork`+`exec`, so every session shell would start with
  SIGTERM blocked and become unkillable. Fixing that means touching the session
  spawn path, the one place worth not touching.
- **A self-pipe**: the handler does nothing but `write` one byte (async-signal
  safe), and a normal thread reads it and does the real work. Handled
  dispositions reset to the default on `exec`, so children are unaffected.

Self-pipe, for the child-process reason.

The handler is installed in `main`, next to the `SIGTTOU`/`SIGTTIN` ignore, but
the thread that consumes the pipe cannot start until the manager exists (after
adoption). A signal in that window is not lost: it sits in the pipe and is
serviced as soon as the thread starts. That is strictly better than dying
mid-startup while holding freshly adopted masters.

### When *not* to rescue

`triaged service stop` and `service uninstall` mean "stop the daemon", and
resurrecting a detached one behind the operator's back would be wrong.
`uninstall` especially must leave nothing running. Both send a new
`DisableShutdownRescue` IPC request before touching `launchctl`/`systemctl`, so
the SIGTERM that follows is a plain exit. `TRIAGE_NO_RESCUE=1` is the escape
hatch for anyone else.

### If the rescue fails

Keep running, and log loudly. Exiting after a failed rescue guarantees the loss;
staying alive keeps the sessions and leaves a human able to intervene. A *second*
signal after a failed attempt exits immediately, so an operator who means it is
never stuck.

### The lock-scope regression test

000124-01 moved `write_input`'s actor round-trip off the sessions lock but shipped
no test, because "block an actor" sounded inherently timing-dependent. It is not,
if the actor is never started: a `Live` session whose `Sender` goes to a receiver
the test holds and never services parks any caller in `recv_actor_result`
indefinitely. Receiving the `WriteInput` command is the synchronisation point,
since after it the writer is provably inside the round-trip, and `list_sessions` must
then still return. No sleeps, no PTY buffer sizes, no child processes: on the old
code it deadlocks, on the new code it passes.

## Plan

1. `handover.rs`: add `SHUTDOWN_RESCUE_TIMEOUT`, the budget for the whole rescue,
   sized to cover a successor's cold start plus the three-phase handshake. Lives
   with the other handover deadlines rather than in the unix-only shutdown module
   so `service.rs` can assert the plist grace period exceeds it on every target.
2. New `shutdown.rs` (unix): self-pipe signal handlers for SIGTERM/SIGINT/SIGHUP,
   a rescue thread, and the rescue itself: skip when disabled or when there is
   nothing live to save, otherwise spawn a detached (`setsid`) `triaged
   --handover` and wait for the handover to carry us to `process::exit(0)`.
   Give up early if the successor dies; on failure keep serving, and exit on a
   second signal.
3. `session.rs`: expose what the rescue needs without ever blocking on the
   sessions mutex: `handover_in_flight()`, and a `try_lock`-based live-session
   count that reports "unknown" rather than waiting.
4. `ipc.rs`: `WireRequest::DisableShutdownRescue`, and `FD_CLOEXEC` on the owner
   Unix listener (the half of 000124-01 step 4 that was left undone).
5. `service.rs`: `ExitTimeOut` in the plist and `TimeoutStopSec` in the systemd
   unit, both above `SHUTDOWN_RESCUE_TIMEOUT` (compile-time asserted); `stop` and
   `uninstall` disable the rescue first.
6. `main.rs`: install handlers early, start the rescue thread once the manager
   owns its sessions.
7. Tests: the lock-scope regression test described above; plist/unit grace-period
   tests; rescue-decision unit tests for the skip conditions.
8. Full local CI gate set before pushing.

### Out of scope

- The keeper process (design (3)). Written up in the devlog as the remaining
  `SIGKILL` gap, with what it would cost.
- Bounding `recv_actor_result`, for the reasons in 000124-01.
- Making `--handover` refuse a controlling terminal. With `SIGTTOU` ignored the
  trap is survivable, and refusing would break the launch path used all night.
