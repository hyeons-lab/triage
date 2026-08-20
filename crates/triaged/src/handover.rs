use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use triage_core::session::{SessionId, SessionSize};

/// Non-reusable identity of a child process carried with its PTY master.
///
/// The PID alone is not enough after a stalled handover because the kernel can
/// reuse it before recovery adopts the retained descriptor.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct HandoverProcessIdentity {
    pub pid: u32,
    pub started_at: [u64; 2],
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandoverSession {
    pub id: SessionId,
    pub command: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub size: SessionSize,
    pub log_path: PathBuf,
    pub output_seq: u64,
    pub bytes_logged: u64,
    pub pid: u32,
    /// Process birth identity used to reject PID reuse during delayed recovery.
    #[serde(default)]
    pub process_identity: Option<HandoverProcessIdentity>,
    /// Wall-clock of the session's most recent output, as milliseconds since the
    /// Unix epoch. Carried across the swap so the incoming daemon restores each
    /// session's real recency; without it every adopted session would look like
    /// it had just been active, collapsing the rail's activity ordering into a
    /// single tie at the handover instant. Defaults to 0 ("unknown") for a state
    /// blob written before this field existed.
    #[serde(default)]
    pub last_activity_ms: u64,
    #[serde(default)]
    pub judge_override: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandoverState {
    pub sessions: Vec<HandoverSession>,
    pub has_tcp_listener: bool,
    /// Whether the outgoing daemon sends a `0x03` teardown-commit byte (Phase 3)
    /// *before* detaching its sessions. When true, the successor can tell a real
    /// teardown from an abort: a pre-commit EOF means the daemon kept its
    /// sessions, so adopting would create a second destructive reader on each
    /// master. Defaults to false so a state serialized by an older daemon — which
    /// never sends the byte — is read as "cannot disambiguate", preserving the
    /// legacy adopt-on-EOF behavior for it. See [`teardown_outcome`].
    #[serde(default)]
    pub sends_teardown_commit: bool,
    /// Random identity of the daemon that transferred this state. The successor
    /// uses it to ask a later IPC connection whether it reached that same daemon,
    /// rather than a launchd respawn at the same socket path.
    #[serde(default)]
    pub handover_owner_token: Option<[u8; 16]>,
    /// Stable identity carried by every daemon that successively owns this set
    /// of sessions. Unlike `handover_owner_token`, it survives a clean swap, so a
    /// stalled successor can recognize a newer authoritative snapshot.
    #[serde(default)]
    pub handover_lineage_token: Option<[u8; 16]>,
}

/// Result of asking a running daemon to hand over (Phase 1, before the successor
/// commits to anything).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandoverClientOutcome {
    /// State and descriptors were received; the successor now holds them and must
    /// complete the Phase-2/3 sync.
    Transferred,
    /// The daemon is already serving another handover and refused this one. The
    /// caller should retry shortly rather than fall back to a fresh start.
    Busy,
}

/// Whether the successor should adopt the transferred sessions or refuse them,
/// decided after it has sent its `0x01` adoption byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TeardownOutcome {
    /// The outgoing daemon committed to (or completed) teardown; its sessions are
    /// the successor's to own.
    Adopt,
    /// The outgoing daemon aborted before committing and still owns its sessions.
    /// Adopting would put a second destructive reader on each PTY master, so the
    /// successor must not adopt; the outgoing daemon keeps serving and a later
    /// attempt can hand over cleanly.
    Refuse,
}

/// What the successor observed while waiting for the outgoing daemon's Phase-3
/// teardown byte. `Eof` and `Timeout` are kept apart deliberately: they look the
/// same on the byte stream but mean opposite things about the peer, and
/// collapsing them costs sessions either way (see [`teardown_outcome`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TeardownSignal {
    /// A byte arrived.
    Byte(u8),
    /// The peer closed the socket without sending a teardown byte, or the read
    /// failed outright (a reset counts as a close).
    ///
    /// `peer_alive` records whether the daemon that supplied the descriptors was
    /// still serving its active handover on its IPC socket afterwards. A replacement
    /// daemon that rebound the same path does not count as alive. This separates the two very
    /// different causes of this: a daemon that *aborted* its handover closes this
    /// connection and keeps serving, while one that was killed mid-handover
    /// closes it by dying. They demand opposite responses: see
    /// [`teardown_outcome`].
    Eof { peer_alive: bool },
    /// [`HANDOVER_TEARDOWN_TIMEOUT`] expired with the socket still open, so the
    /// peer is alive and may yet commit.
    Timeout,
}

/// Decide adopt-vs-refuse from what the successor saw on the Phase-3 socket and
/// whether the outgoing daemon announced it commits before detaching.
///
/// - [`HANDOVER_COMMIT_BYTE`] — explicit teardown-commit: the daemon has (or is
///   about to) detach, so adopt.
/// - [`HANDOVER_DONE_BYTE`] — a daemon predating the commit byte reporting a
///   clean teardown; it detached before sending, so adopt.
/// - `Timeout` — a commit-capable peer has not resolved ownership yet, so retain
///   the descriptors without starting readers and recover through a new
///   handover. A legacy peer cannot make that ownership promise, so preserve its
///   historical adopt-on-timeout behavior.
/// - `Eof { peer_alive: false }` — the peer died mid-handover (killed, panicked).
///   Always adopt, whatever it announced: it is not coming back to finish, and
///   its descriptors died with it, so this process holds the only handles left.
///   Refusing here would close them and take down every session that was still
///   perfectly rescuable. This is reachable in normal operation — an operator
///   running `launchctl kickstart -k` on a swap that looks stuck kills the
///   outgoing daemon in exactly this window.
/// - `Eof { peer_alive: true }`, or an unexpected byte:
///   - if the peer announced the commit byte, its absence means the peer aborted
///     *before* committing and still owns the sessions → refuse. A committing
///     peer always writes the commit byte before it detaches, so a closed
///     connection from a *still-running* daemon is proof it never committed.
///   - if it did not (an older build), the byte stream cannot tell an abort from
///     a lost done-byte, and refusing would strand every session an old daemon
///     genuinely handed off, so adopt — the historical behavior.
///
/// This is the whole adopt/refuse contract, factored out as a pure function so
/// it can be unit-tested without the two-process socket dance around it.
pub fn teardown_outcome(peer_sends_commit: bool, signal: TeardownSignal) -> TeardownOutcome {
    match signal {
        TeardownSignal::Byte(HANDOVER_COMMIT_BYTE | HANDOVER_DONE_BYTE) => TeardownOutcome::Adopt,
        TeardownSignal::Timeout if peer_sends_commit => TeardownOutcome::Refuse,
        TeardownSignal::Timeout => TeardownOutcome::Adopt,
        // A dead peer owns nothing; only we can still save these sessions.
        TeardownSignal::Eof { peer_alive: false } => TeardownOutcome::Adopt,
        TeardownSignal::Byte(_) | TeardownSignal::Eof { .. } if peer_sends_commit => {
            TeardownOutcome::Refuse
        }
        TeardownSignal::Byte(_) | TeardownSignal::Eof { .. } => TeardownOutcome::Adopt,
    }
}

/// Successor → outgoing: "I have the state and descriptors; commit the handover."
/// The point of no return — before it the outgoing daemon can still bail and keep
/// serving, after it there is no rollback.
pub const HANDOVER_ADOPT_BYTE: u8 = 0x01;

/// Outgoing → successor: "I am committing to teardown." Sent *before* detaching,
/// and the detach happens only if this byte landed, so its absence on a closed
/// socket proves the peer never committed. See [`teardown_outcome`].
pub const HANDOVER_COMMIT_BYTE: u8 = 0x03;

/// Outgoing → successor: "teardown complete." The only teardown byte daemons
/// predating [`HANDOVER_COMMIT_BYTE`] send, so it is still accepted as an adopt
/// signal; a current peer sends it after detaching, where nothing reads it.
pub const HANDOVER_DONE_BYTE: u8 = 0x02;

/// Successor → outgoing: all descriptor chunks declared by the handover state
/// arrived. Lineage-capable daemons require this before accepting `0x01` when a
/// transfer exceeds the legacy single-message descriptor count.
pub const HANDOVER_FDS_READY_BYTE: u8 = 0x04;

/// Sentinel `WireResponse::Err` message a daemon returns when it refuses a
/// handover because it is already serving one. Distinguishes "busy, retry
/// shortly" from a dead or non-triaged peer, so the client can retry instead of
/// falling back to a fresh start that would fail to bind the still-held port.
pub const HANDOVER_BUSY_MESSAGE: &str = "handover already in flight";

/// How long the successor waits in Phase 1 for the outgoing daemon to ship
/// session state and PTY descriptors.
///
/// Bounded because smart-start adopts any *live* socket, so a hung daemon — or
/// a non-triaged process squatting on the socket path — must not block startup
/// forever. Nothing is committed yet at this point, so expiring here is cheap:
/// the caller just falls back to a fresh start.
pub const HANDOVER_TRANSFER_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Coordination budget used by starters waiting for another Phase 2 handover.
///
/// The outgoing daemon uses this Phase 2 read timeout so a successor that wedges
/// before committing does not hold the handover slot forever. On timeout it keeps
/// its actors and masters; a delayed successor resolves ownership through a fresh
/// handover before it starts any readers.
///
/// Measured successor startup was ~9s in June and ~22.6s by July, so the 5s
/// this replaced had no headroom and was aborting valid handovers.
pub const HANDOVER_ADOPTION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

// `detach_all_live_sessions` stays a plain code span in the doc below: this
// constant is not `#[cfg(unix)]` and that item is, so a link would dangle on a
// non-unix build, and Windows is a CI target.
/// How long the successor waits in Phase 3 for the outgoing daemon's `0x02`
/// teardown byte before switching to the retained-descriptor recovery path.
///
/// Separate from [`HANDOVER_ADOPTION_TIMEOUT`] because it bounds a different
/// wait — post-adoption teardown, not process startup. Expiry never starts PTY
/// readers for a commit-capable peer: the successor retains every descriptor
/// and performs another complete handover before adoption. Once 0x03 arrives it
/// waits through 0x02 or disconnect, because the old daemon's actual detach/exit,
/// not the commit byte alone, ends destructive reads.
pub const HANDOVER_TEARDOWN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// How long a daemon that has been asked to shut down waits for the successor it
/// spawned to take its sessions, before giving up and going back to serving them.
///
/// A terminating signal is the one loss vector handover cannot help with on its
/// own: this process owns every PTY master, so its death closes all of them and
/// SIGHUPs every child. `crate::shutdown` answers the signal by starting a
/// detached successor and letting the ordinary handover carry the sessions across, so
/// this budget has to cover a successor's whole cold start (log replay for every
/// historical session, measured at ~22.6s and growing) as well as the handshake.
///
/// So it must exceed all three protocol deadlines together,
/// [`HANDOVER_TRANSFER_TIMEOUT`] plus [`HANDOVER_ADOPTION_TIMEOUT`] plus
/// [`HANDOVER_TEARDOWN_TIMEOUT`], and does, with the balance as slack for the successor
/// to get as far as connecting at all. Note what is *not* a separate term: the cold
/// start. That startup work happens inside the adoption window rather than alongside
/// it, since it is what the successor is doing between Phase 1 and its adoption byte,
/// which is precisely the wait the adoption timeout bounds.
///
/// It must stay below the supervisor's stop grace period on systemd
/// (`TimeoutStopSec=150`). On macOS, launchd caps `ExitTimeOut` at 60s, so a
/// rescue that uses its full budget may outlive the owner's SIGKILL; adoption in
/// Phase 2 adopts rather than aborts when the owner dies, so the transferred
/// sessions survive.
pub const SHUTDOWN_RESCUE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(90);

