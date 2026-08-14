# Plan 000123-01 — Make handover survivable: job control and lock discipline

## Thinking

Five daemons wedged across 2026-08-11 and 2026-08-13, and one set of live
sessions destroyed. Every incident traced to the environment around the handover
protocol, not the protocol itself. The protocol has three phases, named timeouts,
a single-flight guard, a bind grace, a teardown commit byte, and `SCM_RIGHTS` fd
passing (000096). None of that was at fault.

The structural fact underneath all of it: **the process that owns the PTY masters
is the process you restart, upgrade, and kill.** Handover exists to move the
descriptors before that death, so anything that can (a) stop the owner
mid-handover or (b) make the owner unable to serialize its sessions turns a
routine upgrade into an outage.

Two defects do exactly that, and both are confirmed in code (grep for `setsid`,
`SIGTTOU`, `SIGTERM`, `CLOEXEC` in `crates/triaged/src/` returns nothing at all):

1. **Job control stops the daemon mid-swap.** Handover teardown calls
   `tcsetattr`. For a process in a *background* process group that raises
   `SIGTTOU` unconditionally, independent of TOSTOP. A `triaged --handover`
   launched from any interactive session is such a process, and it stops *after*
   adopting every PTY master, the control socket, and the TCP listener. The
   sessions are then hostage inside a stopped process: it cannot be killed without
   losing them, and `kill -CONT` alone does not help because it re-stops on the
   next `tcsetattr`. Observed three times in one hour from a single `agy` session
   working on this repo, which is the most natural place for someone to run it.
   Recovery each time required attaching lldb to force `signal(SIGTTOU, SIG_IGN)`.

   The same mechanism stops *children*: a `git rev-parse --show-toplevel` spawned
   into that background group was stopped by job control, and because
   `Command::output` reads until EOF, the actor thread blocked forever on a child
   that would never exit.

2. **The global sessions mutex is held across a blocking actor round-trip.**
   `SessionApi::write_input` takes the guard (session.rs:1856) and still holds it
   when it calls `actor.write_input(...)` (session.rs:1881), which blocks in
   `recv_actor_result` until the actor answers. When that actor was itself blocked
   in `write_all` to a PTY whose child had stopped reading, the mutex was never
   released. Everything that touches sessions then piled up on `Mutex::lock`:
   `list_sessions`, `snapshot_session`, `summary_rows`,
   `run_activity_persistence_loop`, and, decisively,
   `serialize_active_sessions` — so the daemon could not be handed over at the
   exact moment we needed to. HTTP accepted connections and returned 0 bytes.

   The repo already knows the right shape: `request_summary_rows` (session.rs:4866)
   documents "the caller clones `tx` while briefly holding the sessions lock, then
   calls this OFF-LOCK so the actor round-trip never blocks other session
   operations." `write_input` simply never got that treatment.

A third, lesser defect contributed: the TCP listener has no `FD_CLOEXEC`, so it
leaks into every exec'd child. A `git` child was observed holding :7777, which
means a leaked listener can keep the port bound after the owner exits and hand the
successor a spurious `EADDRINUSE`.

Deliberately **not** in this branch: making a SIGTERM'd owner hand off before
dying. That is the remaining loss vector (it is what `launchctl bootout` hit), but
it cannot be done safely inside launchd's default grace period, since Phase 2
takes 10-15s for session deserialize plus summarizer model load. Doing it properly
means either raising `ExitTimeOut` in the plist or moving the masters into a
separate keeper process that outlives daemon restarts. That is an architecture
decision, not a bug fix, and it deserves its own branch.

## Plan

1. `main.rs`: ignore `SIGTTOU` and `SIGTTIN` for the lifetime of the process, set
   once at startup after help/version have returned and before any handover work
   begins. A background `tcsetattr` is permitted to proceed when `SIGTTOU` is
   ignored, so teardown completes instead of stopping the owner. This is the one
   change that retires failure mode 1, and it is what the lldb rescue did by hand.
2. `session.rs`: make `write_input` release the sessions guard before the actor
   round-trip. Clone the `Sender`, validate the lease while holding the guard,
   drop it, then send and await off-lock — the `request_summary_rows` pattern.
3. `session.rs`: spawn the cwd-detection `git` child with `setsid` so it has no
   controlling terminal and cannot be job-control-stopped by an inherited one.
4. `main.rs` / `ipc.rs`: set `FD_CLOEXEC` on the TCP listener and the owner unix
   socket so neither leaks into exec'd children. Handover is unaffected:
   `SCM_RIGHTS` passing is not an exec.
5. Tests: cover that `write_input` does not hold the lock (a blocked actor must
   not prevent `list_sessions`), and that the signal dispositions are ignored.
6. Run the full CI gate set locally before pushing: `cargo fmt --all --check`,
   `cargo clippy --workspace --all-targets --all-features -- -D warnings`,
   `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps
   --locked`, and the triaged tests.

### Out of scope

- The handover protocol, its phases, and its timeouts.
- Descriptor ownership plumbing (`OwnedFd` / `UnadoptedFds`), which is 000122.
- SIGTERM handoff and the keeper-process design, per the reasoning above.
- Bounding `recv_actor_result` with a timeout. Tempting, but a wrong deadline
  turns a slow-but-healthy session into a spurious error; with step 2 in place a
  stuck actor no longer takes the daemon down with it, which is the property that
  actually matters here.
