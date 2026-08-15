//! Surviving a terminating signal without taking every session down.
//!
//! This daemon owns the PTY master of every live session, so its death closes all
//! of them at once and the kernel SIGHUPs every child. That makes an ordinary
//! SIGTERM (`launchctl bootout`, `launchctl stop`, `launchctl unload`, a systemd
//! `stop`, a logout, a plain `kill`) indistinguishable from `kill -9` as far as
//! the sessions are concerned. It is what destroyed 16 live sessions on
//! 2026-08-13, and no amount of hardening inside the handover protocol helps,
//! because a handover is something a *successor* initiates and a signal produces
//! no successor.
//!
//! So this module produces one. On a terminating signal the daemon starts a
//! detached `triaged --handover` and keeps serving until that successor drives the
//! ordinary three-phase handover to completion, which ends in `process::exit(0)`
//! inside [`crate::ipc`]'s handover handler, from a different thread than the one
//! waiting here. Nothing about the protocol, its deadlines, or its adopt/refuse
//! contract is re-implemented; the signal path only decides *when* to start a
//! successor and how long to wait for it.
//!
//! Three properties are worth stating explicitly, because each was a choice:
//!
//! - **The successor is `setsid`-detached.** It must not share this process's
//!   process group or controlling terminal, or the same event that terminated us
//!   (a group signal, a supervisor tearing down its job, a hangup) reaches it too
//!   and the rescue rescues nothing.
//! - **A failed rescue keeps the daemon alive.** Exiting after a failed attempt
//!   guarantees the loss; staying up keeps the sessions and leaves an operator able
//!   to intervene. A second signal then exits, so insisting still works, with one
//!   qualification worth knowing at the point of the promise rather than only at the
//!   constant: a signal within `SIGNAL_COALESCE_GRACE` of the first is treated as the
//!   rest of the same teardown burst, not as asking twice.
//! - **`SIGKILL` is still fatal.** It cannot be caught, so the only defence would
//!   be to stop keeping the masters solely in this process (a keeper process that
//!   outlives it). On systemd, [`crate::handover::SHUTDOWN_RESCUE_TIMEOUT`] stays
//!   under the stop grace period (`TimeoutStopSec=150`); on macOS launchd caps
//!   `ExitTimeOut` at 60s, and Phase 2 adopt-on-dead-peer ensures transferred
//!   descriptors are adopted even if launchd SIGKILLs the outgoing daemon before
//!   the rescue finishes.

use std::os::unix::io::RawFd;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};

use crate::handover::SHUTDOWN_RESCUE_TIMEOUT;
use crate::session::SessionManager;

/// Signals treated as "shut down, please".
///
/// `SIGINT` is included deliberately, even though Ctrl-C in a foreground terminal
/// is usually meant as "stop now": a daemon holding dozens of live agent sessions
/// destroys all of them on that keystroke, which is the same failure this module
/// exists to prevent. Anyone who wants the old behaviour has `TRIAGE_NO_RESCUE`.
const TERMINATING_SIGNALS: [libc::c_int; 3] = [libc::SIGTERM, libc::SIGINT, libc::SIGHUP];

/// Environment escape hatch: set to a non-empty value to make a terminating signal
/// a plain exit again. `triaged service stop` / `uninstall` do not need it; they
/// ask the running daemon over IPC (see [`disable_rescue`]).
const NO_RESCUE_ENV: &str = "TRIAGE_NO_RESCUE";

/// How often the rescue re-checks whether the successor has died while waiting.
const RESCUE_POLL_INTERVAL: Duration = Duration::from_millis(200);

/// Minimum budget left for another successor to be worth starting.
///
/// Sized from what a successor actually needs, not from what is merely more than
/// nothing: it replays every historical session's log before it can send its adoption
/// byte, measured at ~22.6s and growing. Starting one with less than that spawns a
/// real detached daemon that cannot possibly finish in time and is then killed, which
/// is worse than not trying.
const MIN_ATTEMPT_BUDGET: Duration = Duration::from_secs(30);

const _: () = assert!(
    MIN_ATTEMPT_BUDGET.as_millis() > RESCUE_POLL_INTERVAL.as_millis()
        && MIN_ATTEMPT_BUDGET.as_secs() * 2 <= SHUTDOWN_RESCUE_TIMEOUT.as_secs(),
    "the retry floor must leave room for at least one poll, and must be small enough that the \
     budget can hold two attempts at it"
);

/// How long into a rescue attempt further signals are treated as part of the same
/// teardown event rather than as an operator insisting.
///
/// The burst drain in [`run_rescue_loop`] only catches signals already queued the
/// instant it runs, and nothing guarantees a pair is that tightly spaced: a logout
/// sends SIGHUP and then SIGTERM, and a supervisor may signal the process group and
/// then the process, milliseconds apart. Without a grace window the commonest
/// rescue-worthy event of all would be misread as insistence and exit immediately,
/// destroying every session mid-rescue.
const SIGNAL_COALESCE_GRACE: Duration = Duration::from_secs(3);

/// How long to wait for this daemon's own control socket before starting a
/// successor. Only ever reached when a stop signal arrives during startup, since
/// after that the socket is already bound.
const OWN_SOCKET_WAIT: Duration = Duration::from_secs(30);

