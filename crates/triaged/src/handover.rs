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

        Ok(())
    }

    pub fn complete_handover_adoption() -> Result<()> {
        let stream = HANDOVER_STREAM.lock().unwrap().take();
        if let Some(mut stream) = stream {
            tracing::info!("Completing handover adoption (Phase 2 sync)...");
            stream
                .write_all(&[0x01])
                .context("writing adoption sync byte (0x01) to old daemon")?;
            stream.flush().context("flushing adoption sync byte")?;

            tracing::info!("Waiting for old daemon teardown (Phase 3 sync)...");
            stream.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
            let mut sync_byte = [0u8; 1];
            if let Err(err) = stream.read_exact(&mut sync_byte) {
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
