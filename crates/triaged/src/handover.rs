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
}

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
/// - Expiring early makes the successor read masters the outgoing daemon may
///   still be reading. PTY reads are destructive, so two readers split a
///   session's output arbitrarily between them.
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

    pub fn perform_handover_client(socket_path: &Path) -> Result<()> {
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

        Ok(())
    }

    pub fn complete_handover_adoption() -> Result<()> {
        let stream = HANDOVER_STREAM.lock().unwrap().take();
        if let Some(mut stream) = stream {
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
            tracing::info!(gap_ms, "Completing handover adoption (Phase 2 sync)...");
            stream
                .write_all(&[0x01])
                .context("writing adoption sync byte (0x01) to old daemon")?;
            stream.flush().context("flushing adoption sync byte")?;

            tracing::info!("Waiting for old daemon teardown (Phase 3 sync)...");
            stream.set_read_timeout(Some(HANDOVER_TEARDOWN_TIMEOUT))?;
            let mut sync_byte = [0u8; 1];
            if let Err(err) = stream.read_exact(&mut sync_byte) {
                // Proceed even on EOF, deliberately. EOF is ambiguous: the
                // outgoing daemon may have aborted before detaching (it still
                // owns these sessions, and adopting adds a second destructive
                // reader on each master), or it may have detached and exited
                // with its 0x02 lost — the teardown path treats that write as
                // best-effort precisely so a drained daemon still exits.
                //
                // Those call for opposite responses and the byte stream cannot
                // tell them apart, so this resolves toward adopting: the first
                // case corrupts output on a daemon the operator can restart,
                // while refusing in the second strands every live session with
                // no daemon owning it, which nothing can recover.
                tracing::warn!(
                    "Failed to read teardown sync byte (0x02) from old daemon, proceeding anyway: {err}"
                );
            } else if sync_byte[0] != 0x02 {
                tracing::warn!(
                    "Unexpected sync byte from old daemon: {:02x}, proceeding anyway",
                    sync_byte[0]
                );
            } else {
                tracing::info!("Old daemon successfully shut down.");
            }
        }
        Ok(())
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