/// How long to let the tracing appender drain before exiting from this thread. See
/// [`exit_now`].
const LOG_FLUSH_GRACE: Duration = Duration::from_millis(250);

/// How soon after a failed rescue another stop signal counts as an operator insisting,
/// rather than as an unrelated stop request much later.
///
/// Without an upper bound, one transient failure would arm an unconditional exit for
/// the rest of the daemon's life, and a stop signal hours later would destroy every
/// live session with no attempt made at all. It has to exceed nothing in particular,
/// but note that it is deliberately *shorter* than a full-budget rescue: the signal
/// after one of those is measured against when that rescue failed, not against when the
/// chain of attempts began.
const INSIST_WINDOW: Duration = Duration::from_secs(60);

/// How long an operator-requested stop suppresses the rescue.
///
/// A window rather than a latch. `service stop` / `uninstall` disable the rescue and
/// *then* ask the supervisor to stop the job, so a latch would leave a daemon whose
/// stop failed (no plist, a `launchctl` error, an aborted uninstall) permanently
/// unable to rescue anything, and the next logout would silently destroy every
/// session. Long enough to cover a slow `launchctl`/`systemctl` and the SIGTERM it
/// produces; short enough that the daemon re-arms itself if that never arrives.
const RESCUE_DISABLE_WINDOW: Duration = Duration::from_secs(120);

/// How many successors one rescue will start before giving up.
///
/// More than one because the most likely early failure is recoverable: a successor
/// that refuses the handover does so precisely when this daemon *kept* its sessions
/// (the commit byte never landed), so the second attempt starts from an intact
/// state. A successor that failed for a permanent reason (an unrunnable binary, a
/// port it cannot get) fails the same way again, which is why this is 2 and not a
/// loop until the budget drains.
const MAX_SUCCESSOR_ATTEMPTS: usize = 2;

/// Write end of the self-pipe, read by the signal handler only.
static SIGNAL_WRITE_FD: AtomicI32 = AtomicI32::new(-1);
/// Read end of the self-pipe, consumed by the rescue thread.
static SIGNAL_READ_FD: AtomicI32 = AtomicI32::new(-1);
/// The manager whose sessions a stop signal should rescue, once startup has one. See
/// [`arm_rescue`].
static ARMED_MANAGER: Mutex<Option<Arc<SessionManager>>> = Mutex::new(None);
/// When an operator-requested stop stops suppressing the rescue. `None` until one is
/// requested. Never read from the signal handler, so an ordinary mutex is fine.
static RESCUE_DISABLED_UNTIL: Mutex<Option<Instant>> = Mutex::new(None);

/// Make a terminating signal in the next `RESCUE_DISABLE_WINDOW` a plain exit
/// rather than a rescue.
///
/// Called from the `DisableShutdownRescue` IPC request, which `triaged service stop`
/// and `service uninstall` send before they touch `launchctl`/`systemctl`. Those mean
/// "stop the daemon", and `uninstall` in particular must leave nothing running, so
/// quietly starting a detached replacement would be wrong.
pub fn disable_rescue() {
    *RESCUE_DISABLED_UNTIL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) =
        Some(Instant::now() + RESCUE_DISABLE_WINDOW);
}

/// Whether a rescue is currently suppressed.
fn rescue_disabled() -> bool {
    let disabled_until = *RESCUE_DISABLED_UNTIL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    disabled_until.is_some_and(|until| Instant::now() < until)
        || std::env::var_os(NO_RESCUE_ENV).is_some_and(|value| !value.is_empty())
}

/// What a rescue attempt concluded. Success is not representable: a handover that
/// completes exits this process from the IPC handler thread, so the rescue only
/// ever *returns* when it did not happen or did not work.
enum RescueOutcome {
    /// There was nothing to rescue, or an operator asked for a plain stop. Exit
    /// normally.
    Skipped,
    /// Another stop signal arrived mid-attempt. Exit without trying again.
    Insisted,
    /// The rescue was attempted and did not carry the sessions across. Keep
    /// serving them.
    Failed,
}