const _: () = assert!(
    SHUTDOWN_RESCUE_TIMEOUT.as_secs()
        > HANDOVER_TRANSFER_TIMEOUT.as_secs()
            + HANDOVER_ADOPTION_TIMEOUT.as_secs()
            + HANDOVER_TEARDOWN_TIMEOUT.as_secs(),
    "the rescue budget must outlast the whole handshake it waits on, or it gives up on \
     swaps that were about to succeed"
);

#[cfg(unix)]
pub use unix_impl::*;

#[cfg(not(unix))]
pub use fallback_impl::*;

#[cfg(unix)]
mod unix_impl {
    use super::*;
    use anyhow::{Context, Result, bail};
    use libc::{CMSG_DATA, CMSG_FIRSTHDR, SCM_RIGHTS, SOL_SOCKET, iovec, msghdr, recvmsg, sendmsg};
    use portable_pty::{Child, ChildKiller, ExitStatus, MasterPty, PtySize};
    use std::io::{self, BufWriter, Read, Write};
    use std::net::TcpListener;
    use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd, RawFd};
    use std::os::unix::net::UnixStream;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    // Linux accepts at most 253 descriptors in one SCM_RIGHTS message. Allocate
    // the full portable ceiling rather than the former 129-descriptor guess;
    // MSG_CTRUNC still rejects any platform-specific overflow without adopting a
    // partial snapshot.
    pub(crate) const MAX_HANDOVER_FDS: usize = 253;
    pub(crate) const MAX_HANDOVER_STATE_BYTES: usize = 16 * 1024 * 1024;
    // Darwin rejects a single SCM_RIGHTS control message near Linux's ceiling.
    // Smaller send chunks remain portable while the receive buffer stays large
    // enough for predecessors that used Linux's 253-descriptor maximum.
    pub(crate) const MAX_FDS_PER_SEND: usize = 64;

    pub(crate) fn handover_process_identity(pid: u32) -> Option<HandoverProcessIdentity> {
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
            let (_, fields) = stat.rsplit_once(") ")?;
            let mut fields = fields.split_whitespace();
            if fields.next()? == "Z" {
                return None;
            }
            let start_time = fields.nth(18)?.parse().ok()?;
            Some(HandoverProcessIdentity {
                pid,
                started_at: [start_time, 0],
            })
        }

        #[cfg(target_os = "macos")]
        {
            let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
            let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
            // SAFETY: `info` points to `size` bytes of writable storage.
            let result = unsafe {
                libc::proc_pidinfo(
                    pid as libc::c_int,
                    libc::PROC_PIDTBSDINFO,
                    0,
                    info.as_mut_ptr().cast(),
                    size,
                )
            };
            if result != size {
                return None;
            }
            // SAFETY: proc_pidinfo returned the full structure size.
            let info = unsafe { info.assume_init() };
            if info.pbi_status == libc::SZOMB {
                return None;
            }
            Some(HandoverProcessIdentity {
                pid,
                started_at: [info.pbi_start_tvsec, info.pbi_start_tvusec],
            })
        }

        #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "android")))]
        {
            let _ = pid;
            None
        }
    }

    fn handover_process_identity_is_current(identity: HandoverProcessIdentity) -> bool {
        handover_process_identity(identity.pid) == Some(identity)
    }

    /// Duplicate `fd`, giving the copy `FD_CLOEXEC`.
    ///
    /// Always this instead of [`libc::dup`], which explicitly does *not* carry the
    /// flag to the new descriptor. Every `dup` in this daemon copies a PTY master
    /// or the TCP listener, and a copy without `FD_CLOEXEC` is inherited by every
    /// process exec'd while it is open: a `git` child was found on 2026-08-13
    /// holding the :7777 listener, which keeps the port bound after the daemon that
    /// opened it exits and hands the successor a spurious `EADDRINUSE`. A leaked
    /// master is worse still, since the child holding it keeps another session's
    /// terminal alive.
    ///
    /// Handover is unaffected: `SCM_RIGHTS` installs a fresh descriptor in the
    /// receiver rather than exec'ing, and the receiver's flags are its own.
    pub(crate) fn dup_cloexec(fd: RawFd) -> io::Result<RawFd> {
        // SAFETY: `F_DUPFD_CLOEXEC` only reads `fd` and returns a new descriptor;
        // the caller owns what comes back.
        let duplicate = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
        if duplicate < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(duplicate)
    }

    /// Mark `fd` close-on-exec, best-effort.
    ///
    /// For descriptors that do not already have the flag, which in this crate means
    /// anything not opened through `std`: `std` sets it on every socket and file it
    /// creates, whereas one received through `SCM_RIGHTS` arrives without it (macOS
    /// has no `MSG_CMSG_CLOEXEC` to ask for it), and so does a raw `libc::pipe`.
    pub(crate) fn set_cloexec(fd: RawFd) {
        // SAFETY: reads and writes only `fd`'s descriptor flags. A failure leaves
        // the descriptor as inheritable as it already was, which is not worth
        // failing a startup over.
        unsafe {
            let flags = libc::fcntl(fd, libc::F_GETFD);
            if flags >= 0 {
                libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
            }
        }
    }

    pub fn send_fds(socket: &UnixStream, fds: &[RawFd], data: &[u8]) -> io::Result<()> {
        send_initial_frame(socket, fds, data)
    }

    pub(crate) fn send_handover_fds(
        socket: &UnixStream,
        fds: &[RawFd],
        data: &[u8],
    ) -> io::Result<()> {
        let first_count = fds.len().min(MAX_FDS_PER_SEND);
        send_initial_frame(socket, &fds[..first_count], data)?;
        for chunk in fds[first_count..].chunks(MAX_FDS_PER_SEND) {
            send_fd_chunk(socket, chunk)?;
        }
        Ok(())
    }

    pub(crate) fn send_data_frame(socket: &UnixStream, data: &[u8]) -> io::Result<()> {
        let mut writer = socket;
        writer.write_all(&(data.len() as u32).to_be_bytes())?;
        writer.write_all(data)?;
        writer.flush()
    }

    pub(crate) fn recv_data_frame(socket: &UnixStream) -> io::Result<Vec<u8>> {
        let mut reader = socket;
        let mut len_prefix = [0u8; 4];
        reader.read_exact(&mut len_prefix)?;
        let data_len = u32::from_be_bytes(len_prefix) as usize;
        if data_len > MAX_HANDOVER_STATE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "handover state frame exceeds the protocol limit",
            ));
        }
        let mut data = vec![0; data_len];
        reader.read_exact(&mut data)?;
        Ok(data)
    }

    pub(crate) fn send_fd_chunks(socket: &UnixStream, fds: &[RawFd]) -> io::Result<()> {
        for chunk in fds.chunks(MAX_FDS_PER_SEND) {
            send_fd_chunk(socket, chunk)?;
        }
        Ok(())
    }

    fn allocate_control_buffer(cmsg_space: usize) -> Vec<usize> {
        let count = cmsg_space.div_ceil(std::mem::size_of::<usize>());
        vec![0usize; count]
    }

    pub(crate) fn send_initial_frame(
        socket: &UnixStream,
        fds: &[RawFd],
        data: &[u8],
    ) -> io::Result<()> {
        let len_prefix = (data.len() as u32).to_be_bytes();
        let mut iov = iovec {
            iov_base: len_prefix.as_ptr() as *mut libc::c_void,
            iov_len: len_prefix.len(),
        };
        let fds_size = std::mem::size_of_val(fds);
        let cmsg_space = if fds.is_empty() {
            0
        } else {
            (unsafe { libc::CMSG_SPACE(fds_size as u32) }) as usize
        };
        let mut control_buf = allocate_control_buffer(cmsg_space);
        let mut msg = msghdr {
            msg_name: std::ptr::null_mut(),
            msg_namelen: 0,
            msg_iov: &mut iov,
            msg_iovlen: 1,
            msg_control: if cmsg_space == 0 {
                std::ptr::null_mut()
            } else {
                control_buf.as_mut_ptr().cast()
            },
            msg_controllen: cmsg_space as _,
            msg_flags: 0,
        };
        if !fds.is_empty() {
            // SAFETY: `control_buf` was sized with CMSG_SPACE for this fd slice.
            unsafe {
                let cmsg = CMSG_FIRSTHDR(&msg);
                if cmsg.is_null() {
                    return Err(io::Error::other("CMSG_FIRSTHDR failed"));
                }
                (*cmsg).cmsg_level = SOL_SOCKET;
                (*cmsg).cmsg_type = SCM_RIGHTS;
                (*cmsg).cmsg_len = libc::CMSG_LEN(fds_size as u32) as _;
                std::ptr::copy_nonoverlapping(
                    fds.as_ptr(),
                    CMSG_DATA(cmsg) as *mut RawFd,
                    fds.len(),
                );
                msg.msg_controllen = (*cmsg).cmsg_len as _;
            }
        }

        // SAFETY: every pointer in `msg` refers to live input storage.
        let bytes_sent = unsafe { sendmsg(socket.as_raw_fd(), &msg, 0) };
        if bytes_sent < 0 {
            return Err(io::Error::last_os_error());
        }
        if bytes_sent == 0 {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "sendmsg wrote no handover length prefix bytes",
            ));
        }
        let sent = bytes_sent as usize;
        let mut writer = socket;
        writer.write_all(&len_prefix[sent..])?;
        writer.write_all(data)?;
        writer.flush()
    }

    fn send_fd_chunk(socket: &UnixStream, fds: &[RawFd]) -> io::Result<()> {
        debug_assert!(!fds.is_empty() && fds.len() <= MAX_FDS_PER_SEND);
        let fd = socket.as_raw_fd();
        let marker = [0xFDu8];
        let mut iov = iovec {
            iov_base: marker.as_ptr() as *mut libc::c_void,
            iov_len: marker.len(),
        };
        let fds_size = std::mem::size_of_val(fds);
        let cmsg_space = unsafe { libc::CMSG_SPACE(fds_size as u32) } as usize;
        let mut control_buf = allocate_control_buffer(cmsg_space);

        let mut msg = msghdr {
            msg_name: std::ptr::null_mut(),
            msg_namelen: 0,
            msg_iov: &mut iov as *mut iovec,
            msg_iovlen: 1,
            msg_control: control_buf.as_mut_ptr().cast(),
            msg_controllen: cmsg_space as _,
            msg_flags: 0,
        };

        unsafe {
            let cmsg = CMSG_FIRSTHDR(&msg);
            if cmsg.is_null() {
                return Err(io::Error::other("CMSG_FIRSTHDR failed"));
            }
            (*cmsg).cmsg_level = SOL_SOCKET;
            (*cmsg).cmsg_type = SCM_RIGHTS;
            (*cmsg).cmsg_len = libc::CMSG_LEN(fds_size as u32) as _;

            let data_ptr = CMSG_DATA(cmsg) as *mut RawFd;
            std::ptr::copy_nonoverlapping(fds.as_ptr(), data_ptr, fds.len());

            msg.msg_controllen = (*cmsg).cmsg_len as _;
        }

        let bytes_sent = unsafe { sendmsg(fd, &msg, 0) };
        if bytes_sent < 0 {
            return Err(io::Error::last_os_error());
        }

        if bytes_sent as usize != marker.len() {
            return Err(io::Error::other(
                "sendmsg failed to send the descriptor chunk marker",
            ));
        }
        Ok(())
    }

    pub(crate) struct ReceivedFds(Vec<RawFd>);

    impl ReceivedFds {
        fn into_raw(mut self) -> Vec<RawFd> {
            std::mem::take(&mut self.0)
        }

        pub(crate) fn len(&self) -> usize {
            self.0.len()
        }

        pub(crate) fn is_empty(&self) -> bool {
            self.0.is_empty()
        }
    }

    impl Drop for ReceivedFds {
        fn drop(&mut self) {
            for fd in self.0.drain(..) {
                // SAFETY: each descriptor was installed in this process by recvmsg.
                unsafe { libc::close(fd) };
            }
        }
    }

    pub fn recv_fds(socket: &UnixStream, max_fds: usize) -> io::Result<(Vec<u8>, Vec<RawFd>)> {
        recv_fds_guarded(socket, max_fds).map(|(data, fds)| (data, fds.into_raw()))
    }

    pub(crate) fn recv_fds_guarded(
        socket: &UnixStream,
        max_fds: usize,
    ) -> io::Result<(Vec<u8>, ReceivedFds)> {
        let fd = socket.as_raw_fd();

        let mut len_prefix = [0u8; 4];
        let mut iov = iovec {
            iov_base: len_prefix.as_mut_ptr() as *mut libc::c_void,
            iov_len: len_prefix.len(),
        };

        let fds_size = max_fds * std::mem::size_of::<RawFd>();
        let cmsg_space = unsafe { libc::CMSG_SPACE(fds_size as u32) } as usize;
        let mut control_buf = allocate_control_buffer(cmsg_space);

        let mut msg = msghdr {
            msg_name: std::ptr::null_mut(),
            msg_namelen: 0,
            msg_iov: &mut iov as *mut iovec,
            msg_iovlen: 1,
            msg_control: control_buf.as_mut_ptr().cast(),
            msg_controllen: cmsg_space as _,
            msg_flags: 0,
        };

        let bytes_received = unsafe { recvmsg(fd, &mut msg, 0) };
        if bytes_received < 0 {
            return Err(io::Error::last_os_error());
        }

        let mut received_fds = ReceivedFds(Vec::new());
        unsafe {
            let cmsg = CMSG_FIRSTHDR(&msg);
            if !cmsg.is_null()
                && (*cmsg).cmsg_level == SOL_SOCKET
                && (*cmsg).cmsg_type == SCM_RIGHTS
            {
                let len = ((*cmsg).cmsg_len as usize).saturating_sub(libc::CMSG_LEN(0) as usize);
                let fd_count = len / std::mem::size_of::<RawFd>();
                if fd_count > 0 {
                    received_fds.0.reserve(fd_count);
                    let data_ptr = CMSG_DATA(cmsg) as *const RawFd;
                    std::ptr::copy_nonoverlapping(data_ptr, received_fds.0.as_mut_ptr(), fd_count);
                    received_fds.0.set_len(fd_count);
                }
            }
        }

        if msg.msg_flags & libc::MSG_CTRUNC != 0 {
            return Err(io::Error::other(
                "recvmsg truncated the SCM_RIGHTS descriptor list",
            ));
        }

        if bytes_received == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "handover socket closed before the length prefix",
            ));
        }
        if bytes_received as usize > len_prefix.len() {
            return Err(io::Error::other(
                "recvmsg returned more bytes than the handover length prefix",
            ));
        }

        let mut reader = socket;
        reader.read_exact(&mut len_prefix[bytes_received as usize..])?;

        // Close-on-exec on arrival. `MSG_CMSG_CLOEXEC` would be the tidy way to ask
        // for this, but macOS does not implement it, so set the flag by hand instead
        // of having two behaviours to reason about per platform.
        //
        // This is the *largest* half of the descriptor leak, not a tidy-up: after a
        // handover every PTY master this daemon owns is a descriptor received here,
        // and each one it holds without the flag is inherited by every process it
        // execs from then on. A single `git` helper or newly spawned session shell
        // then holds a copy of every other session's master, which keeps those
        // terminals alive past their owner. See `dup_cloexec` for the other half of
        // this leak, and for the incident that exposed both.
        for fd in &received_fds.0 {
            set_cloexec(*fd);
        }

        let data_len = u32::from_be_bytes(len_prefix) as usize;
        if data_len > MAX_HANDOVER_STATE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "handover state frame exceeds the protocol limit",
            ));
        }
        let mut data_buf = vec![0u8; data_len];

        reader.read_exact(&mut data_buf)?;

        Ok((data_buf, received_fds))
    }

    pub(crate) fn recv_remaining_fds(
        socket: &UnixStream,
        expected: usize,
        received: &mut ReceivedFds,
    ) -> io::Result<()> {
        ensure_fd_capacity(expected.saturating_sub(received.0.len()))?;
        while received.0.len() < expected {
            let remaining = expected - received.0.len();
            let max_fds = remaining.min(MAX_HANDOVER_FDS);
            let fd = socket.as_raw_fd();
            let mut marker = [0u8; 1];
            let mut iov = iovec {
                iov_base: marker.as_mut_ptr().cast(),
                iov_len: marker.len(),
            };
            let fds_size = max_fds * std::mem::size_of::<RawFd>();
            let cmsg_space = unsafe { libc::CMSG_SPACE(fds_size as u32) } as usize;
            let mut control_buf = allocate_control_buffer(cmsg_space);
            let mut msg = msghdr {
                msg_name: std::ptr::null_mut(),
                msg_namelen: 0,
                msg_iov: &mut iov,
                msg_iovlen: 1,
                msg_control: control_buf.as_mut_ptr().cast(),
                msg_controllen: cmsg_space as _,
                msg_flags: 0,
            };
            // SAFETY: every pointer in `msg` refers to live writable storage.
            let bytes_received = unsafe { recvmsg(fd, &mut msg, 0) };
            if bytes_received < 0 {
                return Err(io::Error::last_os_error());
            }

            let before = received.0.len();
            // SAFETY: the kernel initialized the control headers described by `msg`.
            unsafe {
                let cmsg = CMSG_FIRSTHDR(&msg);
                if !cmsg.is_null()
                    && (*cmsg).cmsg_level == SOL_SOCKET
                    && (*cmsg).cmsg_type == SCM_RIGHTS
                {
                    let len =
                        ((*cmsg).cmsg_len as usize).saturating_sub(libc::CMSG_LEN(0) as usize);
                    let fd_count = len / std::mem::size_of::<RawFd>();
                    let data_ptr = CMSG_DATA(cmsg) as *const RawFd;
                    received.0.reserve(fd_count);
                    for index in 0..fd_count {
                        let received_fd = *data_ptr.add(index);
                        set_cloexec(received_fd);
                        received.0.push(received_fd);
                    }
                }
            }
            if msg.msg_flags & libc::MSG_CTRUNC != 0 {
                return Err(io::Error::other(
                    "recvmsg truncated an SCM_RIGHTS descriptor chunk",
                ));
            }
            if bytes_received != 1 || marker[0] != 0xFD || received.0.len() == before {
                return Err(io::Error::other("invalid SCM_RIGHTS descriptor chunk"));
            }
            if received.0.len() > expected {
                return Err(io::Error::other(
                    "handover sent more descriptors than its state declared",
                ));
            }
        }
        Ok(())
    }

    fn ensure_fd_capacity(additional: usize) -> io::Result<()> {
        let mut limit = std::mem::MaybeUninit::<libc::rlimit>::zeroed();
        // SAFETY: `limit` points to writable storage for getrlimit.
        if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, limit.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: getrlimit succeeded and initialized the structure.
        let mut limit = unsafe { limit.assume_init() };
        let open_fds = std::fs::read_dir("/dev/fd")
            .or_else(|_| std::fs::read_dir("/proc/self/fd"))
            .map(|entries| entries.filter_map(Result::ok).count())
            .unwrap_or(32);
        let required = (open_fds as libc::rlim_t).saturating_add(additional as libc::rlim_t);
        if required > limit.rlim_max {
            return Err(io::Error::from_raw_os_error(libc::EMFILE));
        }
        let desired = (open_fds as libc::rlim_t)
            .saturating_add(additional as libc::rlim_t)
            .saturating_add(256)
            .max(limit.rlim_cur)
            .min(limit.rlim_max);
        if desired == limit.rlim_cur {
            return Ok(());
        }
        limit.rlim_cur = desired;
        // SAFETY: `limit` was returned by getrlimit and only its soft value was
        // raised, never beyond the reported hard limit.
        if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    fn truncate_state_to_received_fds(state: &mut HandoverState, fd_count: usize) {
        let listener_count = usize::from(state.has_tcp_listener && fd_count > 0);
        if state.has_tcp_listener && fd_count == 0 {
            state.has_tcp_listener = false;
        }
        state
            .sessions
            .truncate(fd_count.saturating_sub(listener_count));
    }

    pub static INHERITED_FDS: Mutex<Option<Vec<RawFd>>> = Mutex::new(None);
    pub static INHERITED_STATE: Mutex<Option<String>> = Mutex::new(None);
    pub static HANDOVER_STREAM: Mutex<Option<UnixStream>> = Mutex::new(None);
    /// Random identity of the daemon that supplied the current handover. The
    /// liveness probe asks the newly connected peer to confirm this identity.
    static HANDOVER_PEER_TOKEN: Mutex<Option<[u8; 16]>> = Mutex::new(None);
    /// Process identity captured from the Phase 1 Unix connection. This is used
    /// only while upgrading from the preceding protocol, which announced a commit
    /// byte but did not serialize `HANDOVER_PEER_TOKEN` yet.
    static HANDOVER_PEER_PROCESS_IDENTITY: Mutex<Option<crate::ipc::PeerProcessIdentity>> =
        Mutex::new(None);
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum RecoveryOwnerKey {
        Lineage([u8; 16]),
        TcpListener(crate::ipc::SocketIdentity),
        OwnerToken([u8; 16]),
        Process(crate::ipc::PeerProcessIdentity),
        SocketPath(crate::ipc::SocketIdentity),
    }
    static RECOVERED_HANDOVERS: Mutex<Vec<(RecoveryOwnerKey, HandoverState, ReceivedFds)>> =
        Mutex::new(Vec::new());

    #[derive(Debug, Clone, PartialEq, Eq, Hash)]
    enum RecoverySessionKey {
        Process(HandoverProcessIdentity),
        Legacy(SessionId, u32),
    }

    fn recovery_session_key(session: &HandoverSession) -> RecoverySessionKey {
        session.process_identity.map_or_else(
            || RecoverySessionKey::Legacy(session.id.clone(), session.pid),
            RecoverySessionKey::Process,
        )
    }

    pub(crate) fn rename_recovered_session(
        session: &mut HandoverSession,
        mut id_unavailable: impl FnMut(&SessionId) -> bool,
    ) -> io::Result<()> {
        let base = format!("{}-recovered-{}", session.id, session.pid);
        let original_log = session.log_path.clone();
        let mut suffix = 1;
        loop {
            let candidate = if suffix == 1 {
                base.clone()
            } else {
                format!("{base}-{suffix}")
            };
            suffix += 1;
            let candidate_id = SessionId::new(candidate)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
            if id_unavailable(&candidate_id) {
                continue;
            }
            let candidate_log = original_log.with_file_name(format!("{candidate_id}.log"));
            let mut destination = match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&candidate_log)
            {
                Ok(destination) => destination,
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(error);
                }
            };
            match std::fs::File::open(&original_log) {
                Ok(mut source) => {
                    if let Err(error) = io::copy(&mut source, &mut destination) {
                        tracing::warn!(
                            %error,
                            from = %original_log.display(),
                            to = %candidate_log.display(),
                            "Could not copy recovery history to the renamed session log."
                        );
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => tracing::warn!(
                    %error,
                    from = %original_log.display(),
                    "Could not read recovery history for the renamed session."
                ),
            }
            session.id = candidate_id;
            session.log_path = candidate_log;
            return Ok(());
        }
    }
    /// When Phase 1 (state + FD transfer) finished, used to report how long this
    /// successor took to reach Phase 2, so unexpectedly slow warm-up is visible.
    static PHASE1_COMPLETED_AT: Mutex<Option<Instant>> = Mutex::new(None);
    static ACTIVE_TCP_LISTENER_FD: AtomicI32 = AtomicI32::new(-1);
    static ADOPTION_IN_PROGRESS: AtomicBool = AtomicBool::new(false);

    struct AdoptionAttemptGuard {
        clear_on_drop: bool,
    }

    impl AdoptionAttemptGuard {
        fn arm() -> Self {
            ADOPTION_IN_PROGRESS.store(true, Ordering::Release);
            Self {
                clear_on_drop: true,
            }
        }

        fn retain(mut self) {
            self.clear_on_drop = false;
        }
    }

    impl Drop for AdoptionAttemptGuard {
        fn drop(&mut self) {
            if self.clear_on_drop {
                ADOPTION_IN_PROGRESS.store(false, Ordering::Release);
            }
        }
    }

    pub fn adoption_in_progress() -> bool {
        ADOPTION_IN_PROGRESS.load(Ordering::Acquire)
    }

    pub fn finish_handover_adoption() {
        ADOPTION_IN_PROGRESS.store(false, Ordering::Release);
    }

    #[cfg(test)]
    pub(crate) fn remember_handover_peer_token(owner_token: Option<[u8; 16]>) {
        *HANDOVER_PEER_TOKEN
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = owner_token;
        *HANDOVER_PEER_PROCESS_IDENTITY
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
        RECOVERED_HANDOVERS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clear();
    }

    pub(crate) fn remember_handover_peer_identity(
        owner_token: Option<[u8; 16]>,
        owner_process_identity: Option<crate::ipc::PeerProcessIdentity>,
    ) {
        *HANDOVER_PEER_TOKEN
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = owner_token;
        *HANDOVER_PEER_PROCESS_IDENTITY
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = owner_process_identity;
    }

    pub fn set_active_tcp_listener_fd(fd: RawFd) {
        ACTIVE_TCP_LISTENER_FD.store(fd, Ordering::SeqCst);
    }

    pub fn get_active_tcp_listener_fd() -> RawFd {
        ACTIVE_TCP_LISTENER_FD.load(Ordering::SeqCst)
    }

    pub fn take_inherited_tcp_listener() -> Option<TcpListener> {
        let mut state_guard = INHERITED_STATE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(ref state_str) = *state_guard
            && let Ok(mut state) = serde_json::from_str::<HandoverState>(state_str)
            && state.has_tcp_listener
        {
            let mut fds_guard = INHERITED_FDS
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(fds) = fds_guard.as_mut()
                && !fds.is_empty()
            {
                let fd = fds.remove(0);
                state.has_tcp_listener = false;
                if let Ok(updated) = serde_json::to_string(&state) {
                    *state_guard = Some(updated);
                }
                tracing::info!(fd = fd, "Adopting inherited TCP listener");
                return Some(unsafe { TcpListener::from_raw_fd(fd) });
            }
        }
        None
    }

    pub fn perform_handover_client(socket_path: &Path) -> Result<HandoverClientOutcome> {
        // Arm before the descriptor receive. Once SCM_RIGHTS installs even one
        // master in this process, a simultaneous predecessor death can make it
        // the only surviving copy. Error and Busy returns disarm through Drop;
        // a completed transfer keeps the flag set through adoption.
        let adoption_attempt = AdoptionAttemptGuard::arm();
        let connect =
            |request: &[u8]| -> Result<(UnixStream, Option<crate::ipc::PeerProcessIdentity>)> {
                let stream = UnixStream::connect(socket_path)
                    .context("connecting to running daemon Unix socket")?;
                let peer_process_identity = crate::ipc::peer_process_identity(&stream);
                stream
                    .set_read_timeout(Some(HANDOVER_TRANSFER_TIMEOUT))
                    .context("setting handover client read timeout")?;
                let mut writer = BufWriter::new(&stream);
                writer
                    .write_all(request)
                    .context("sending Handover request")?;
                writer.flush().context("flushing request buffer")?;
                drop(writer);
                Ok((stream, peer_process_identity))
            };

        // New peers send metadata first and only then transfer descriptors. This
        // means an interrupted state frame cannot install PTY masters that the
        // receiver then has to discard without enough metadata to adopt them.
        // A predecessor that does not recognize HandoverV2 closes the connection;
        // reconnect with the published legacy request for rolling upgrades.
        let (stream, peer_process_identity, data, mut fds, metadata_first) = {
            let (stream, identity) = connect(b"{\"HandoverV2\":null}\n")?;
            match recv_data_frame(&stream) {
                Ok(data) => (stream, identity, data, ReceivedFds(Vec::new()), true),
                Err(version_error) => {
                    tracing::debug!(
                        %version_error,
                        "Handover peer does not support metadata-first framing; retrying legacy protocol."
                    );
                    // A legacy peer attaches descriptors to its first frame, so
                    // capacity must be available before reconnecting and asking
                    // it to send. V2 sends metadata first and reserves only the
                    // declared descriptor count in `recv_remaining_fds`.
                    ensure_fd_capacity(MAX_HANDOVER_FDS)
                        .context("reserving descriptor capacity for legacy handover")?;
                    let (stream, identity) = connect(b"{\"Handover\":null}\n")?;
                    let (data, fds) = recv_fds_guarded(&stream, MAX_HANDOVER_FDS)
                        .context("receiving legacy handover descriptors and state")?;
                    (stream, identity, data, fds, false)
                }
            }
        };

        if data.is_empty() {
            bail!("handover socket closed prematurely or returned empty state");
        }

        let response_str = std::str::from_utf8(&data).context("decoding handover JSON response")?;

        let wire_resp: serde_json::Value =
            serde_json::from_str(response_str).context("parsing handover response JSON")?;

        // A daemon already serving a handover refuses with this sentinel error so
        // the caller can retry rather than fall back to a fresh start (which would
        // fail to bind the port the outgoing daemon still holds). Any *other*
        // error response, or a malformed one, is a genuine failure: fall back.
        if let Some(message) = wire_resp
            .get("Err")
            .and_then(|err| err.get("message"))
            .and_then(|message| message.as_str())
        {
            if message == HANDOVER_BUSY_MESSAGE {
                return Ok(HandoverClientOutcome::Busy);
            }
            bail!("daemon refused handover: {message}");
        }

        let state_val = wire_resp
            .get("Ok")
            .and_then(|ok| ok.get("HandoverState"))
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "Handover request failed or returned invalid response format: {:?}",
                    wire_resp
                )
            })?;

        let mut handover_state = serde_json::from_value::<HandoverState>(state_val.clone())
            .context("decoding handover state identity")?;
        let expected_fd_count =
            handover_state.sessions.len() + usize::from(handover_state.has_tcp_listener);
        if metadata_first {
            // The metadata-first response carries no ancillary data. All
            // descriptors arrive in explicit, capacity-checked chunks below.
            debug_assert_eq!(fds.len(), 0);
        }
        if let Err(error) = recv_remaining_fds(&stream, expected_fd_count, &mut fds) {
            if fds.is_empty() {
                return Err(error).context("receiving remaining handover descriptor chunks");
            }
            truncate_state_to_received_fds(&mut handover_state, fds.len());
            let peer_token = handover_state.handover_owner_token;
            remember_handover_peer_identity(peer_token, peer_process_identity);
            RECOVERED_HANDOVERS
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .clear();
            *INHERITED_STATE
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) =
                Some(serde_json::to_string(&handover_state)?);
            *INHERITED_FDS
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(fds.into_raw());
            *HANDOVER_STREAM
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
            *PHASE1_COMPLETED_AT
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Instant::now());
            tracing::warn!(
                %error,
                received = handover_state.sessions.len(),
                expected = expected_fd_count,
                "Handover owner disappeared during descriptor chunks; retaining the mapped prefix for socket-owner recovery."
            );
            adoption_attempt.retain();
            return Ok(HandoverClientOutcome::Transferred);
        }
        if fds.len() != expected_fd_count {
            bail!(
                "handover sent {} descriptors for {} sessions (tcp listener: {})",
                fds.len(),
                handover_state.sessions.len(),
                handover_state.has_tcp_listener
            );
        }
        let peer_token = handover_state.handover_owner_token;
        let state_str = serde_json::to_string(&handover_state)?;
        let lineage_token = handover_state
            .handover_lineage_token
            .or(handover_state.handover_owner_token);
        if let Some(lineage_token) = lineage_token {
            crate::ipc::inherit_daemon_lineage(lineage_token);
        }
        // Remember the Phase 1 daemon's identity. If it dies before Phase 2 and
        // launchd respawns a daemon at the same pathname, the new listener cannot
        // confirm this identity and must not make us refuse the surviving PTYs.
        remember_handover_peer_identity(peer_token, peer_process_identity);
        RECOVERED_HANDOVERS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clear();
        *INHERITED_FDS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(fds.into_raw());
        *INHERITED_STATE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(state_str);
        *HANDOVER_STREAM
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(stream);
        *PHASE1_COMPLETED_AT
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Instant::now());

        if handover_state.handover_lineage_token.is_some() {
            let ready_result = HANDOVER_STREAM
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .as_ref()
                .ok_or_else(|| io::Error::other("handover stream disappeared before readiness"))
                .and_then(|stream| {
                    let mut ready_stream = stream.try_clone()?;
                    ready_stream.write_all(&[HANDOVER_FDS_READY_BYTE])?;
                    ready_stream.flush()
                });
            if let Err(error) = ready_result {
                tracing::warn!(
                    %error,
                    "Could not acknowledge the complete descriptor set; retaining it for socket-owner recovery."
                );
            }
        }

        adoption_attempt.retain();
        Ok(HandoverClientOutcome::Transferred)
    }

    /// Resolve a reachable socket owner through a complete second handover.
    /// Returns true only while ownership is still unresolved and the transferred
    /// descriptors must remain idle. A confirmed original and a replacement are
    /// handled identically: retain their fresh snapshot, make them detach, and
    /// merge it before any PTY reader starts.
    fn handover_owner_blocks_adoption(
        socket_path: &Path,
        expected_token: Option<[u8; 16]>,
        expected_process_identity: Option<crate::ipc::PeerProcessIdentity>,
    ) -> bool {
        let unreachable_owner_may_live = || {
            expected_process_identity
                .and_then(crate::ipc::peer_process_identity_is_alive)
                .unwrap_or_else(|| crate::ipc::handover_peer_is_reachable(socket_path))
        };
        let replacement_blocks_adoption = || {
            matches!(
                release_handover_peer(socket_path),
                ReplacementRelease::Unavailable
            )
        };
        match expected_token {
            Some(owner_token) => match crate::ipc::probe_handover_peer(
                socket_path,
                owner_token,
                expected_process_identity,
            ) {
                crate::ipc::HandoverPeerStatus::Original
                | crate::ipc::HandoverPeerStatus::Replacement => replacement_blocks_adoption(),
                crate::ipc::HandoverPeerStatus::Indeterminate => replacement_blocks_adoption(),
                crate::ipc::HandoverPeerStatus::Unreachable => unreachable_owner_may_live(),
            },
            None => match expected_process_identity {
                Some(owner_process_identity) => {
                    match crate::ipc::probe_handover_peer_process_identity(
                        socket_path,
                        owner_process_identity,
                    ) {
                        crate::ipc::HandoverPeerStatus::Original
                        | crate::ipc::HandoverPeerStatus::Replacement => {
                            replacement_blocks_adoption()
                        }
                        crate::ipc::HandoverPeerStatus::Indeterminate => {
                            replacement_blocks_adoption()
                        }
                        crate::ipc::HandoverPeerStatus::Unreachable => unreachable_owner_may_live(),
                    }
                }
                // Without a process identity there is no stronger signal than
                // reachability. A reachable owner must complete a recovery
                // handover; an absent listener cannot be retained forever on
                // Unix targets that expose no authenticated peer PID.
                None => {
                    crate::ipc::handover_peer_is_reachable(socket_path)
                        && replacement_blocks_adoption()
                }
            },
        }
    }

    /// Ask the process currently serving the socket to perform its own ordinary
    /// handover. Its descriptors are retained before the adoption byte is sent,
    /// so a death at any later point cannot lose sessions that were created after
    /// the original Phase 1 snapshot.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum ReplacementRelease {
        Released,
        Unavailable,
    }

    fn wait_for_committed_peer_teardown(
        stream: &mut UnixStream,
        process_identity: Option<crate::ipc::PeerProcessIdentity>,
    ) {
        wait_for_committed_peer_teardown_with(stream, || match process_identity {
            Some(identity) => {
                if let Err(terminate_error) = crate::ipc::terminate_handover_peer(identity) {
                    tracing::error!(
                        %terminate_error,
                        "Could not terminate the committed handover peer; retaining sessions."
                    );
                }
            }
            None => tracing::error!(
                "Committed handover peer has no safe process identity; retaining sessions."
            ),
        });
    }

    fn wait_for_committed_peer_teardown_with(
        stream: &mut UnixStream,
        mut on_timeout: impl FnMut(),
    ) {
        let mut timed_out = false;
        loop {
            let mut byte = [0; 1];
            match stream.read_exact(&mut byte) {
                Ok(()) if byte[0] == HANDOVER_DONE_BYTE => tracing::debug!(
                    "Handover peer reported detach complete; waiting for process teardown."
                ),
                Ok(()) => tracing::warn!(
                    byte = byte[0],
                    "Ignoring an unexpected byte while waiting for committed peer teardown."
                ),
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    if timed_out {
                        tracing::warn!(
                            "Committed handover peer stream remained quiet after termination attempt; proceeding with adoption."
                        );
                        return;
                    }
                    timed_out = true;
                    tracing::warn!(
                        %error,
                        "Committed handover peer exceeded its teardown grace; terminating the authenticated process."
                    );
                    on_timeout();
                }
                // Once 0x03 landed the peer cannot roll back: its server path
                // detaches unconditionally and exits. A closed/reset stream is
                // therefore equivalent to the courtesy 0x02 completion byte.
                Err(_) => return,
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn wait_for_committed_peer_teardown_for_test(
        stream: &mut UnixStream,
        on_timeout: impl FnMut(),
    ) {
        wait_for_committed_peer_teardown_with(stream, on_timeout);
    }

    fn release_handover_peer(socket_path: &Path) -> ReplacementRelease {
        let socket_identity_before = crate::ipc::socket_path_identity(socket_path);
        let Ok(mut stream) = UnixStream::connect(socket_path) else {
            return ReplacementRelease::Unavailable;
        };
        let socket_identity_after = crate::ipc::socket_path_identity(socket_path);
        let mut socket_identity = (socket_identity_before.is_some()
            && socket_identity_before == socket_identity_after)
            .then_some(socket_identity_before)
            .flatten();
        let mut process_identity = crate::ipc::peer_process_identity(&stream);
        if stream
            .set_read_timeout(Some(HANDOVER_TEARDOWN_TIMEOUT))
            .is_err()
            || stream
                .set_write_timeout(Some(HANDOVER_TEARDOWN_TIMEOUT))
                .is_err()
        {
            return ReplacementRelease::Unavailable;
        }
        let handover = (|| -> Result<ReplacementRelease> {
            stream.write_all(b"{\"HandoverV2\":null}\n")?;
            stream.flush()?;
            let (data, mut received_fds) = match recv_data_frame(&stream) {
                Ok(data) => (data, ReceivedFds(Vec::new())),
                Err(_) => {
                    ensure_fd_capacity(MAX_HANDOVER_FDS)?;
                    stream = UnixStream::connect(socket_path)?;
                    stream.set_read_timeout(Some(HANDOVER_TEARDOWN_TIMEOUT))?;
                    stream.set_write_timeout(Some(HANDOVER_TEARDOWN_TIMEOUT))?;
                    process_identity = crate::ipc::peer_process_identity(&stream);
                    let rebound_identity = crate::ipc::socket_path_identity(socket_path);
                    socket_identity = (socket_identity_before.is_some()
                        && socket_identity_before == rebound_identity)
                        .then_some(socket_identity_before)
                        .flatten();
                    stream.write_all(b"{\"Handover\":null}\n")?;
                    stream.flush()?;
                    recv_fds_guarded(&stream, MAX_HANDOVER_FDS)?
                }
            };
            let response: serde_json::Value = serde_json::from_slice(&data)?;
            let state = response
                .get("Ok")
                .and_then(|ok| ok.get("HandoverState"))
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("replacement declined empty handover"))?;
            let mut state: HandoverState = serde_json::from_value(state)?;
            let expected_fd_count = state.sessions.len() + usize::from(state.has_tcp_listener);
            if let Err(error) = recv_remaining_fds(&stream, expected_fd_count, &mut received_fds) {
                if received_fds.is_empty() {
                    return Err(error.into());
                }
                truncate_state_to_received_fds(&mut state, received_fds.len());
                remember_recovered_handover(
                    process_identity,
                    socket_identity,
                    state,
                    received_fds,
                )?;
                return Ok(ReplacementRelease::Unavailable);
            }
            if received_fds.len() != expected_fd_count {
                anyhow::bail!(
                    "recovery handover sent {} descriptors for {} sessions (tcp listener: {})",
                    received_fds.len(),
                    state.sessions.len(),
                    state.has_tcp_listener
                );
            }
            let uses_chunk_protocol = state.handover_lineage_token.is_some();
            remember_recovered_handover(process_identity, socket_identity, state, received_fds)?;
            if uses_chunk_protocol {
                stream.write_all(&[HANDOVER_FDS_READY_BYTE])?;
                stream.flush()?;
            }
            stream.write_all(&[HANDOVER_ADOPT_BYTE])?;
            stream.flush()?;
            let mut commit = [0; 1];
            stream.read_exact(&mut commit)?;
            match commit[0] {
                HANDOVER_COMMIT_BYTE | HANDOVER_DONE_BYTE => {
                    wait_for_committed_peer_teardown(&mut stream, process_identity);
                    Ok(ReplacementRelease::Released)
                }
                _ => Ok(ReplacementRelease::Unavailable),
            }
        })();
        handover.unwrap_or(ReplacementRelease::Unavailable)
    }

    fn remember_recovered_handover(
        process_identity: Option<crate::ipc::PeerProcessIdentity>,
        socket_identity: Option<crate::ipc::SocketIdentity>,
        state: HandoverState,
        fds: ReceivedFds,
    ) -> Result<()> {
        let tcp_listener_identity = state
            .has_tcp_listener
            .then(|| {
                fds.0
                    .first()
                    .copied()
                    .and_then(crate::ipc::socket_fd_identity)
            })
            .flatten();
        let key = state
            .handover_lineage_token
            .map(RecoveryOwnerKey::Lineage)
            .or_else(|| tcp_listener_identity.map(RecoveryOwnerKey::TcpListener))
            .or_else(|| state.handover_owner_token.map(RecoveryOwnerKey::OwnerToken))
            .or_else(|| process_identity.map(RecoveryOwnerKey::Process))
            .or_else(|| socket_identity.map(RecoveryOwnerKey::SocketPath))
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "recovery peer supplied no stable process, listener, or socket identity"
                )
            })?;
        let mut recovered = RECOVERED_HANDOVERS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some((_, retained_state, retained_fds)) =
            recovered.iter_mut().find(|(owner, _, _)| *owner == key)
        {
            compact_recovery_snapshot(retained_state, retained_fds, state, fds);
            return Ok(());
        }
        recovered.push((key, state, fds));
        Ok(())
    }

    fn compact_recovery_snapshot(
        retained_state: &mut HandoverState,
        retained_fds: &mut ReceivedFds,
        mut fresh_state: HandoverState,
        mut fresh_fds: ReceivedFds,
    ) {
        let retained_offset = usize::from(retained_state.has_tcp_listener);
        for index in (0..retained_state.sessions.len()).rev() {
            let fd_index = retained_offset + index;
            let Some(&fd) = retained_fds.0.get(fd_index) else {
                retained_state.sessions.remove(index);
                continue;
            };
            let alive = retained_state.sessions[index].process_identity.map_or_else(
                || {
                    // SAFETY: `fd` is a retained PTY master. A positive
                    // foreground process group proves a live slave still belongs
                    // to this terminal without trusting a reusable PID.
                    let foreground = unsafe { libc::tcgetpgrp(fd) };
                    tokenless_pty_foreground_is_live(
                        foreground,
                        io::Error::last_os_error().raw_os_error(),
                    )
                },
                handover_process_identity_is_current,
            );
            if !alive {
                retained_state.sessions.remove(index);
                let stale_fd = retained_fds.0.remove(fd_index);
                // SAFETY: removing transfers ownership out of the RAII vector.
                unsafe { libc::close(stale_fd) };
            }
        }

        if fresh_state.has_tcp_listener && !fresh_fds.0.is_empty() {
            let fresh_listener = fresh_fds.0.remove(0);
            if retained_state.has_tcp_listener && !retained_fds.0.is_empty() {
                let stale_listener = std::mem::replace(&mut retained_fds.0[0], fresh_listener);
                // SAFETY: the newer snapshot replaces this independently-owned dup.
                unsafe { libc::close(stale_listener) };
            } else {
                retained_fds.0.insert(0, fresh_listener);
                retained_state.has_tcp_listener = true;
            }
        }

        let mut retained_indices: std::collections::HashMap<RecoverySessionKey, usize> =
            retained_state
                .sessions
                .iter()
                .enumerate()
                .map(|(index, session)| (recovery_session_key(session), index))
                .collect();
        let offset = usize::from(retained_state.has_tcp_listener);
        let mut fresh_fds_iter = fresh_fds.into_raw().into_iter();
        for fresh_session in fresh_state.sessions.drain(..) {
            let Some(fresh_fd) = fresh_fds_iter.next() else {
                break;
            };
            let identity = recovery_session_key(&fresh_session);
            if let Some(&index) = retained_indices.get(&identity) {
                let stale_fd = std::mem::replace(&mut retained_fds.0[offset + index], fresh_fd);
                // SAFETY: the fresh snapshot replaces this independently-owned dup.
                unsafe { libc::close(stale_fd) };
                retained_state.sessions[index] = fresh_session;
            } else {
                let index = retained_state.sessions.len();
                retained_state.sessions.push(fresh_session);
                retained_fds.0.push(fresh_fd);
                retained_indices.insert(identity, index);
            }
        }
        for extra_fd in fresh_fds_iter {
            // SAFETY: any unconsumed descriptors from the fresh recovery snapshot must be closed.
            unsafe { libc::close(extra_fd) };
        }
        retained_state.sends_teardown_commit = fresh_state.sends_teardown_commit;
        retained_state.handover_owner_token = fresh_state.handover_owner_token;
        retained_state.handover_lineage_token = fresh_state.handover_lineage_token;
    }

    fn tokenless_pty_foreground_is_live(
        foreground: libc::pid_t,
        error: Option<libc::c_int>,
    ) -> bool {
        foreground > 0 || (foreground < 0 && error != Some(libc::EIO))
    }

    #[cfg(test)]
    pub(crate) fn tokenless_pty_foreground_is_live_for_test(
        foreground: libc::pid_t,
        error: Option<libc::c_int>,
    ) -> bool {
        tokenless_pty_foreground_is_live(foreground, error)
    }

    #[cfg(test)]
    pub(crate) fn remember_recovered_handover_for_test(state: HandoverState, fds: Vec<RawFd>) {
        remember_recovered_handover(None, None, state, ReceivedFds(fds))
            .expect("test recovery snapshot has a stable identity");
    }

    #[cfg(test)]
    pub(crate) fn remember_tokenless_recovered_handover_for_test(
        socket_identity: crate::ipc::SocketIdentity,
        state: HandoverState,
        fds: Vec<RawFd>,
    ) {
        remember_recovered_handover(None, Some(socket_identity), state, ReceivedFds(fds))
            .expect("test recovery snapshot has a socket identity");
    }

    /// Merge descriptors retained during Phase-2 recovery into the original
    /// transfer. Exact process-birth matches replace stale snapshots; an id
    /// reused for another live child is renamed so neither PTY is lost.
    pub fn merge_recovered_handovers(state: &mut HandoverState, fds: &mut Vec<RawFd>) {
        if fds.len() != state.sessions.len() {
            tracing::error!(
                descriptors = fds.len(),
                sessions = state.sessions.len(),
                "Handover descriptor count is incomplete; adopting every available session instead of exiting."
            );
        }
        let recovered = std::mem::take(
            &mut *RECOVERED_HANDOVERS
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()),
        );
        let mut identity_indices: std::collections::HashMap<RecoverySessionKey, usize> = state
            .sessions
            .iter()
            .enumerate()
            .map(|(index, session)| (recovery_session_key(session), index))
            .collect();
        for (_, mut recovered_state, recovered_fds) in recovered {
            let mut raw_fds = recovered_fds.into_raw();
            if recovered_state.has_tcp_listener && !raw_fds.is_empty() {
                let listener_fd = raw_fds.remove(0);
                // SAFETY: the recovery snapshot installed this independent fd in
                // our process. `main` already retained the original listener.
                unsafe { libc::close(listener_fd) };
                recovered_state.has_tcp_listener = false;
            }
            let mut fds_iter = raw_fds.into_iter();
            for mut recovered_session in recovered_state.sessions {
                let Some(recovered_fd) = fds_iter.next() else {
                    tracing::error!(
                        session_id = %recovered_session.id,
                        "recovered handover state contains more sessions than descriptors"
                    );
                    break;
                };
                let identity = recovery_session_key(&recovered_session);
                if let Some(&index) = identity_indices.get(&identity)
                    && index < fds.len()
                {
                    let old_fd = std::mem::replace(&mut fds[index], recovered_fd);
                    // SAFETY: this fd came from the original SCM_RIGHTS transfer
                    // and the fresh recovery snapshot now replaces its ownership.
                    unsafe { libc::close(old_fd) };
                    recovered_session.id = state.sessions[index].id.clone();
                    recovered_session.log_path = state.sessions[index].log_path.clone();
                    state.sessions[index] = recovered_session;
                    continue;
                }
                if state
                    .sessions
                    .iter()
                    .any(|session| session.id == recovered_session.id)
                    && let Err(error) =
                        rename_recovered_session(&mut recovered_session, |candidate| {
                            state
                                .sessions
                                .iter()
                                .any(|session| session.id == *candidate)
                        })
                {
                    tracing::warn!(
                        %error,
                        session_id = %recovered_session.id,
                        "could not reserve a distinct recovery log; deferring the rename to adoption"
                    );
                }
                let index = state.sessions.len();
                state.sessions.push(recovered_session);
                fds.push(recovered_fd);
                identity_indices.insert(identity, index);
            }
            for extra_fd in fds_iter {
                // SAFETY: any unconsumed descriptors from the recovery snapshot must be closed.
                unsafe { libc::close(extra_fd) };
            }
        }
    }

    /// Reserve the IPC pathname before adopted readers start. Any daemon that
    /// wins the pathname first is itself handed over and merged, so KeepAlive
    /// respawns cannot strand the retained sessions behind an empty listener.
    pub fn claim_handover_socket(
        socket_path: &Path,
        state: &mut HandoverState,
        fds: &mut Vec<RawFd>,
    ) {
        loop {
            match crate::ipc::try_prebind_owner_socket(socket_path) {
                Ok(true) => {
                    merge_recovered_handovers(state, fds);
                    return;
                }
                Ok(false) => {
                    let _ = release_handover_peer(socket_path);
                }
                Err(error) => tracing::warn!(
                    %error,
                    socket_path = %socket_path.display(),
                    "Could not reserve the handover IPC socket; retaining sessions and retrying."
                ),
            }
            std::thread::sleep(std::time::Duration::from_millis(250));
        }
    }

    /// Retain the transferred descriptors without starting readers until the
    /// process serving the old socket has atomically committed its own handover
    /// or disappeared. A liveness probe alone cannot authorize dropping the
    fn wait_for_handover_owner_release(
        socket_path: &Path,
        expected_token: Option<[u8; 16]>,
        expected_process_identity: Option<crate::ipc::PeerProcessIdentity>,
    ) {
        tracing::warn!(
            "Retaining transferred sessions while the current socket owner still blocks safe adoption."
        );
        loop {
            std::thread::sleep(std::time::Duration::from_millis(250));
            if !handover_owner_blocks_adoption(
                socket_path,
                expected_token,
                expected_process_identity,
            ) {
                tracing::info!(
                    "The prior socket owner released or disappeared; adopting retained sessions."
                );
                return;
            }
        }
    }

    /// Send the `0x01` adoption byte and resolve ownership before returning.
    ///
    /// `peer_sends_commit` comes from the transferred [`HandoverState`]: it says
    /// whether the outgoing daemon announces a `0x03` commit byte before it
    /// detaches, which is what lets a pre-commit EOF be read as "the daemon kept
    /// its sessions" (refuse) rather than "detached, `0x02` lost" (adopt).
    ///
    /// `socket_path` is the peer's IPC socket, probed to tell an aborted peer from
    /// a dead one when the read ends without a teardown byte. See
    /// [`teardown_outcome`].
    pub fn complete_handover_adoption(
        socket_path: &Path,
        peer_sends_commit: bool,
    ) -> Result<TeardownOutcome> {
        let stream = HANDOVER_STREAM
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        let peer_token = *HANDOVER_PEER_TOKEN
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let peer_process_identity = *HANDOVER_PEER_PROCESS_IDENTITY
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(mut stream) = stream else {
            // No handover stream: this start was not driven by a handover, so
            // there is no old daemon to sync with. Nothing to refuse.
            return Ok(TeardownOutcome::Adopt);
        };

        // Deliberately no budget field here: the deadline that decides this
        // handover belongs to the *outgoing* daemon's binary, which may be an
        // older build with a different (shorter) bound. Logging our own
        // constant would claim headroom that was never in force.
        // Read rather than take, so the measurement survives for the error
        // path below: the gap is the single most useful number to have when
        // the write fails. Poisoning must not abort a swap over a log field,
        // hence recovering the guard instead of unwrapping.
        // `-1` rather than an absent field: a missing key is indistinguishable
        // from an older daemon that never emitted one.
        let gap_ms = PHASE1_COMPLETED_AT
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .map_or(-1, |at| at.elapsed().as_millis() as i64);
        tracing::info!(
            gap_ms,
            peer_sends_commit,
            "Completing handover adoption (Phase 2 sync)..."
        );

        // Arm the Phase-3 read deadline before writing 0x01. Once that byte
        // lands the outgoing daemon may detach its sessions, so from here on any
        // error must not abort adoption: doing so would strand every session
        // with no daemon owning it. set_read_timeout is a local setsockopt with
        // no effect on the peer, so moving it ahead of the commit is free and
        // removes the one fallible call that used to sit past the point of no
        // return.
        //
        // If writing the 0x01 adoption byte fails (or setting the timeout fails
        // on a broken socket), the outcome depends on whether the peer is dead
        // or alive:
        // - peer dead: the outgoing daemon died (or was SIGKILLed by launchd / the
        //   supervisor during Phase 2 warm-up) before receiving the adoption byte.
        //   Its descriptors died with it, and this process holds the only surviving
        //   handles. Aborting would destroy all live sessions, so adopt what was
        //   transferred.
        // - peer alive: the outgoing daemon timed out or aborted and is still
        //   serving on its own copies of the descriptors. Refuse adoption so the
        //   living peer keeps serving without double readers.
        let write_res = stream
            .set_read_timeout(Some(HANDOVER_TEARDOWN_TIMEOUT))
            .and_then(|()| stream.write_all(&[HANDOVER_ADOPT_BYTE]))
            .and_then(|()| stream.flush());

        if let Err(err) = write_res {
            drop(stream);
            let peer_alive =
                handover_owner_blocks_adoption(socket_path, peer_token, peer_process_identity);
            tracing::warn!(
                peer_alive,
                gap_ms,
                "Failed to send adoption sync byte (0x01) to old daemon: {err}"
            );
            if !peer_alive {
                tracing::warn!(
                    "Old daemon died before receiving adoption byte; adopting because nothing \
                     else holds these sessions."
                );
                return Ok(TeardownOutcome::Adopt);
            }
            wait_for_handover_owner_release(socket_path, peer_token, peer_process_identity);
            return Ok(TeardownOutcome::Adopt);
        }

        tracing::info!("Waiting for old daemon teardown (Phase 3 sync)...");
        let mut sync_byte = [0u8; 1];
        // A timeout and a closed socket are NOT interchangeable here. The read
        // deadline is enforced locally via SO_RCVTIMEO, which surfaces as
        // WouldBlock (or TimedOut on some platforms) and leaves the peer
        // connected; anything else means the peer is gone. teardown_outcome
        // resolves them in opposite directions, so the kind must survive.
        let signal = match stream.read_exact(&mut sync_byte) {
            Ok(()) if sync_byte[0] == HANDOVER_COMMIT_BYTE => {
                wait_for_committed_peer_teardown(&mut stream, peer_process_identity);
                TeardownSignal::Byte(HANDOVER_COMMIT_BYTE)
            }
            Ok(()) if sync_byte[0] == HANDOVER_DONE_BYTE => {
                // Older daemons send 0x02 immediately after detaching, before
                // their reader threads and process have necessarily stopped.
                wait_for_committed_peer_teardown(&mut stream, peer_process_identity);
                TeardownSignal::Byte(HANDOVER_DONE_BYTE)
            }
            Ok(()) => TeardownSignal::Byte(sync_byte[0]),
            Err(err)
                if matches!(
                    err.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                tracing::warn!("Timed out waiting for teardown byte from old daemon: {err}");
                TeardownSignal::Timeout
            }
            Err(err) => {
                // The peer closed on us. Whether it aborted (and kept serving) or
                // died decides adopt-vs-refuse, and only a liveness probe can tell
                // them apart: see `handover_owner_blocks_adoption`.
                let peer_alive =
                    handover_owner_blocks_adoption(socket_path, peer_token, peer_process_identity);
                tracing::warn!(
                    peer_alive,
                    "Failed to read teardown byte from old daemon: {err}"
                );
                TeardownSignal::Eof { peer_alive }
            }
        };

        let outcome = teardown_outcome(peer_sends_commit, signal);
        match (outcome, signal) {
            (TeardownOutcome::Adopt, TeardownSignal::Byte(HANDOVER_COMMIT_BYTE)) => {
                tracing::info!("Old daemon committed to teardown (0x03); adopting.");
            }
            (TeardownOutcome::Adopt, TeardownSignal::Byte(HANDOVER_DONE_BYTE)) => {
                tracing::info!("Old daemon reported teardown complete (0x02); adopting.");
            }
            (TeardownOutcome::Adopt, TeardownSignal::Timeout) => {
                tracing::warn!(
                    "Legacy daemon did not send a teardown byte before the deadline; retaining \
                     descriptors until its ownership can be resolved."
                );
                drop(stream);
                wait_for_handover_owner_release(socket_path, peer_token, peer_process_identity);
                return Ok(TeardownOutcome::Adopt);
            }
            (TeardownOutcome::Adopt, TeardownSignal::Eof { peer_alive: false }) => {
                // The peer died mid-handover. Its descriptors went with it, so we
                // hold the only handles to these sessions; refusing would destroy
                // sessions that are still perfectly alive.
                tracing::warn!(
                    "Old daemon died before committing its teardown; adopting because nothing \
                     else holds these sessions."
                );
            }
            (TeardownOutcome::Adopt, _) => {
                // Legacy peer (no commit byte announced) with an ambiguous EOF or
                // stray byte: adopt, matching the historical behavior, because
                // refusing would strand sessions an old daemon really did detach.
                tracing::warn!(
                    "Old daemon sent no commit byte and predates the commit protocol; \
                     adopting to avoid stranding a real handover."
                );
            }
            (TeardownOutcome::Refuse, _) => {
                tracing::warn!(
                    "Old daemon announced a teardown-commit byte but never sent it, so it \
                     aborted the handover and may still own its sessions."
                );
                drop(stream);
                wait_for_handover_owner_release(socket_path, peer_token, peer_process_identity);
                return Ok(TeardownOutcome::Adopt);
            }
        }
        Ok(TeardownOutcome::Adopt)
    }

    /// A PTY master inherited through a handover.
    ///
    /// The descriptor is an [`OwnedFd`] rather than a bare `RawFd` so the leak
    /// this type used to cause is unrepresentable. Holding a raw number meant
    /// nothing closed it — the reader and writer handed to a session are `dup`s
    /// that close themselves, so an adopted session that ended leaked exactly its
    /// master. That compounds, because every handover re-adopts every session.
    ///
    /// The descriptor closes when this value drops — which session end is not: a
    /// session whose child has exited leaves `run_actor` polling for commands with
    /// this master still open. What does drop it:
    ///
    /// - the actor loop returns, on a `Shutdown` command or when its command
    ///   channel disconnects. That second case includes a handover detach, which
    ///   closes this master while the session lives on; see
    ///   [`crate::session::SessionManager::detach_all_live_sessions`].
    /// - adoption gives up before the loop starts — any early return on the path
    ///   from `UnadoptedFds::take_next` to a running actor, a failed reader- or
    ///   worker-thread spawn included, drops the wrapper it was handed.
    ///
    /// Closing it under a live session does not undo the handover, because the
    /// successor is not sharing this descriptor: `SCM_RIGHTS` installs an
    /// independent one in that process, and `extract_handover_state` sends a
    /// duplicate rather than this fd itself. The child keeps its slave side
    /// regardless, so the session survives on the successor's copy.
    #[derive(Debug)]
    pub struct AdoptedMasterPty {
        /// Private, and reachable only through [`Self::from_raw_fd`]: the whole
        /// point of the type is that exactly one owner holds this descriptor, and
        /// a `pub` field lets a caller construct or replace it without going
        /// through the one constructor that documents what that costs.
        fd: OwnedFd,
    }

    impl AdoptedMasterPty {
        /// Take ownership of an inherited descriptor.
        ///
        /// `pub(crate)` rather than `pub`: both callers live in this crate
        /// (`spawn_adopted_pty_runtime` and its test), and an `unsafe` constructor
        /// is worth keeping as close to its invariant as the call sites allow.
        ///
        /// # Safety
        ///
        /// `fd` must be an open descriptor this process owns and nothing else will
        /// close — in practice one handed over by `UnadoptedFds::take_next`, which
        /// gives up its claim precisely so this type can take it.
        pub(crate) unsafe fn from_raw_fd(fd: RawFd) -> Self {
            Self {
                fd: unsafe { OwnedFd::from_raw_fd(fd) },
            }
        }

        fn raw(&self) -> RawFd {
            self.fd.as_raw_fd()
        }

        fn try_clone_signal_target(
            &self,
            pid: u32,
            process_identity: Option<HandoverProcessIdentity>,
        ) -> io::Result<(AdoptedSignalTarget, Option<HandoverProcessIdentity>)> {
            #[cfg(not(any(target_os = "linux", target_os = "android")))]
            let _ = (pid, process_identity);
            let fd = dup_cloexec(self.raw())?;
            #[cfg(any(target_os = "linux", target_os = "android"))]
            let process_identity = process_identity.or_else(|| {
                let mut session_id = 0 as libc::pid_t;
                // SAFETY: TIOCGSID writes one pid_t to the supplied address and
                // only reads the PTY descriptor.
                if unsafe {
                    libc::ioctl(
                        self.raw(),
                        libc::TIOCGSID as _,
                        std::ptr::addr_of_mut!(session_id),
                    )
                } < 0
                    || session_id != pid as libc::pid_t
                {
                    return None;
                }
                let identity = handover_process_identity(pid)?;
                let mut confirmed_session_id = 0 as libc::pid_t;
                if unsafe {
                    libc::ioctl(
                        self.raw(),
                        libc::TIOCGSID as _,
                        std::ptr::addr_of_mut!(confirmed_session_id),
                    )
                } < 0
                    || confirmed_session_id != pid as libc::pid_t
                    || !handover_process_identity_is_current(identity)
                {
                    return None;
                }
                Some(identity)
            });
            #[cfg(any(target_os = "linux", target_os = "android"))]
            let pidfd = process_identity.and_then(|identity| {
                if !handover_process_identity_is_current(identity) {
                    return None;
                }
                // SAFETY: pidfd_open takes a numeric PID and returns either a new
                // owned descriptor or -1. Rechecking the birth identity after the
                // open rejects reuse between the first check and this syscall.
                let result = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
                if result < 0 {
                    return None;
                }
                let result = result as RawFd;
                set_cloexec(result);
                if !handover_process_identity_is_current(identity) {
                    // SAFETY: pidfd_open returned this descriptor to this call.
                    unsafe { libc::close(result) };
                    return None;
                }
                // SAFETY: the successful pidfd_open descriptor is uniquely owned.
                Some(Arc::new(unsafe { OwnedFd::from_raw_fd(result) }))
            });
            // SAFETY: `dup_cloexec` returned a new descriptor owned by this call.
            Ok((
                AdoptedSignalTarget {
                    pty: Arc::new(unsafe { OwnedFd::from_raw_fd(fd) }),
                    #[cfg(any(target_os = "linux", target_os = "android"))]
                    pidfd,
                },
                process_identity,
            ))
        }

        pub(crate) fn try_clone_cancelable_reader(
            &self,
        ) -> io::Result<(Box<dyn Read + Send>, AdoptedReaderCancel)> {
            let dup_fd = dup_cloexec(self.raw())?;
            // SAFETY: `dup_cloexec` returned a new descriptor owned by this call.
            let pty = unsafe { std::fs::File::from_raw_fd(dup_fd) };
            let (cancel_reader, cancel_writer) = UnixStream::pair()?;
            cancel_writer.set_nonblocking(true)?;
            Ok((
                Box::new(CancelablePtyReader {
                    pty,
                    cancel: cancel_reader,
                }),
                AdoptedReaderCancel(Arc::new(cancel_writer)),
            ))
        }
    }

    impl MasterPty for AdoptedMasterPty {
        fn resize(&self, size: PtySize) -> Result<(), anyhow::Error> {
            let ws = libc::winsize {
                ws_row: size.rows,
                ws_col: size.cols,
                ws_xpixel: size.pixel_width,
                ws_ypixel: size.pixel_height,
            };
            let res = unsafe { libc::ioctl(self.raw(), libc::TIOCSWINSZ, &ws) };
            if res < 0 {
                Err(anyhow::Error::new(std::io::Error::last_os_error()))
            } else {
                Ok(())
            }
        }

        fn get_size(&self) -> Result<PtySize, anyhow::Error> {
            let mut ws = libc::winsize {
                ws_row: 0,
                ws_col: 0,
                ws_xpixel: 0,
                ws_ypixel: 0,
            };
            let res = unsafe { libc::ioctl(self.raw(), libc::TIOCGWINSZ, &mut ws) };
            if res < 0 {
                Err(anyhow::Error::new(std::io::Error::last_os_error()))
            } else {
                Ok(PtySize {
                    rows: ws.ws_row,
                    cols: ws.ws_col,
                    pixel_width: ws.ws_xpixel,
                    pixel_height: ws.ws_ypixel,
                })
            }
        }

        fn try_clone_reader(&self) -> Result<Box<dyn std::io::Read + Send>, anyhow::Error> {
            // `dup_cloexec`, not `dup`: this copy lives for the session's whole
            // life, so a copy without FD_CLOEXEC would be inherited by every
            // process the daemon execs afterwards, including every *other*
            // session's child.
            let dup_fd = dup_cloexec(self.raw())?;
            let file = unsafe { std::fs::File::from_raw_fd(dup_fd) };
            Ok(Box::new(file))
        }

        fn take_writer(&self) -> Result<Box<dyn std::io::Write + Send>, anyhow::Error> {
            let dup_fd = dup_cloexec(self.raw())?;
            let file = unsafe { std::fs::File::from_raw_fd(dup_fd) };
            Ok(Box::new(file))
        }

        fn as_raw_fd(&self) -> Option<RawFd> {
            Some(self.raw())
        }

        fn process_group_leader(&self) -> Option<i32> {
            None
        }

        fn tty_name(&self) -> Option<PathBuf> {
            None
        }
    }

    impl AsRawFd for AdoptedMasterPty {
        fn as_raw_fd(&self) -> RawFd {
            self.raw()
        }
    }

    struct CancelablePtyReader {
        pty: std::fs::File,
        cancel: UnixStream,
    }

    impl Read for CancelablePtyReader {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            if buffer.is_empty() {
                return Ok(0);
            }
            let mut descriptors = [
                libc::pollfd {
                    fd: self.pty.as_raw_fd(),
                    events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                    revents: 0,
                },
                libc::pollfd {
                    fd: self.cancel.as_raw_fd(),
                    events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                    revents: 0,
                },
            ];
            loop {
                // SAFETY: both pollfd entries describe live descriptors owned by
                // this reader and remain valid for the duration of the call.
                let result = unsafe { libc::poll(descriptors.as_mut_ptr(), 2, -1) };
                if result < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                if descriptors[1].revents != 0 {
                    return Ok(0);
                }
                if descriptors[0].revents != 0 {
                    return self.pty.read(buffer);
                }
            }
        }
    }

    #[derive(Debug, Clone)]
    pub(crate) struct AdoptedReaderCancel(Arc<UnixStream>);

    impl AdoptedReaderCancel {
        fn cancel(&self) -> io::Result<()> {
            let mut writer = &*self.0;
            loop {
                match writer.write(&[1]) {
                    Ok(_) => return Ok(()),
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset
                        ) =>
                    {
                        return Ok(());
                    }
                    Err(error) => return Err(error),
                }
            }
        }
    }

    #[derive(Debug, Clone)]
    struct AdoptedSignalTarget {
        pty: Arc<OwnedFd>,
        #[cfg(any(target_os = "linux", target_os = "android"))]
        pidfd: Option<Arc<OwnedFd>>,
    }

    impl AdoptedSignalTarget {
        fn terminate(&self, process_identity: Option<HandoverProcessIdentity>) -> io::Result<()> {
            #[cfg(any(target_os = "linux", target_os = "android"))]
            for _ in 0..50 {
                // Linux TIOCSIG accepts the interactive signal set only. SIGQUIT
                // terminates the foreground job through the PTY-bound process
                // group before pidfd targets the serialized shell itself.
                let result =
                    unsafe { libc::ioctl(self.pty.as_raw_fd(), libc::TIOCSIG as _, libc::SIGQUIT) };
                if result < 0 {
                    let error = io::Error::last_os_error();
                    if !matches!(error.raw_os_error(), Some(libc::EIO) | Some(libc::ENXIO)) {
                        return Err(error);
                    }
                    break;
                }
                if let Some(identity) = process_identity {
                    let foreground = unsafe { libc::tcgetpgrp(self.pty.as_raw_fd()) };
                    if foreground <= 0 || foreground == identity.pid as libc::pid_t {
                        break;
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(20));
            }

            #[cfg(any(target_os = "linux", target_os = "android"))]
            if let Some(identity) = process_identity {
                // If SIGQUIT did not clear a separate foreground job, killing
                // only the serialized shell would orphan that job and make a
                // failed shutdown look successful. There is no race-free group
                // kill handle on these targets, so leave the actor intact and
                // report that the job must be stopped first.
                let foreground = unsafe { libc::tcgetpgrp(self.pty.as_raw_fd()) };
                if foreground > 0 && foreground != identity.pid as libc::pid_t {
                    return Err(io::Error::new(
                        io::ErrorKind::WouldBlock,
                        "PTY foreground process group ignored the termination signal",
                    ));
                }
            }

            #[cfg(any(target_os = "linux", target_os = "android"))]
            if let Some(pidfd) = self.pidfd.as_ref() {
                // SAFETY: pidfd_send_signal resolves the process through the
                // already-open kernel handle, not through a reusable PID.
                let result = unsafe {
                    libc::syscall(
                        libc::SYS_pidfd_send_signal,
                        pidfd.as_raw_fd(),
                        libc::SIGKILL,
                        std::ptr::null::<libc::siginfo_t>(),
                        0,
                    )
                };
                if result < 0 {
                    let error = io::Error::last_os_error();
                    if error.raw_os_error() != Some(libc::ESRCH) {
                        return Err(error);
                    }
                }
                return Ok(());
            }

            #[cfg(any(target_os = "linux", target_os = "android"))]
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "adopted session has no PID-safe termination target",
            ));

            #[cfg(any(
                target_vendor = "apple",
                target_os = "freebsd",
                target_os = "dragonfly"
            ))]
            for _ in 0..20 {
                // TIOCSIG resolves the foreground process group through this PTY
                // in the kernel. Repeat because a foreground job can die first,
                // after which the serialized shell regains the terminal.
                let result =
                    unsafe { libc::ioctl(self.pty.as_raw_fd(), libc::TIOCSIG as _, libc::SIGKILL) };
                if result < 0 {
                    let error = io::Error::last_os_error();
                    if !matches!(error.raw_os_error(), Some(libc::EIO) | Some(libc::ENXIO)) {
                        return Err(error);
                    }
                }
                if process_identity
                    .is_some_and(|identity| !handover_process_identity_is_current(identity))
                {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }

            #[cfg(not(any(
                target_os = "linux",
                target_os = "android",
                target_vendor = "apple",
                target_os = "freebsd",
                target_os = "dragonfly"
            )))]
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "adopted-session termination is unsupported on this Unix target",
            ));

            #[cfg(any(
                target_vendor = "apple",
                target_os = "freebsd",
                target_os = "dragonfly"
            ))]
            Ok(())
        }
    }

    #[derive(Debug)]
    pub(crate) struct AdoptedChild {
        pid: u32,
        process_identity: Option<HandoverProcessIdentity>,
        signal_target: AdoptedSignalTarget,
        reader_cancel: AdoptedReaderCancel,
    }

    impl AdoptedChild {
        pub(crate) fn new(
            pid: u32,
            process_identity: Option<HandoverProcessIdentity>,
            master: &AdoptedMasterPty,
            reader_cancel: AdoptedReaderCancel,
        ) -> io::Result<Self> {
            let (signal_target, process_identity) =
                master.try_clone_signal_target(pid, process_identity)?;
            Ok(Self {
                pid,
                process_identity,
                signal_target,
                reader_cancel,
            })
        }

        pub(crate) fn process_identity(&self) -> Option<HandoverProcessIdentity> {
            self.process_identity
        }
    }

    impl ChildKiller for AdoptedChild {
        fn kill(&mut self) -> std::io::Result<()> {
            self.signal_target.terminate(self.process_identity)?;
            if let Err(error) = self.reader_cancel.cancel() {
                tracing::warn!(
                    ?error,
                    "PTY child terminated, but its adopted reader could not be cancelled explicitly"
                );
            }
            Ok(())
        }

        fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
            Box::new(AdoptedChildKiller {
                pid: self.pid,
                process_identity: self.process_identity,
                signal_target: self.signal_target.clone(),
                reader_cancel: self.reader_cancel.clone(),
            })
        }
    }

    impl Child for AdoptedChild {
        fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
            if let Some(identity) = self.process_identity
                && !handover_process_identity_is_current(identity)
            {
                return Ok(Some(ExitStatus::with_exit_code(0)));
            }
            let res = unsafe { libc::kill(self.pid as libc::pid_t, 0) };
            if res == 0 {
                Ok(None)
            } else {
                let err = std::io::Error::last_os_error();
                if err.raw_os_error() == Some(libc::EPERM) {
                    Ok(None)
                } else {
                    Ok(Some(ExitStatus::with_exit_code(0)))
                }
            }
        }

        fn wait(&mut self) -> std::io::Result<ExitStatus> {
            loop {
                if let Some(status) = self.try_wait()? {
                    return Ok(status);
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
        }

        fn process_id(&self) -> Option<u32> {
            Some(self.pid)
        }
    }

    #[derive(Debug)]
    pub(crate) struct AdoptedChildKiller {
        pid: u32,
        process_identity: Option<HandoverProcessIdentity>,
        signal_target: AdoptedSignalTarget,
        reader_cancel: AdoptedReaderCancel,
    }

    impl ChildKiller for AdoptedChildKiller {
        fn kill(&mut self) -> std::io::Result<()> {
            self.signal_target.terminate(self.process_identity)?;
            if let Err(error) = self.reader_cancel.cancel() {
                tracing::warn!(
                    ?error,
                    "PTY child terminated, but its adopted reader could not be cancelled explicitly"
                );
            }
            Ok(())
        }

        fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
            Box::new(AdoptedChildKiller {
                pid: self.pid,
                process_identity: self.process_identity,
                signal_target: self.signal_target.clone(),
                reader_cancel: self.reader_cancel.clone(),
            })
        }
    }
}

#[cfg(not(unix))]
mod fallback_impl {
    use super::{HandoverClientOutcome, HandoverProcessIdentity, TeardownOutcome};
    use anyhow::{Result, bail};
    use std::path::Path;

    pub(crate) fn handover_process_identity(_pid: u32) -> Option<HandoverProcessIdentity> {
        None
    }

    pub fn perform_handover_client(_socket_path: &Path) -> Result<HandoverClientOutcome> {
        bail!("Process handover is only supported on Unix-like operating systems.");
    }

    pub fn complete_handover_adoption(
        _socket_path: &Path,
        _peer_sends_commit: bool,
    ) -> Result<TeardownOutcome> {
        Ok(TeardownOutcome::Adopt)
    }
}
