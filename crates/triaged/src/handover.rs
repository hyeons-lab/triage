use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use triage_core::session::{SessionId, SessionSize};

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
    /// `peer_alive` records whether the daemon was still accepting on its IPC
    /// socket afterwards, which is the only thing that separates the two very
    /// different causes of this: a daemon that *aborted* its handover closes this
    /// connection and keeps serving, while one that was killed mid-handover
    /// closes it by dying. They demand opposite responses — see
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
/// - `Timeout` — always adopt, whatever the peer announced. The peer is still
///   connected, and its detach is gated only on *its own* commit-byte write
///   succeeding, never on the successor still being there. So refusing (and
///   exiting) on a slow peer loses every session the moment that write lands a
///   little late: the outgoing daemon detaches and exits into a successor that
///   is already gone. Adopting risks at worst a second reader on a daemon an
///   operator can restart; refusing risks unrecoverable loss.
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
        // A live-but-slow peer must never be refused: see the doc above.
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

/// How long the outgoing daemon waits in Phase 2 for its successor's `0x01`
/// adoption byte before giving up and keeping its sessions.
///
/// Deliberately generous. A successor that *dies* closes the socket, and the
/// outgoing daemon's read then fails with EOF immediately — death does not
/// depend on this deadline. It only fires for a successor that is alive but
/// slow to finish starting up, and aborting that handover is strictly worse
/// than waiting: the swap is stranded and the operator is forced into a hard
/// restart that kills every live session. The bound exists solely so a wedged
/// successor cannot pin the outgoing daemon forever.
///
/// Measured successor startup was ~9s in June and ~22.6s by July, so the 5s
/// this replaced had no headroom and was aborting valid handovers.
pub const HANDOVER_ADOPTION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