/// Install the terminating-signal handlers.
///
/// Call this as early as possible: before the long startup work, and before any
/// thread that could receive one of these signals exists. The handler does nothing
/// but write a byte to a pipe, so a signal that arrives before
/// [`spawn_rescue_thread`] has started is not lost: it waits in the pipe and is
/// serviced once the thread comes up. Installing early rather than alongside that
/// thread is what makes a signal arriving in between survivable at all.
///
/// A self-pipe rather than a dedicated `sigwait` thread, and the reason is the
/// session children: `sigwait` requires the signal to be *blocked* in every
/// thread, a blocked mask is inherited across `fork` and `exec`, and every shell
/// this daemon spawns would then start with SIGTERM blocked and be unkillable. A
/// handled disposition resets to the default on `exec`, so children are unaffected.
///
/// Failure is not fatal and not reported: this runs before logging is initialised,
/// and a daemon that cannot install a handler is exactly as good as every daemon
/// before this module existed.
pub fn install_signal_handlers() {
    let mut fds = [-1 as libc::c_int; 2];
    // SAFETY: `pipe` writes exactly two descriptors into the provided array.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return;
    }
    // Close-on-exec on both ends: every session child, and the successor spawned
    // by a rescue, would otherwise inherit them. An inherited write end is the
    // worse half, since it keeps the pipe writable for the child's lifetime and
    // hands an unrelated process a way to fake a shutdown signal to this daemon.
    for fd in fds {
        crate::handover::set_cloexec(fd);
    }
    // Non-blocking write end, which is the standard self-pipe requirement: the
    // handler must never block. A rescue occupies the reader for up to
    // SHUTDOWN_RESCUE_TIMEOUT, so a caller sending signals in a loop could fill the
    // pipe, and a blocking `write` would then park the handler inside whatever
    // thread it interrupted, holding whatever locks that thread held. Losing a
    // signal to a full pipe is harmless by comparison: a full pipe means one is
    // already queued and about to be answered.
    unsafe {
        let flags = libc::fcntl(fds[1], libc::F_GETFL);
        if flags >= 0 {
            libc::fcntl(fds[1], libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
    }
    SIGNAL_READ_FD.store(fds[0], Ordering::SeqCst);
    SIGNAL_WRITE_FD.store(fds[1], Ordering::SeqCst);

    for signum in TERMINATING_SIGNALS {
        install_handler(signum);
    }
}

/// Point `signum` at [`on_terminating_signal`], with `SA_RESTART` so the pipe read
/// and every other blocking call in the process is resumed rather than failing
/// with `EINTR`.
fn install_handler(signum: libc::c_int) {
    // SAFETY: `action` is fully initialised below before use, and `sigaction` only
    // reads it. A failure leaves the default disposition, which is the behaviour
    // this daemon had before.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_terminating_signal as *const () as libc::sighandler_t;
        action.sa_flags = libc::SA_RESTART;
        libc::sigemptyset(&mut action.sa_mask);
        libc::sigaction(signum, &action, std::ptr::null_mut());
    }
}

/// The signal handler. Writes the signal number to the self-pipe and returns.
///
/// Everything the rescue actually does (allocating, locking, spawning a process) is
/// forbidden here, so this does the one async-signal-safe thing that lets a normal
/// thread do the work: a single `write`.
///
/// `errno` is saved and restored around it. A handler runs on whatever thread the
/// signal interrupted, and that thread may be between a failed syscall and its
/// `Error::last_os_error()`; clobbering `errno` there turns an unrelated error into
/// the wrong one. POSIX requires this of any handler that can modify `errno`.
extern "C" fn on_terminating_signal(signum: libc::c_int) {
    // SAFETY: reading and restoring the calling thread's own `errno` through the
    // pointer libc hands out for exactly that, and a single one-byte `write` from a
    // local. All are async-signal-safe. `fd` is the pipe's write end, which is never
    // closed, and the write is non-blocking. A short or failed write only costs this
    // one signal a rescue.
    unsafe {
        let errno = errno_location();
        let saved = if errno.is_null() { 0 } else { *errno };
        let fd = SIGNAL_WRITE_FD.load(Ordering::Acquire);
        if fd >= 0 {
            let byte = signum as u8;
            libc::write(fd, std::ptr::addr_of!(byte).cast(), 1);
        }
        if !errno.is_null() {
            *errno = saved;
        }
    }
}

/// Address of the calling thread's `errno`, which every libc spells differently.
///
/// A null return means this target's spelling is unknown here, and the handler then
/// skips the save/restore rather than guessing.
///
/// # Safety
///
/// The returned pointer is valid only for the calling thread.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
unsafe fn errno_location() -> *mut libc::c_int {
    unsafe { libc::__error() }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
unsafe fn errno_location() -> *mut libc::c_int {
    unsafe { libc::__errno_location() }
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "linux",
    target_os = "android"
)))]
unsafe fn errno_location() -> *mut libc::c_int {
    std::ptr::null_mut()
}

/// Start the thread that answers terminating signals.
///
/// Call as soon as logging is up, *before* the long startup work. Until
/// [`arm_rescue`] publishes a manager there is nothing to rescue, and a signal
/// arriving in that window makes this thread exit the process, which is exactly what
/// the default disposition would have done. That is the point: without a consumer,
/// caught-and-queued signals would make the daemon unstoppable for the whole of
/// startup, and a `service stop` racing a start could not even land its
/// `DisableShutdownRescue` (the IPC socket is not bound yet).
pub fn spawn_rescue_thread() {
    let read_fd = SIGNAL_READ_FD.load(Ordering::SeqCst);
    if read_fd < 0 {
        tracing::warn!(
            "no shutdown-signal pipe; a terminating signal will kill this daemon and every \
             live session with it"
        );
        return;
    }

    if let Err(error) = std::thread::Builder::new()
        .name("triage-shutdown-rescue".into())
        .spawn(move || run_rescue_loop(read_fd))
    {
        // Nothing will read the pipe, so the handlers must go: a caught signal with
        // no consumer is *worse* than no handler, because it is silently discarded
        // and leaves the daemon killable only by SIGKILL.
        restore_default_handlers();
        tracing::warn!(
            %error,
            "could not spawn the shutdown-rescue thread; terminating signals are back to their \
             default behaviour, so one will kill this daemon and every live session with it"
        );
    }
}

