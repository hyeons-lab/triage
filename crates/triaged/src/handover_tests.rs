#[cfg(all(unix, test))]
mod tests {
    use crate::session::{SessionManager, SessionManagerConfig};
    use std::path::PathBuf;
    use triage_core::session::{SessionApi, SessionId, SessionSize, StartSessionRequest};

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new() -> std::io::Result<Self> {
            let num: u64 = rand::random();
            let path = std::env::temp_dir().join(format!("triage-test-{}", num));
            std::fs::create_dir_all(&path)?;
            Ok(Self { path })
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn test_zero_downtime_session_serialization_and_adoption() -> anyhow::Result<()> {
        let temp_dir = TempDir::new()?;
        let log_dir = temp_dir.path.clone();
        let config = SessionManagerConfig::new(log_dir.clone());
        let manager = SessionManager::new(config);

        // 1. Spawn a live shell PTY session in the old manager
        let req = StartSessionRequest {
            command: "/bin/sh".to_string(),
            args: vec![
                "-c".to_string(),
                "echo 'triage_handover_test'; sleep 100".to_string(),
            ],
            cwd: Some(std::env::current_dir()?),
            size: SessionSize::default(),
        };
        let session_id = manager.start_session(req)?;

        // Wait a brief moment for some output to be produced and logged
        std::thread::sleep(std::time::Duration::from_millis(150));

        // 2. Set a mock active TCP listener FD
        let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
        use std::os::unix::io::AsRawFd;
        crate::handover::set_active_tcp_listener_fd(listener.as_raw_fd());

        // 3. Serialize live sessions
        let (mut state, fds) = manager.serialize_active_sessions()?;

        // Assertions on the serialized state
        assert_eq!(state.sessions.len(), 1);
        let h_sess = &state.sessions[0];
        assert_eq!(h_sess.id, session_id);
        assert_eq!(h_sess.command, "/bin/sh");
        assert!(h_sess.pid > 0);
        assert!(h_sess.bytes_logged > 0);
        assert_eq!(fds.len(), 1); // 1 PTY master fd

        // 4. Set the has_tcp_listener and active listener fd matching handover.rs
        let dup_tcp = unsafe { libc::dup(listener.as_raw_fd()) };
        assert!(
            dup_tcp >= 0,
            "libc::dup failed: {}",
            std::io::Error::last_os_error()
        );
        let mut fds_to_adopt = vec![dup_tcp];
        fds_to_adopt.extend(fds);
        state.has_tcp_listener = true;

        // 5. Adopt sessions in a brand new manager
        let new_config = SessionManagerConfig::new(log_dir.clone());
        let new_manager = SessionManager::new(new_config);

        // Consume the adopted TCP listener to simulate startup
        *crate::handover::INHERITED_STATE.lock().unwrap() = Some(serde_json::to_string(&state)?);
        *crate::handover::INHERITED_FDS.lock().unwrap() = Some(fds_to_adopt);
        let adopted_listener = crate::handover::take_inherited_tcp_listener();
        assert!(adopted_listener.is_some());

        // Now adopt the sessions
        let inherited_fds = crate::handover::INHERITED_FDS
            .lock()
            .unwrap()
            .take()
            .unwrap();
        new_manager.adopt_sessions(state, inherited_fds)?;

        // 6. Verify adopted session exists and is live!
        let active_sessions = new_manager.list_sessions()?;
        assert_eq!(active_sessions.len(), 1);
        assert_eq!(active_sessions[0], session_id);

        let snap = new_manager.snapshot_session(session_id.clone())?;
        assert!(!snap.exited);
        assert_eq!(snap.size, SessionSize::default());

        // Verify that replayed scrollback contains the output of the session!
        let rows = snap.styled_rows;
        let mut found_test_output = false;
        for row in rows {
            for span in row.spans {
                if span.text.contains("triage_handover_test") {
                    found_test_output = true;
                    break;
                }
            }
            if found_test_output {
                break;
            }
        }
        assert!(
            found_test_output,
            "adopted session failed to replay log state correctly"
        );

        // Simulate the old daemon's handover teardown. It must DETACH (not kill)
        // so the shared child survives into the successor; sending the actors a
        // shutdown here would SIGKILL the child and exit the adopted session —
        // that was the "handover tears down every session" bug.
        manager.detach_all_live_sessions();
        let snap_after = new_manager.snapshot_session(session_id.clone())?;
        assert!(
            !snap_after.exited,
            "adopted session was killed by the old daemon's handover teardown"
        );

        // Clean up the running process (now solely owned via the adopted fd).
        let _ = new_manager.shutdown_session(session_id);

        Ok(())
    }

    /// A descriptor handed to the code under test, whose closure can be
    /// observed reliably from inside a parallel test binary.
    ///
    /// Two simpler probes both give wrong answers here:
    ///
    /// - `fcntl(F_GETFD)` alone cannot tell "never closed" from "closed, and the
    ///   number already reissued". Descriptors are recycled immediately, and
    ///   tests share one process, so this reported a correctly-closed fd as open.
    /// - A pipe's EOF cannot be trusted either: other tests in this binary
    ///   `start_session`, and the children they fork inherit a copy of the write
    ///   end, so the read end keeps reporting "writer alive" no matter what this
    ///   process did with its own copy.
    ///
    /// Identify the descriptor instead. A fresh temp file has an inode nothing
    /// else shares, so afterwards "the number is gone" and "the number now
    /// points at something else" both mean our fd was closed — and neither
    /// depends on what other threads or forked children are doing.
    struct FdProbe {
        fd: std::os::unix::io::RawFd,
        dev: u64,
        ino: u64,
    }

    impl FdProbe {
        fn new(dir: &std::path::Path, name: &str) -> std::io::Result<Self> {
            use std::os::unix::io::IntoRawFd;
            let file = std::fs::File::create(dir.join(name))?;
            let fd = file.into_raw_fd();
            let (dev, ino) = Self::identity(fd).ok_or_else(std::io::Error::last_os_error)?;
            Ok(Self { fd, dev, ino })
        }

        fn identity(fd: std::os::unix::io::RawFd) -> Option<(u64, u64)> {
            let mut st: libc::stat = unsafe { std::mem::zeroed() };
            if unsafe { libc::fstat(fd, &mut st) } != 0 {
                return None;
            }
            Some((st.st_dev as u64, st.st_ino as u64))
        }

        /// True once this descriptor no longer refers to the file it was opened
        /// on — either closed outright, or closed and the number reissued.
        fn is_closed(&self) -> bool {
            match Self::identity(self.fd) {
                None => true,
                Some(identity) => identity != (self.dev, self.ino),
            }
        }
    }

    // The descriptors `UnadoptedFds` closes are the ones no session ever took.
    // Once a session takes one it belongs to that session's master, and nothing
    // used to close it: the reader and writer are `dup`s that close themselves,
    // while the master held a bare `RawFd`. So every adopted session that ended
    // leaked its master — and since a handover re-adopts *every* session, one swap
    // makes that true of the whole set.
    //
    // Tested on the type directly rather than through a live session: a PTY master
    // cannot be identified the way `FdProbe` identifies a descriptor, because every
    // `/dev/ptmx` clone reports the same inode, so "closed and the number reissued
    // to another master" would be indistinguishable from "still open".
    #[test]
    fn adopted_master_closes_its_fd_on_drop() -> anyhow::Result<()> {
        let temp_dir = TempDir::new()?;
        let probe = FdProbe::new(&temp_dir.path, "adopted-master")?;
        assert!(!probe.is_closed(), "probe should start open");

        {
            // SAFETY: the probe hands its descriptor over and does not close it.
            let _master = unsafe { crate::handover::AdoptedMasterPty::from_raw_fd(probe.fd) };
        }

        assert!(
            probe.is_closed(),
            "AdoptedMasterPty did not close its descriptor on drop — an adopted \
             session would leak its PTY master every time one ends"
        );
        Ok(())
    }

    // A partial adoption is logged and survived rather than propagated into a
    // process exit, so the OS no longer sweeps up descriptors the adoption never
    // claimed. Any fd with no session to take it has to be closed on the way out
    // or it leaks for the life of the daemon.
    #[test]
    fn adopt_sessions_closes_fds_no_session_claims() -> anyhow::Result<()> {
        let temp_dir = TempDir::new()?;
        let manager = SessionManager::new(SessionManagerConfig::new(temp_dir.path.clone()));

        let surplus = FdProbe::new(&temp_dir.path, "surplus")?;
        assert!(!surplus.is_closed(), "probe should start open");

        // No sessions to adopt, so nothing claims the fd.
        let state = crate::handover::HandoverState {
            sessions: Vec::new(),
            has_tcp_listener: false,
            sends_teardown_commit: true,
        };
        manager.adopt_sessions(state, vec![surplus.fd])?;

        assert!(
            surplus.is_closed(),
            "a handover fd that no session adopted was left open"
        );
        Ok(())
    }

    // The same guarantee on the failure path. A session whose log can't be opened
    // fails inside `spawn_adopted_pty_runtime`, after its fd has been taken but
    // before any session owns it — the case that used to `?` straight out to a
    // process exit. Both that fd and everything queued behind it must be closed.
    #[test]
    fn adopt_sessions_closes_fds_when_adoption_fails() -> anyhow::Result<()> {
        let temp_dir = TempDir::new()?;
        let manager = SessionManager::new(SessionManagerConfig::new(temp_dir.path.clone()));

        let in_flight = FdProbe::new(&temp_dir.path, "in-flight")?;
        let queued = FdProbe::new(&temp_dir.path, "queued")?;

        // `log_path` points at a directory, so opening it for append fails and
        // the first session never becomes live.
        let session = crate::handover::HandoverSession {
            id: SessionId::new("session-1")?,
            command: "/bin/sh".to_string(),
            args: Vec::new(),
            cwd: Some(temp_dir.path.clone()),
            size: SessionSize::default(),
            log_path: temp_dir.path.clone(),
            output_seq: 0,
            bytes_logged: 0,
            pid: 1,
        };
        let state = crate::handover::HandoverState {
            sessions: vec![session.clone(), session],
            has_tcp_listener: false,
            sends_teardown_commit: true,
        };

        let result = manager.adopt_sessions(state, vec![in_flight.fd, queued.fd]);
        assert!(result.is_err(), "adoption should fail on an unopenable log");
        assert!(
            in_flight.is_closed(),
            "the fd of the session that failed to adopt was left open"
        );
        assert!(
            queued.is_closed(),
            "a queued handover fd was left open after adoption failed"
        );
        Ok(())
    }

    // The two-process Phase-3 handshake (complete_handover_adoption /
    // handle_handover_server) can't be exercised in-process — it does socket I/O
    // between two daemons and ends in process::exit. The adopt-vs-refuse decision
    // is factored into `teardown_outcome` precisely so its contract is testable
    // here without that dance.
    use crate::handover::{TeardownOutcome, TeardownSignal, teardown_outcome};

    #[test]
    fn commit_byte_always_adopts() {
        // 0x03 is the explicit teardown-commit: adopt regardless of what the peer
        // announced (a peer that sends the byte obviously supports it).
        let signal = TeardownSignal::Byte(0x03);
        assert_eq!(teardown_outcome(true, signal), TeardownOutcome::Adopt);
        assert_eq!(teardown_outcome(false, signal), TeardownOutcome::Adopt);
    }

    #[test]
    fn done_byte_always_adopts() {
        // 0x02 is a clean teardown from a daemon predating the commit byte; it
        // detached before sending, so adopt.
        let signal = TeardownSignal::Byte(0x02);
        assert_eq!(teardown_outcome(true, signal), TeardownOutcome::Adopt);
        assert_eq!(teardown_outcome(false, signal), TeardownOutcome::Adopt);
    }

    #[test]
    fn eof_from_a_living_committing_peer_refuses() {
        // The peer announced it commits before detaching, closed the connection
        // without sending the byte, and is still serving: it aborted and still
        // owns its sessions. Adopting would put a second destructive reader on
        // each master — refuse.
        assert_eq!(
            teardown_outcome(true, TeardownSignal::Eof { peer_alive: true }),
            TeardownOutcome::Refuse
        );
    }

    #[test]
    fn eof_from_a_dead_peer_always_adopts() {
        // The peer died mid-handover (e.g. `launchctl kickstart -k` on a swap that
        // looked stuck). Its descriptors died with it, so this process holds the
        // only handles left and refusing would destroy sessions that are still
        // alive. Adopt regardless of what it announced.
        assert_eq!(
            teardown_outcome(true, TeardownSignal::Eof { peer_alive: false }),
            TeardownOutcome::Adopt
        );
        assert_eq!(
            teardown_outcome(false, TeardownSignal::Eof { peer_alive: false }),
            TeardownOutcome::Adopt
        );
    }

    #[test]
    fn eof_from_legacy_peer_adopts() {
        // An older daemon that never announces the commit byte: EOF cannot tell an
        // abort from a lost 0x02, and refusing would strand a real handover, so
        // adopt — the historical behavior we must preserve for old peers.
        assert_eq!(
            teardown_outcome(false, TeardownSignal::Eof { peer_alive: true }),
            TeardownOutcome::Adopt
        );
    }

    #[test]
    fn timeout_always_adopts_even_from_a_committing_peer() {
        // The distinction that matters most: unlike EOF, a timeout leaves the peer
        // connected and able to commit. Its detach is gated only on its own
        // commit-byte write, so refusing here would exit the successor and orphan
        // every session the moment that write lands late. Adopt in both cases.
        assert_eq!(
            teardown_outcome(true, TeardownSignal::Timeout),
            TeardownOutcome::Adopt
        );
        assert_eq!(
            teardown_outcome(false, TeardownSignal::Timeout),
            TeardownOutcome::Adopt
        );
    }

    #[test]
    fn stray_byte_follows_the_eof_rule() {
        // An unexpected byte is treated like no commit byte: refuse only when the
        // peer claimed it would commit, adopt otherwise.
        let signal = TeardownSignal::Byte(0x7f);
        assert_eq!(teardown_outcome(true, signal), TeardownOutcome::Refuse);
        assert_eq!(teardown_outcome(false, signal), TeardownOutcome::Adopt);
    }
}