/// How long the successor waits in Phase 3 for the outgoing daemon's `0x02`
/// teardown byte before starting its own PTY readers anyway.
///
/// Separate from [`HANDOVER_ADOPTION_TIMEOUT`] because it bounds a different
/// wait — post-adoption teardown, not process startup — so the startup
/// measurements above do not justify its value. It is also the one deadline
/// with a cost on *both* sides, which is why it is not simply generous:
///
/// - Expiring early makes the successor adopt (see [`teardown_outcome`]) and
///   start reading masters the outgoing daemon is still reading. PTY reads are
///   destructive, so two readers split a session's output arbitrarily between
///   them.
///
///   Note what actually ends that overlap: not this byte, and not the commit
///   byte. `SessionActor::detach` only drops the reader/worker join handles — it
///   deliberately never signals shutdown, so those threads keep draining the
///   masters until the outgoing daemon's `process::exit`. The teardown bytes
///   bound how long the successor *waits*; the old daemon's exit is what makes
///   the handoff exclusive. Keeping that window short is therefore about
///   reaching that exit promptly, not about the handshake.
/// - Expiring late leaves the system dark. By this point the successor has
///   adopted the TCP listener but has not started serving, and the outgoing
///   daemon has drained its sessions, so no process answers clients until the
///   wait ends.
///
/// Teardown is a detach-and-exit that should take milliseconds; only a wedged
/// outgoing daemon reaches this deadline at all. So this is set well above
/// normal teardown but well below the startup-sized bound above, capping the
/// dark window rather than optimising for the pathological case.
pub const HANDOVER_TEARDOWN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

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
    use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
    use std::os::unix::net::UnixStream;
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicI32, Ordering};
    use std::time::Instant;

    pub fn send_fds(socket: &UnixStream, fds: &[RawFd], data: &[u8]) -> io::Result<()> {
        let fd = socket.as_raw_fd();

        let len_prefix = (data.len() as u32).to_be_bytes();
        let mut iov = iovec {
            iov_base: len_prefix.as_ptr() as *mut libc::c_void,
            iov_len: len_prefix.len(),
        };

        let fds_size = std::mem::size_of_val(fds);
        let cmsg_space = unsafe { libc::CMSG_SPACE(fds_size as u32) } as usize;
        let mut control_buf = vec![0u8; cmsg_space];

        let mut msg = msghdr {
            msg_name: std::ptr::null_mut(),
            msg_namelen: 0,
            msg_iov: &mut iov as *mut iovec,
            msg_iovlen: 1,
            msg_control: control_buf.as_mut_ptr() as *mut libc::c_void,
            msg_controllen: control_buf.len() as _,
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

        if bytes_sent as usize != len_prefix.len() {
            return Err(io::Error::other(
                "sendmsg failed to send the entire length prefix",
            ));
        }

        let mut writer = socket.try_clone()?;
        writer.write_all(data)?;
        writer.flush()?;

        Ok(())
    }

    pub fn recv_fds(socket: &UnixStream, max_fds: usize) -> io::Result<(Vec<u8>, Vec<RawFd>)> {
        let fd = socket.as_raw_fd();

        let mut len_prefix = [0u8; 4];
        let mut iov = iovec {
            iov_base: len_prefix.as_mut_ptr() as *mut libc::c_void,
            iov_len: len_prefix.len(),
        };

        let fds_size = max_fds * std::mem::size_of::<RawFd>();
        let cmsg_space = unsafe { libc::CMSG_SPACE(fds_size as u32) } as usize;
        let mut control_buf = vec![0u8; cmsg_space];

        let mut msg = msghdr {
            msg_name: std::ptr::null_mut(),
            msg_namelen: 0,
            msg_iov: &mut iov as *mut iovec,
            msg_iovlen: 1,
            msg_control: control_buf.as_mut_ptr() as *mut libc::c_void,
            msg_controllen: control_buf.len() as _,
            msg_flags: 0,
        };

        let bytes_received = unsafe { recvmsg(fd, &mut msg, 0) };
        if bytes_received < 0 {
            return Err(io::Error::last_os_error());
        }

        if bytes_received as usize != len_prefix.len() {
            return Err(io::Error::other(
                "recvmsg failed to read the entire 4-byte length prefix",
            ));
        }

        let mut received_fds = Vec::new();
        unsafe {
            let cmsg = CMSG_FIRSTHDR(&msg);
            if !cmsg.is_null()
                && (*cmsg).cmsg_level == SOL_SOCKET
                && (*cmsg).cmsg_type == SCM_RIGHTS
            {
                let len = (*cmsg).cmsg_len as usize - libc::CMSG_LEN(0) as usize;
                let fd_count = len / std::mem::size_of::<RawFd>();
                if fd_count > 0 {
                    received_fds.reserve(fd_count);
                    let data_ptr = CMSG_DATA(cmsg) as *const RawFd;
                    std::ptr::copy_nonoverlapping(data_ptr, received_fds.as_mut_ptr(), fd_count);
                    received_fds.set_len(fd_count);
                }
            }
        }

        let data_len = u32::from_be_bytes(len_prefix) as usize;
        let mut data_buf = vec![0u8; data_len];

        let mut reader = socket.try_clone()?;
        reader.read_exact(&mut data_buf)?;

        Ok((data_buf, received_fds))
    }

    pub static INHERITED_FDS: Mutex<Option<Vec<RawFd>>> = Mutex::new(None);
    pub static INHERITED_STATE: Mutex<Option<String>> = Mutex::new(None);
    pub static HANDOVER_STREAM: Mutex<Option<UnixStream>> = Mutex::new(None);
    /// When Phase 1 (state + FD transfer) finished, used to report how long this
    /// successor took to reach Phase 2. The old daemon only waits
    /// `HANDOVER_ADOPTION_TIMEOUT` for that byte, so this gap is what decides
    /// whether a handover succeeds — log it rather than leaving a failure opaque.
    static PHASE1_COMPLETED_AT: Mutex<Option<Instant>> = Mutex::new(None);
    static ACTIVE_TCP_LISTENER_FD: AtomicI32 = AtomicI32::new(-1);

    pub fn set_active_tcp_listener_fd(fd: RawFd) {
        ACTIVE_TCP_LISTENER_FD.store(fd, Ordering::SeqCst);
    }

    pub fn get_active_tcp_listener_fd() -> RawFd {
        ACTIVE_TCP_LISTENER_FD.load(Ordering::SeqCst)
    }

    pub fn take_inherited_tcp_listener() -> Option<TcpListener> {
        let state_guard = INHERITED_STATE.lock().unwrap();
        if let Some(ref state_str) = *state_guard
            && let Ok(state) = serde_json::from_str::<HandoverState>(state_str)
            && state.has_tcp_listener
        {
            let mut fds_guard = INHERITED_FDS.lock().unwrap();
            if let Some(fds) = fds_guard.as_mut()
                && !fds.is_empty()
            {
                let fd = fds.remove(0);
                tracing::info!(fd = fd, "Adopting inherited TCP listener");
                return Some(unsafe { TcpListener::from_raw_fd(fd) });
            }
        }
        None
    }

    pub fn perform_handover_client(socket_path: &Path) -> Result<HandoverClientOutcome> {
        let stream =
            UnixStream::connect(socket_path).context("connecting to running daemon Unix socket")?;
        // On timeout recv_fds returns an error and the caller falls back to a
        // fresh start. complete_handover_adoption sets its own timeout later.
        stream
            .set_read_timeout(Some(HANDOVER_TRANSFER_TIMEOUT))
            .context("setting handover client read timeout")?;

        let request_str = "{\"Handover\":null}\n";
        {
            let mut writer = BufWriter::new(&stream);
            writer
                .write_all(request_str.as_bytes())
                .context("sending Handover request")?;
            writer.flush().context("flushing request buffer")?;
        }

        let (data, fds) =
            recv_fds(&stream, 129).context("receiving handover session descriptors and state")?;

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

        let state_str = serde_json::to_string(state_val)?;

        *INHERITED_FDS.lock().unwrap() = Some(fds);
        *INHERITED_STATE.lock().unwrap() = Some(state_str);
        *HANDOVER_STREAM.lock().unwrap() = Some(stream);
        *PHASE1_COMPLETED_AT
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Instant::now());

        Ok(HandoverClientOutcome::Transferred)
    }

    /// Whether the outgoing daemon is still accepting on its IPC socket.
    ///
    /// After a Phase-3 EOF this is the only thing that separates "aborted but
    /// alive — it kept its sessions, refuse" from "died mid-handover — nothing
    /// owns them, adopt or lose them". A daemon that is killed takes its listener
    /// with it, so the connect is refused; one that merely aborted this handover
    /// is still serving and accepts. Treat any connect error as "gone": the
    /// dangerous mistake is refusing (and destroying sessions) on a false
    /// "alive", not adopting on a false "dead".
    fn peer_still_listening(socket_path: &Path) -> bool {
        UnixStream::connect(socket_path).is_ok()
    }

    /// Send the `0x01` adoption byte and read the outgoing daemon's Phase-3
    /// response, returning whether the successor should adopt or refuse.
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
        let stream = HANDOVER_STREAM.lock().unwrap().take();
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
        // path below — the gap is the single most useful number to have when
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

        // Arm the Phase-3 read deadline *before* writing 0x01. Once that byte
        // lands the outgoing daemon may detach its sessions, so from here on any
        // error must not abort adoption — doing so would strand every session
        // with no daemon owning it. set_read_timeout is a local setsockopt with
        // no effect on the peer, so moving it ahead of the commit is free and
        // removes the one fallible call that used to sit past the point of no
        // return. (A failure on the 0x01 write itself is still fatal-by-`?`, and
        // correctly so: a byte that never left means the outgoing daemon times
        // out and keeps its sessions, so aborting here strands nothing.)
        stream
            .set_read_timeout(Some(HANDOVER_TEARDOWN_TIMEOUT))
            .context("setting teardown read timeout on handover socket")?;
        stream
            .write_all(&[HANDOVER_ADOPT_BYTE])
            .context("writing adoption sync byte (0x01) to old daemon")?;
        stream.flush().context("flushing adoption sync byte")?;

        tracing::info!("Waiting for old daemon teardown (Phase 3 sync)...");
        let mut sync_byte = [0u8; 1];
        // A timeout and a closed socket are NOT interchangeable here. The read
        // deadline is enforced locally via SO_RCVTIMEO, which surfaces as
        // WouldBlock (or TimedOut on some platforms) and leaves the peer
        // connected; anything else means the peer is gone. teardown_outcome
        // resolves them in opposite directions, so the kind must survive.
        let signal = match stream.read_exact(&mut sync_byte) {
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
                // them apart — see `peer_still_listening`.
                let peer_alive = peer_still_listening(socket_path);
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
                // Deliberately adopting a slow peer rather than refusing it — the
                // peer is still connected and its detach is gated only on its own
                // commit-byte write, so refusing here risks orphaning everything.
                tracing::warn!(
                    "Old daemon did not send a teardown byte before the deadline but is still \
                     connected; adopting rather than risk orphaning its sessions if it commits."
                );
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
                // The peer announced it commits before detaching, yet we saw no
                // commit byte — it aborted and still owns its sessions. Adopting
                // would put a second destructive reader on each master.
                tracing::error!(
                    "Old daemon announced a teardown-commit byte but never sent it, so it \
                     aborted the handover and still owns its sessions. Refusing to adopt to \
                     avoid corrupting them."
                );
            }
        }
        Ok(outcome)
    }

    #[derive(Debug)]
    pub struct AdoptedMasterPty {
        pub fd: RawFd,
    }

    impl MasterPty for AdoptedMasterPty {
        fn resize(&self, size: PtySize) -> Result<(), anyhow::Error> {
            let ws = libc::winsize {
                ws_row: size.rows,
                ws_col: size.cols,
                ws_xpixel: size.pixel_width,
                ws_ypixel: size.pixel_height,
            };
            let res = unsafe { libc::ioctl(self.fd, libc::TIOCSWINSZ, &ws) };
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
            let res = unsafe { libc::ioctl(self.fd, libc::TIOCGWINSZ, &mut ws) };
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
            let dup_fd = unsafe { libc::dup(self.fd) };
            if dup_fd < 0 {
                return Err(anyhow::Error::new(std::io::Error::last_os_error()));
            }
            let file = unsafe { std::fs::File::from_raw_fd(dup_fd) };
            Ok(Box::new(file))
        }

        fn take_writer(&self) -> Result<Box<dyn std::io::Write + Send>, anyhow::Error> {
            let dup_fd = unsafe { libc::dup(self.fd) };
            if dup_fd < 0 {
                return Err(anyhow::Error::new(std::io::Error::last_os_error()));
            }
            let file = unsafe { std::fs::File::from_raw_fd(dup_fd) };
            Ok(Box::new(file))
        }

        fn as_raw_fd(&self) -> Option<RawFd> {
            Some(self.fd)
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
            self.fd
        }
    }

    // Deliberately no `Drop`: closing here would change when a *live* adopted
    // session's master closes, since `SessionActor::detach` drops the actor's
    // command sender and `run_actor` then unwinds its state before the daemon
    // exits. Descriptors that never reach a session are closed by `UnadoptedFds`
    // in `adopt_sessions` instead, which owns the queue until each session is
    // live and so covers the in-flight fd too.

    #[derive(Debug)]
    pub struct AdoptedChild {
        pub pid: u32,
    }

    impl ChildKiller for AdoptedChild {
        fn kill(&mut self) -> std::io::Result<()> {
            let res = unsafe { libc::kill(self.pid as libc::pid_t, libc::SIGKILL) };
            if res < 0 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(())
            }
        }

        fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
            Box::new(AdoptedChildKiller { pid: self.pid })
        }
    }

    impl Child for AdoptedChild {
        fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
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
    pub struct AdoptedChildKiller {
        pub pid: u32,
    }

    impl ChildKiller for AdoptedChildKiller {
        fn kill(&mut self) -> std::io::Result<()> {
            let res = unsafe { libc::kill(self.pid as libc::pid_t, libc::SIGKILL) };
            if res < 0 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(())
            }
        }

        fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
            Box::new(AdoptedChildKiller { pid: self.pid })
        }
    }
}

#[cfg(not(unix))]
mod fallback_impl {
    use anyhow::{Result, bail};
    use std::path::Path;

    pub fn perform_handover_client(_socket_path: &Path) -> Result<()> {
        bail!("Process handover is only supported on Unix-like operating systems.");
    }

    pub fn complete_handover_adoption() -> Result<()> {
        Ok(())
    }
}