/// Put the terminating signals back to their default disposition.
///
/// For the paths that give up on ever answering them. Leaving a handler installed with
/// nothing consuming the pipe is the worst of both worlds: the signal is caught, so it
/// does not terminate the process, and then discarded, so nothing acts on it. The
/// daemon would be stoppable only by SIGKILL, which is precisely the death that costs
/// every session.
fn restore_default_handlers() {
    // SAFETY: `signal` with SIG_DFL installs no handler, so there is no
    // async-signal-safety obligation; the only effect is on this process's disposition
    // table.
    unsafe {
        for signum in TERMINATING_SIGNALS {
            libc::signal(signum, libc::SIG_DFL);
        }
    }
}

/// Publish the manager whose sessions a terminating signal should rescue.
///
/// Call as soon as a manager exists, which is deliberately *before* handover adoption
/// and session restore: from the moment adoption commits, this process is the sole
/// owner of every adopted master, and an unarmed stop signal there would close all of
/// them. Arming earlier costs nothing, because a manager holding only restored
/// `Historical` entries reports no live sessions and a signal is skipped. Before this
/// is called at all, a stop signal is a plain exit.
pub fn arm_rescue(manager: Arc<SessionManager>) {
    *ARMED_MANAGER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(manager);
}

/// Wait for terminating signals and answer each one.
///
/// A successful rescue never comes back here: the handover it starts ends in
/// `process::exit(0)` on the IPC handler thread. So reaching the bottom of an
/// iteration means the rescue was skipped (exit cleanly) or failed (keep serving,
/// and let a second signal be the operator's override).
fn run_rescue_loop(read_fd: RawFd) -> ! {
    // Two independent facts about the signal being handled, which together decide
    // whether it means "try" or "stop trying":
    //
    // - `last_failure`: whether a rescue has recently failed at all. Its recency is
    //   also what ends a chain of attempts, so a stop request long after the dust
    //   settled starts fresh instead of inheriting an old failure's verdict.
    // - `chain_started`: when the *first* signal of the current chain arrived, which is
    //   what a burst is measured against. Deliberately not reset per attempt: an
    //   attempt can fail in milliseconds (a spawn error returns at once), and
    //   restarting the grace on each one would mean a caller signalling faster than
    //   SIGNAL_COALESCE_GRACE could never register as insisting, leaving the daemon
    //   forking a successor per signal and never exiting.
    let mut last_failure: Option<Instant> = None;
    let mut chain_started: Option<Instant> = None;
    loop {
        let Some(signum) = read_one_signal(read_fd) else {
            // The pipe is unusable, so no further signal can ever be observed.
            // Park instead of spinning; the daemon keeps serving and a SIGKILL is
            // the only way out, exactly as it was before this module existed.
            restore_default_handlers();
            tracing::error!(
                "shutdown-signal pipe is unreadable; terminating signals are back to their \
                 default behaviour, so the next one will kill this daemon"
            );
            loop {
                std::thread::park();
            }
        };

        // Drain whatever arrived with it: one teardown event routinely delivers more
        // than one signal. See `SIGNAL_COALESCE_GRACE`, which covers the rest of a
        // burst that is not quite this tightly spaced.
        let co_arrived = drain_queued_signals(read_fd);

        // No recent failure means this signal opens a new chain of attempts, whether
        // it is the first ever or the first since an unrelated stop request long ago.
        // Keyed to the failure rather than to the previous signal, because a rescue
        // that spends its whole budget takes longer than INSIST_WINDOW on its own: the
        // signal that follows it is an override, not a new request.
        let starts_new_chain =
            last_failure.is_none_or(|failed_at| failed_at.elapsed() >= INSIST_WINDOW);
        if starts_new_chain {
            chain_started = Some(Instant::now());
        }

        // Insisting means: a rescue in this chain has already failed, and this signal is
        // late enough not to be the rest of the burst that started the chain.
        let insisting = !starts_new_chain
            && chain_started.is_some_and(|at| at.elapsed() >= SIGNAL_COALESCE_GRACE);
        if insisting {
            tracing::warn!(
                signum,
                "another stop signal after a failed session rescue; exiting now as asked. Live \
                 sessions will be lost."
            );
            exit_now(1);
        }

        tracing::warn!(
            signum,
            co_arrived,
            "received a stop signal; attempting to rescue live sessions"
        );
        let manager = loop {
            let adoption_in_progress = crate::handover::adoption_in_progress();
            match armed_manager() {
                Some(manager) if !adoption_in_progress || manager.has_unresolved_adoptions() => {
                    break manager;
                }
                Some(_) | None if adoption_in_progress => {
                    // The handover globals own the descriptors, but main has not
                    // yet published them into the manager's transferable queue.
                    // This is a short startup window; exiting or rescuing now
                    // would both omit the only PTY copies.
                    if another_signal_queued(read_fd) {
                        if chain_started
                            .is_some_and(|started| started.elapsed() < SIGNAL_COALESCE_GRACE)
                        {
                            let drained = drain_queued_signals(read_fd);
                            tracing::info!(
                                drained,
                                "more signals arrived while transferred PTYs were being published; treating them as the same teardown event"
                            );
                        } else {
                            drain_queued_signals(read_fd);
                            tracing::warn!(
                                "another stop signal arrived before transferred PTYs became transferable; exiting now as asked"
                            );
                            exit_now(1);
                        }
                    }
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                Some(manager) => break manager,
                None => {
                    // Nothing owns sessions yet, so there is nothing to hand over
                    // and no reason to stay.
                    tracing::warn!(
                        signum,
                        "stop signal arrived before startup finished; exiting without a rescue"
                    );
                    exit_now(0);
                }
            }
        };
        if crate::handover::adoption_in_progress() {
            tracing::warn!(
                signum,
                "transferred session descriptors still await adoption; rescue will hand off both live and retained PTYs"
            );
        };
        match rescue(&manager, read_fd, signum) {
            RescueOutcome::Skipped => exit_now(0),
            RescueOutcome::Insisted => {
                tracing::warn!("exiting on the operator's second stop signal");
                exit_now(1);
            }
            RescueOutcome::Failed => {
                last_failure = Some(Instant::now());
                tracing::error!(
                    "could not hand the live sessions to a successor, so this daemon is staying \
                     up rather than closing their PTYs. Send another stop signal to exit anyway."
                );
            }
        }
    }
}

/// The manager published by [`arm_rescue`], if startup has got that far.
fn armed_manager() -> Option<Arc<SessionManager>> {
    ARMED_MANAGER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

/// Exit the process from the rescue thread, tidily.
///
/// Two things `std::process::exit` alone would skip:
///
/// - **Unlink our socket**, as the handover exit in [`crate::ipc`] also does. This is
///   an orderly exit with the socket still bound, and a file left behind widens the
///   window where two concurrent starters both remove it and both bind.
///   Identity-checked, so it can never delete a successor's.
/// - **Let the log catch up**, which the handover exit does *not* do, because it is
///   not the path whose whole output is one explanatory line. `exit` never runs
///   `main`'s `WorkerGuard` drop, the only thing that flushes the non-blocking tracing
///   appender, so the message explaining this exit is the one most likely to be lost.
///   The appender drains continuously, so a short pause is enough in practice; there
///   is no way to force a flush from here, since the guard belongs to `main`.
fn exit_now(code: i32) -> ! {
    crate::ipc::unlink_own_default_socket();
    std::thread::sleep(LOG_FLUSH_GRACE);
    std::process::exit(code)
}

/// Whether another terminating signal is already queued, without blocking.
///
/// Polled while a rescue waits, so "send another stop signal to exit anyway" is
/// true *during* the attempt and not only after it. Without this the loop would not
/// look at the pipe again until the rescue returned, up to the full budget later,
/// and an operator watching a stop take 90 seconds would have no way to insist.
fn another_signal_queued(read_fd: RawFd) -> bool {
    signal_queued_with_timeout(read_fd, Duration::ZERO)
}

/// Whether a terminating signal becomes readable within `timeout`.
fn signal_queued_with_timeout(read_fd: RawFd, timeout: Duration) -> bool {
    let mut poll_fd = libc::pollfd {
        fd: read_fd,
        events: libc::POLLIN,
        revents: 0,
    };
    let timeout_ms = timeout.as_millis().min(libc::c_int::MAX as u128) as libc::c_int;
    // SAFETY: one `pollfd` describing a descriptor this process owns. The timeout
    // is bounded to the range accepted by `poll`.
    let ready = unsafe { libc::poll(&mut poll_fd, 1, timeout_ms) };
    ready > 0 && poll_fd.revents & libc::POLLIN != 0
}

/// Discard every signal byte already queued, returning how many there were.
///
/// Called immediately after reading one, to collapse a burst that belongs to a single
/// teardown event into that one signal. Anything arriving *after* this is a distinct
/// act, which is what makes "another stop signal" mean an operator insisting.
fn drain_queued_signals(read_fd: RawFd) -> usize {
    let mut drained = 0;
    while another_signal_queued(read_fd) {
        let mut byte = 0u8;
        // SAFETY: reads at most one byte into `byte`'s address, and `poll` has just
        // reported the descriptor readable, so this cannot block.
        if unsafe { libc::read(read_fd, std::ptr::addr_of_mut!(byte).cast(), 1) } != 1 {
            break;
        }
        drained += 1;
    }
    drained
}

/// Block until a signal byte arrives, returning the signal number.
///
/// `None` means the pipe can no longer be read, which is unrecoverable: this
/// process holds the write end for its whole life, so EOF is not a normal outcome.
fn read_one_signal(read_fd: RawFd) -> Option<libc::c_int> {
    loop {
        let mut byte = 0u8;
        // SAFETY: reads at most one byte into `byte`'s address; `read_fd` is the
        // pipe's read end, owned by this process for its lifetime.
        let read = unsafe { libc::read(read_fd, std::ptr::addr_of_mut!(byte).cast(), 1) };
        match read {
            1 => return Some(libc::c_int::from(byte)),
            // EOF cannot happen while we hold the write end; treat it as fatal to
            // the pipe rather than spinning on a descriptor that will never block.
            0 => return None,
            _ => {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return None;
            }
        }
    }
}

/// Try to move this daemon's live sessions into a fresh successor.
fn rescue(manager: &SessionManager, read_fd: RawFd, signum: libc::c_int) -> RescueOutcome {
    if rescue_disabled() {
        tracing::info!(
            signum,
            "session rescue is disabled (operator-requested stop or {NO_RESCUE_ENV}); exiting \
             without handing sessions over"
        );
        return RescueOutcome::Skipped;
    }

    // Deliberately a non-blocking read: the rescue must not be the one thing that
    // waits on the sessions mutex, because a daemon wedged on that mutex is
    // precisely when a stop signal arrives. "Unknown" is treated as "there may be
    // sessions", since attempting a rescue that turns out to be unnecessary costs
    // one process spawn, while skipping one that was necessary costs the sessions.
    match manager.try_live_session_count() {
        Some(0) => {
            tracing::info!("no live sessions to rescue; exiting cleanly");
            return RescueOutcome::Skipped;
        }
        Some(live) => tracing::info!(live, "handing live sessions to a detached successor"),
        None => tracing::warn!(
            "could not read the session table without blocking; attempting the rescue anyway"
        ),
    }

    let deadline = Instant::now() + SHUTDOWN_RESCUE_TIMEOUT;
    // Anchored once, here, rather than at the start of each wait. A burst belongs to the
    // signal that triggered *this rescue*, so re-arming the window per wait (or per
    // retry) would keep discarding an operator's override: it is drained inside the
    // wait, so `run_rescue_loop` never sees it and never gets to call it insistence.
    let coalesce_until = Instant::now() + SIGNAL_COALESCE_GRACE;

    // A handover already in flight is the successor this rescue would otherwise
    // start, and `begin_handover` would refuse a second one anyway, so wait for the
    // running swap. If it *finishes* without exiting this process it aborted and
    // kept the sessions, and then a successor of our own is exactly what is needed:
    // fall through rather than sit out the rest of the budget.
    if manager.handover_in_flight() {
        tracing::info!(
            "a handover is already in flight; waiting for it instead of starting a second \
             successor"
        );
        if wait_for_handover(manager, read_fd, deadline, coalesce_until, None, || {
            !manager.handover_in_flight()
        }) == WaitOutcome::Insisted
        {
            return RescueOutcome::Insisted;
        }
    }

    for attempt in 1..=MAX_SUCCESSOR_ATTEMPTS {
        // Checked before every attempt, not only between them: the in-flight wait
        // above can consume the whole budget on its own (an IPC thread blocked inside
        // `serialize_active_sessions` holds the handover slot indefinitely), and
        // spawning into what is left would only produce a detached daemon this
        // function immediately kills.
        if deadline.saturating_duration_since(Instant::now()) < MIN_ATTEMPT_BUDGET {
            tracing::error!("too little of the rescue budget left to start a successor");
            break;
        }

        // A successor can only take the sessions by handing over from us, and that
        // means connecting to our IPC socket. It is bound late in startup (inside
        // `IpcServer::serve`), so a signal answered before then would otherwise burn
        // an attempt on a successor that finds nothing to hand over from, falls back
        // to a fresh start, and dies on the TCP port this process still holds.
        if wait_for_own_ipc_socket(read_fd, deadline, coalesce_until) == WaitOutcome::Insisted {
            return RescueOutcome::Insisted;
        }

        // Re-checked after that wait, which can consume the floor on its own: it is
        // bounded by OWN_SOCKET_WAIT, and spawning with what is left would produce a
        // successor `wait_for_handover` kills before its first poll.
        if deadline.saturating_duration_since(Instant::now()) < MIN_ATTEMPT_BUDGET {
            tracing::error!(
                "too little of the rescue budget left after waiting for the control socket"
            );
            break;
        }

        let child = match spawn_detached_successor() {
            Ok(child) => child,
            Err(error) => {
                tracing::error!(%error, "could not start a successor to take the live sessions");
                return RescueOutcome::Failed;
            }
        };
        tracing::info!(
            attempt,
            successor_pid = child.id(),
            budget_secs = SHUTDOWN_RESCUE_TIMEOUT.as_secs(),
            "started a detached successor; it will adopt the sessions and this process will exit \
             when the handover completes"
        );
        if wait_for_handover(
            manager,
            read_fd,
            deadline,
            coalesce_until,
            Some(child),
            || false,
        ) == WaitOutcome::Insisted
        {
            return RescueOutcome::Insisted;
        }

        if attempt < MAX_SUCCESSOR_ATTEMPTS {
            tracing::warn!(
                "the successor did not take the sessions; trying once more with a fresh one"
            );
        }
    }
    RescueOutcome::Failed
}

/// Wait until *this* daemon has bound its own IPC socket, so a successor has
/// something to hand over from.
///
/// Asks `ipc` whether we bound it rather than connecting to the path: during a swap
/// the path can be answered by a predecessor that has already detached its sessions,
/// and a successor started on the strength of that would hand over from a daemon with
/// nothing left to give, burning an attempt.
///
/// Bounded by the rescue budget and best-effort: if it never comes up the caller still
/// tries, because a successor that fails is no worse than no successor at all. Returns
/// `Insisted` if another stop signal arrives first, since this wait is long enough that
/// ignoring one would break the promise `another_signal_queued` exists to keep.
fn wait_for_own_ipc_socket(
    read_fd: RawFd,
    deadline: Instant,
    coalesce_until: Instant,
) -> WaitOutcome {
    let socket_deadline = Instant::now() + OWN_SOCKET_WAIT;
    let mut warned = false;
    while Instant::now() < socket_deadline.min(deadline) {
        if crate::ipc::own_socket_is_bound() {
            return WaitOutcome::NotTaken;
        }
        // This wait can run for OWN_SOCKET_WAIT, which is far too long to leave an
        // operator's second signal unanswered; `another_signal_queued` exists for
        // exactly that promise. Subject to the same burst window as every other read of
        // the pipe, and for a sharper reason here: this wait is reachable while the
        // daemon holds masters freshly adopted from a predecessor, so misreading a
        // logout's SIGHUP-then-SIGTERM as insistence would close every one of them.
        if another_signal_queued(read_fd) {
            if Instant::now() < coalesce_until {
                let drained = drain_queued_signals(read_fd);
                tracing::info!(drained, "more signals arrived with the one being answered");
            } else {
                tracing::warn!("another stop signal arrived while waiting for the control socket");
                return WaitOutcome::Insisted;
            }
        }
        if !warned {
            warned = true;
            tracing::info!(
                "waiting for this daemon's own control socket before starting a successor; the \
                 stop signal arrived before startup finished binding it"
            );
        }
        std::thread::sleep(RESCUE_POLL_INTERVAL);
    }
    WaitOutcome::NotTaken
}

/// Why a wait for a handover ended.
///
/// Success is absent for the usual reason: a completed handover exits this process
/// from the IPC handler thread, so returning at all means it did not complete. The
/// distinction that matters is `Insisted`, because the caller must not answer an
/// operator's second stop signal by spawning yet another successor.
#[derive(PartialEq, Eq)]
enum WaitOutcome {
    /// Another stop signal arrived. Stop trying and exit.
    Insisted,
    /// The swap ended, or the budget did, without taking the sessions.
    NotTaken,
}

/// Wait for a handover to carry this process to `process::exit(0)`.
///
/// Ends on whichever comes first of the successor exiting, `give_up` reporting that
/// there is no longer a swap to wait for, another stop signal arriving, or the budget
/// expiring.
///
/// `child` is `None` when the handover was already in flight and this rescue did not
/// start the process serving it, so there is no process of ours to watch or clean up.
/// `coalesce_until` is the rescue's own burst window, passed in rather than computed
/// here so a retry cannot re-arm it and swallow an override.
fn wait_for_handover(
    manager: &SessionManager,
    read_fd: RawFd,
    deadline: Instant,
    coalesce_until: Instant,
    mut child: Option<std::process::Child>,
    give_up: impl Fn() -> bool,
) -> WaitOutcome {
    let mut outcome = WaitOutcome::NotTaken;
    while Instant::now() < deadline {
        std::thread::sleep(RESCUE_POLL_INTERVAL);

        // An operator insisting must not have to wait out the budget; the loop is
        // the only thing standing between the queued signal and `run_rescue_loop`
        // acting on it.
        //
        // Except in the first moments, where a second signal is far more likely to
        // be the rest of one teardown event than a person asking twice. See
        // `SIGNAL_COALESCE_GRACE`.
        if another_signal_queued(read_fd) {
            if Instant::now() < coalesce_until {
                let drained = drain_queued_signals(read_fd);
                tracing::info!(
                    drained,
                    "more signals arrived with the one that started this rescue; treating them \
                     as the same teardown event"
                );
                continue;
            }
            tracing::warn!("another stop signal arrived while waiting for the handover");
            outcome = WaitOutcome::Insisted;
            break;
        }

        // A successor that exits while we are still running has given up: a
        // successful handover exits *this* process first, from the IPC handler
        // thread, so reaching here means the swap did not happen. Stop waiting out
        // the full budget for a process that is already gone.
        if let Some(successor) = child.as_mut() {
            match successor.try_wait() {
                Ok(Some(status)) => {
                    tracing::error!(
                        %status,
                        "the successor exited without taking the sessions; it either refused the \
                         handover or failed to start"
                    );
                    return WaitOutcome::NotTaken;
                }
                Ok(None) => {}
                Err(error) => {
                    // Can't tell whether it is alive; keep waiting out the budget
                    // rather than abandoning a swap that may still be running. Also
                    // gives up the right to reap it, so stop holding the handle.
                    tracing::warn!(%error, "could not check on the successor process");
                    child = None;
                }
            }
        }

        if give_up() {
            tracing::warn!("the in-flight handover ended without taking the sessions");
            break;
        }
    }

    // A successor still running here has not carried this process to its exit, so it
    // owns nothing but stale copies of the descriptors. Leaving it alive would put a
    // second daemon on this socket and this port, and never reaping it would leave a
    // zombie in a process with no reason to call `wait` again.
    //
    // Except while a handover is still in flight. Between the outgoing daemon's
    // commit byte and its exit, the sessions have already been detached and that
    // successor is their only owner, so killing it there closes every master and
    // SIGHUPs every child: the exact loss this module exists to prevent, inflicted by
    // its own cleanup. The window is short but reachable from both the deadline and a
    // second signal, so it is checked rather than reasoned away.
    if let Some(mut successor) = child {
        let pid = successor.id();
        if manager.handover_in_flight() {
            // Left unreaped on purpose: it is alive and wanted alive, so there is
            // nothing to `wait` for. If it later exits it becomes a zombie for the rest
            // of this daemon's life, which is one process-table entry per rescue that
            // ended this way, and a trade worth making against killing a successor that
            // may already own every session.
            tracing::warn!(
                successor_pid = pid,
                "leaving the successor alone: a handover is still in flight, and it may already \
                 own the sessions"
            );
        } else {
            match successor.kill().and_then(|()| successor.wait()) {
                Ok(_) => tracing::warn!(
                    successor_pid = pid,
                    "stopped the successor that did not complete the handover"
                ),
                Err(error) => tracing::warn!(
                    %error,
                    successor_pid = pid,
                    "could not stop the successor that did not complete the handover"
                ),
            }
        }
    }

    if Instant::now() >= deadline {
        tracing::error!(
            budget_secs = SHUTDOWN_RESCUE_TIMEOUT.as_secs(),
            "the handover did not complete within the rescue budget"
        );
    }
    outcome
}

/// Start `triaged --handover` in its own session, with no inherited stdio.
///
/// `setsid` is the load-bearing part. The successor exists to outlive whatever is
/// terminating this process, and a child that keeps this process group and
/// controlling terminal is reached by the same group signal, supervisor teardown,
/// or hangup that started the rescue. A new session also means no controlling
/// terminal at all, so nothing can job-control-stop it mid-swap, the failure that
/// wedged three daemons on 2026-08-13.
///
/// Its stdio is `/dev/null` rather than inherited for the same reason: a successor
/// holding this daemon's terminal would reacquire exactly the relationship `setsid`
/// just removed.
fn spawn_detached_successor() -> Result<std::process::Child> {
    use std::process::{Command, Stdio};

    let exe = std::env::current_exe().context("resolving the triaged executable to re-exec")?;
    let mut command = Command::new(&exe);
    command
        .arg("--handover")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    crate::session::detach_from_terminal(&mut command);
    command
        .spawn()
        .with_context(|| format!("spawning a successor daemon from {}", exe.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `disable_rescue` is what `service stop` / `uninstall` reach through IPC, so its
    /// effect has to be observable through the same predicate the signal path
    /// consults.
    ///
    /// The window is asserted from the *other* side too, because a latch here would be
    /// a trap: `service stop` disables the rescue before asking the supervisor to stop
    /// the job, so a stop that then fails must not leave the daemon permanently unable
    /// to save its sessions.
    ///
    /// Restores the static rather than leaving it set: this is process-global state in
    /// a test binary that shares one process.
    #[test]
    fn disable_rescue_suppresses_the_rescue_for_a_bounded_window() {
        disable_rescue();
        assert!(
            rescue_disabled(),
            "an operator-requested stop must suppress"
        );

        let expiry = *RESCUE_DISABLED_UNTIL
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let expiry = expiry.expect("a stop request records an expiry");
        assert!(
            expiry.saturating_duration_since(Instant::now()) <= RESCUE_DISABLE_WINDOW,
            "the suppression must expire rather than latch"
        );

        // Pretend the window has passed: the daemon must re-arm itself.
        *RESCUE_DISABLED_UNTIL
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Instant::now());
        assert!(
            !rescue_disabled(),
            "once the window passes the rescue must be armed again, or a failed `service stop` \
             would silently disarm it forever"
        );

        *RESCUE_DISABLED_UNTIL
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    }

    /// A signal burst belonging to one teardown event must not read as an operator
    /// insisting: a logout delivers SIGHUP and SIGTERM within microseconds, and
    /// counting the second as insistence would turn the commonest rescue-worthy event
    /// into an immediate exit that closes every master.
    ///
    /// Wires up the pipe by hand rather than calling `install_signal_handlers`:
    /// installing real handlers in the test binary would leave `cargo test` itself
    /// unable to die on Ctrl-C, since nothing in a test process consumes the pipe.
    #[test]
    fn a_burst_of_signals_is_drained_as_one_event() {
        let mut fds = [-1 as libc::c_int; 2];
        assert_eq!(
            unsafe { libc::pipe(fds.as_mut_ptr()) },
            0,
            "open a self-pipe"
        );
        SIGNAL_WRITE_FD.store(fds[1], Ordering::SeqCst);
        let read_fd = fds[0];

        // Three signals arriving together, as a logout or a group signal delivers them.
        for signum in [libc::SIGHUP, libc::SIGTERM, libc::SIGTERM] {
            on_terminating_signal(signum);
        }

        let first = read_one_signal(read_fd).expect("the first signal is readable");
        assert_eq!(first, libc::SIGHUP);
        assert_eq!(
            drain_queued_signals(read_fd),
            2,
            "the rest of the burst must be drained with it"
        );
        assert!(
            !another_signal_queued(read_fd),
            "nothing should be left to mistake for a later, deliberate stop"
        );

        // A genuinely later signal is still seen.
        on_terminating_signal(libc::SIGTERM);
        assert!(another_signal_queued(read_fd));
        assert_eq!(drain_queued_signals(read_fd), 1);

        SIGNAL_WRITE_FD.store(-1, Ordering::SeqCst);
        for fd in fds {
            unsafe { libc::close(fd) };
        }
    }
}
