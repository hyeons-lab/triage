#[cfg(all(unix, test))]
mod tests {
    use crate::session::{SessionManager, SessionManagerConfig};
    use std::path::PathBuf;
    use std::sync::{Mutex, MutexGuard, OnceLock};
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

    fn handover_state_lock() -> MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[test]
    fn descriptor_transfer_chunks_above_the_single_message_limit() -> anyhow::Result<()> {
        use std::os::fd::AsRawFd;
        use std::os::unix::net::UnixStream;

        let (sender, receiver) = UnixStream::pair()?;
        let file = std::fs::File::open("/dev/null")?;
        let raw_fds = vec![file.as_raw_fd(); crate::handover::MAX_HANDOVER_FDS + 1];
        let payload = vec![b'x'; 256 * 1024];
        let send = std::thread::spawn(move || {
            let result = crate::handover::send_handover_fds(&sender, &raw_fds, &payload);
            drop(file);
            result
        });

        let (data, mut received) =
            crate::handover::recv_fds_guarded(&receiver, crate::handover::MAX_HANDOVER_FDS)?;
        assert_eq!(data.len(), 256 * 1024);
        assert!(data.iter().all(|byte| *byte == b'x'));
        assert_eq!(
            received.len(),
            crate::handover::MAX_FDS_PER_SEND,
            "the legacy first recvmsg must carry a complete legacy-sized FD prefix"
        );
        crate::handover::recv_remaining_fds(
            &receiver,
            crate::handover::MAX_HANDOVER_FDS + 1,
            &mut received,
        )?;
        assert_eq!(received.len(), crate::handover::MAX_HANDOVER_FDS + 1);
        send.join().expect("descriptor sender thread")?;
        Ok(())
    }

    #[test]
    fn public_descriptor_helpers_round_trip_one_message() -> anyhow::Result<()> {
        use std::os::fd::AsRawFd;
        use std::os::unix::net::UnixStream;

        let (sender, receiver) = UnixStream::pair()?;
        let file = std::fs::File::open("/dev/null")?;
        let raw_fds = vec![file.as_raw_fd(); crate::handover::MAX_FDS_PER_SEND + 1];
        let count = raw_fds.len();
        let send = std::thread::spawn(move || crate::handover::send_fds(&sender, &raw_fds, b"ok"));
        let (data, fds) = crate::handover::recv_fds(&receiver, count)?;
        send.join().expect("descriptor sender thread")?;
        assert_eq!(data, b"ok");
        assert_eq!(fds.len(), count);
        for fd in fds {
            // SAFETY: recv_fds transfers ownership of every returned descriptor.
            unsafe { libc::close(fd) };
        }
        Ok(())
    }

    #[test]
    fn descriptor_receivers_reject_oversized_state_before_allocating() -> anyhow::Result<()> {
        use std::io::Write;
        use std::os::unix::net::UnixStream;

        let oversized = (crate::handover::MAX_HANDOVER_STATE_BYTES + 1) as u32;

        let (mut sender, receiver) = UnixStream::pair()?;
        sender.write_all(&oversized.to_be_bytes())?;
        let error = crate::handover::recv_data_frame(&receiver)
            .expect_err("metadata-only receiver accepted an oversized state frame");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);

        let (mut sender, receiver) = UnixStream::pair()?;
        sender.write_all(&oversized.to_be_bytes())?;
        let error = match crate::handover::recv_fds_guarded(&receiver, 1) {
            Ok(_) => panic!("descriptor receiver accepted an oversized state frame"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        Ok(())
    }

    #[test]
    fn failed_recovery_log_reservation_does_not_change_session_identity() -> anyhow::Result<()> {
        let temp_dir = TempDir::new()?;
        let mut session = crate::handover::HandoverSession {
            id: SessionId::new("session-1")?,
            command: "/bin/sh".to_string(),
            args: Vec::new(),
            cwd: None,
            size: SessionSize::default(),
            log_path: temp_dir.path.join("missing").join("session-1.log"),
            output_seq: 0,
            bytes_logged: 0,
            pid: 42,
            process_identity: None,
            last_activity_ms: 0,
            judge_override: None,
        };
        let original = session.clone();

        assert!(
            crate::handover::rename_recovered_session(&mut session, |_| false).is_err(),
            "reservation unexpectedly succeeded in a missing directory"
        );
        assert_eq!(session.id, original.id);
        assert_eq!(session.log_path, original.log_path);
        Ok(())
    }

    #[test]
    fn interrupted_descriptor_chunks_preserve_the_mapped_prefix() -> anyhow::Result<()> {
        use std::io::{BufRead, BufReader};
        use std::os::fd::AsRawFd;
        use std::os::unix::net::UnixListener;

        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        let socket_path = temp_dir.path.join("partial.sock");
        let listener = UnixListener::bind(&socket_path)?;
        let sessions = (0..crate::handover::MAX_FDS_PER_SEND + 1)
            .map(|index| crate::handover::HandoverSession {
                id: SessionId::new(format!("session-{}", index + 1)).unwrap(),
                command: "/bin/sh".to_string(),
                args: Vec::new(),
                cwd: None,
                size: SessionSize::default(),
                log_path: temp_dir.path.join(format!("session-{}.log", index + 1)),
                output_seq: 0,
                bytes_logged: 0,
                pid: 10_000 + index as u32,
                process_identity: None,
                last_activity_ms: 0,
                judge_override: None,
            })
            .collect();
        let state = crate::handover::HandoverState {
            sessions,
            has_tcp_listener: false,
            sends_teardown_commit: true,
            handover_owner_token: Some([4; 16]),
            handover_lineage_token: Some([5; 16]),
        };
        let response = serde_json::json!({"Ok": {"HandoverState": state}});
        let response = serde_json::to_vec(&response)?;
        let server = std::thread::spawn(move || -> std::io::Result<()> {
            let (stream, _) = listener.accept()?;
            let mut request = String::new();
            BufReader::new(stream.try_clone()?).read_line(&mut request)?;
            assert!(request.contains("HandoverV2"));
            let file = std::fs::File::open("/dev/null")?;
            let raw_fds = vec![file.as_raw_fd(); crate::handover::MAX_FDS_PER_SEND];
            crate::handover::send_data_frame(&stream, &response)?;
            crate::handover::send_fd_chunks(&stream, &raw_fds)
        });

        assert_eq!(
            crate::handover::perform_handover_client(&socket_path)?,
            crate::handover::HandoverClientOutcome::Transferred
        );
        server.join().expect("partial handover server")?;
        let state: crate::handover::HandoverState = serde_json::from_str(
            &crate::handover::INHERITED_STATE
                .lock()
                .unwrap()
                .take()
                .expect("retained partial state"),
        )?;
        assert_eq!(state.sessions.len(), crate::handover::MAX_FDS_PER_SEND);
        let retained = crate::handover::INHERITED_FDS
            .lock()
            .unwrap()
            .take()
            .expect("retained partial descriptors");
        assert_eq!(retained.len(), crate::handover::MAX_FDS_PER_SEND);
        for fd in retained {
            // SAFETY: the test owns every descriptor removed from INHERITED_FDS.
            unsafe { libc::close(fd) };
        }
        crate::handover::finish_handover_adoption();
        Ok(())
    }

    #[test]
    fn completed_descriptor_transfer_survives_readiness_failure() -> anyhow::Result<()> {
        use std::io::{BufRead, BufReader};
        use std::os::fd::AsRawFd;
        use std::os::unix::net::UnixListener;

        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        let socket_path = temp_dir.path.join("ready-failure.sock");
        let listener = UnixListener::bind(&socket_path)?;
        let state = crate::handover::HandoverState {
            sessions: vec![crate::handover::HandoverSession {
                id: SessionId::new("session-1")?,
                command: "/bin/sh".to_string(),
                args: Vec::new(),
                cwd: None,
                size: SessionSize::default(),
                log_path: temp_dir.path.join("session-1.log"),
                output_seq: 0,
                bytes_logged: 0,
                pid: 10_000,
                process_identity: None,
                last_activity_ms: 0,
                judge_override: None,
            }],
            has_tcp_listener: false,
            sends_teardown_commit: true,
            handover_owner_token: Some([4; 16]),
            handover_lineage_token: Some([5; 16]),
        };
        let response = serde_json::to_vec(&serde_json::json!({
            "Ok": {"HandoverState": state}
        }))?;
        let server = std::thread::spawn(move || -> std::io::Result<()> {
            let (stream, _) = listener.accept()?;
            let mut request = String::new();
            BufReader::new(stream.try_clone()?).read_line(&mut request)?;
            assert!(request.contains("HandoverV2"));
            let file = std::fs::File::open("/dev/null")?;
            crate::handover::send_data_frame(&stream, &response)?;
            crate::handover::send_fd_chunks(&stream, &[file.as_raw_fd()])?;
            stream.shutdown(std::net::Shutdown::Both)
        });

        assert_eq!(
            crate::handover::perform_handover_client(&socket_path)?,
            crate::handover::HandoverClientOutcome::Transferred
        );
        server.join().expect("handover server")?;
        assert!(
            crate::handover::INHERITED_STATE
                .lock()
                .unwrap()
                .take()
                .is_some()
        );
        let retained = crate::handover::INHERITED_FDS
            .lock()
            .unwrap()
            .take()
            .expect("retained descriptors");
        assert_eq!(retained.len(), 1);
        for fd in retained {
            // SAFETY: the test owns descriptors removed from INHERITED_FDS.
            unsafe { libc::close(fd) };
        }
        crate::handover::HANDOVER_STREAM.lock().unwrap().take();
        crate::handover::finish_handover_adoption();
        Ok(())
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
                "set -m; trap '' HUP; echo 'triage_handover_test'; \
                 sh -c 'trap \"\" HUP; exec sleep 100'"
                    .to_string(),
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
        // Monitor mode puts the foreground job in its own process group. The
        // adopted shutdown path must terminate both that job and the serialized
        // shell rather than assuming they share a PID/process group.
        let foreground_pid = unsafe { libc::tcgetpgrp(fds[0]) };
        assert!(foreground_pid > 0);
        assert_ne!(foreground_pid as u32, h_sess.pid);
        let foreground_process_identity =
            crate::handover::handover_process_identity(foreground_pid as u32);
        // The session echoed above, so it has a real activity stamp. Captured
        // here to compare after adoption: recency has to survive the swap, or
        // every session lands in the successor looking equally (un)recent and the
        // rail's ordering collapses into one arbitrary tie on the other side of
        // an upgrade.
        let serialized_activity = h_sess.last_activity_ms;
        let adopted_process_identity = h_sess.process_identity;
        assert!(
            serialized_activity > 0,
            "a session that produced output must serialize a real activity stamp"
        );

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

        // Recency carried across the swap rather than being re-stamped.
        let adopted_activity = new_manager
            .list_session_contexts()?
            .into_iter()
            .find(|row| row.session_id == session_id)
            .expect("adopted session in contexts")
            .last_activity_ms;
        assert_eq!(
            adopted_activity, serialized_activity,
            "the adopted session must keep the stamp it was handed over with"
        );

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

        let next_id = new_manager.start_session(StartSessionRequest {
            command: "/bin/sh".to_string(),
            args: vec!["-c".to_string(), "sleep 100".to_string()],
            cwd: Some(std::env::current_dir()?),
            size: SessionSize::default(),
        })?;
        assert_eq!(next_id.as_str(), "session-2");
        let _ = new_manager.shutdown_session(next_id);

        // Clean up the running process (now solely owned via the adopted fd).
        new_manager.shutdown_session(session_id)?;
        if let Some(adopted_process_identity) = adopted_process_identity {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
            while crate::handover::handover_process_identity(adopted_process_identity.pid)
                == Some(adopted_process_identity)
                && std::time::Instant::now() < deadline
            {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            assert_ne!(
                crate::handover::handover_process_identity(adopted_process_identity.pid),
                Some(adopted_process_identity),
                "shutting down an adopted session must terminate its original child"
            );
        }
        if let Some(foreground_process_identity) = foreground_process_identity {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
            while crate::handover::handover_process_identity(foreground_process_identity.pid)
                == Some(foreground_process_identity)
                && std::time::Instant::now() < deadline
            {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            assert_ne!(
                crate::handover::handover_process_identity(foreground_process_identity.pid),
                Some(foreground_process_identity),
                "shutting down an adopted session must terminate its foreground job"
            );
        }

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
            handover_owner_token: None,
            handover_lineage_token: None,
        };
        manager.adopt_sessions(state, vec![surplus.fd])?;

        assert!(
            surplus.is_closed(),
            "a handover fd that no session adopted was left open"
        );
        Ok(())
    }

    // Once the predecessor has committed, a failed adoption must retain both the
    // descriptor for that session and every later descriptor. They are the only
    // remaining PTY masters and must survive for a background retry.
    #[test]
    fn adopt_sessions_retains_fds_when_adoption_fails() -> anyhow::Result<()> {
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
            process_identity: None,
            last_activity_ms: 0,
            judge_override: None,
        };
        let state = crate::handover::HandoverState {
            sessions: vec![session.clone(), session],
            has_tcp_listener: false,
            sends_teardown_commit: true,
            handover_owner_token: None,
            handover_lineage_token: None,
        };

        let result = manager.adopt_sessions(state, vec![in_flight.fd, queued.fd]);
        assert!(result.is_err(), "adoption should fail on an unopenable log");
        assert!(
            !in_flight.is_closed(),
            "the fd of the session that failed to adopt was closed"
        );
        assert!(
            !queued.is_closed(),
            "a later handover fd was closed after an earlier adoption failed"
        );
        assert_eq!(
            manager.try_live_session_count(),
            Some(2),
            "shutdown rescue did not count the retained sessions"
        );
        let shutdown_error = manager
            .shutdown_session(SessionId::new("session-1")?)
            .expect_err("a retained live PTY must not be shut down as historical");
        assert!(
            shutdown_error
                .to_string()
                .contains("awaiting inherited PTY adoption"),
            "unexpected pending shutdown error: {shutdown_error:#}"
        );
        let restore_error = manager
            .restore_session(triage_core::session::RestoreSessionRequest {
                session_id: SessionId::new("session-1")?,
                size: SessionSize::default(),
            })
            .expect_err("a retained live PTY must not be restored as historical");
        assert!(
            restore_error
                .to_string()
                .contains("awaiting inherited PTY adoption"),
            "unexpected pending restore error: {restore_error:#}"
        );
        let handover = manager
            .begin_handover()
            .expect("retained sessions should be transferable to another daemon");
        let (transfer, transfer_fds) = manager.serialize_active_sessions()?;
        assert_eq!(transfer.sessions.len(), 2);
        assert_eq!(transfer_fds.len(), 2);
        for fd in transfer_fds {
            unsafe { libc::close(fd) };
        }
        drop(handover);

        let retained = manager.take_pending_adoption_fds_for_test();
        assert_eq!(retained.len(), 2);
        for fd in retained {
            unsafe { libc::close(fd) };
        }
        assert!(in_flight.is_closed());
        assert!(queued.is_closed());
        Ok(())
    }

    #[test]
    fn recovery_handover_merges_new_and_reused_session_ids() -> anyhow::Result<()> {
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        crate::handover::remember_handover_peer_token(None);

        let session = |id: &str, pid: u32| -> anyhow::Result<crate::handover::HandoverSession> {
            Ok(crate::handover::HandoverSession {
                id: SessionId::new(id)?,
                command: "/bin/sh".to_string(),
                args: Vec::new(),
                cwd: None,
                size: SessionSize::default(),
                log_path: temp_dir.path.join(format!("{id}-{pid}.log")),
                output_seq: 0,
                bytes_logged: 0,
                pid,
                process_identity: Some(crate::handover::HandoverProcessIdentity {
                    pid,
                    started_at: [u64::from(pid), 0],
                }),
                last_activity_ms: 0,
                judge_override: None,
            })
        };

        let old_replaced = FdProbe::new(&temp_dir.path, "old-replaced")?;
        let old_retained = FdProbe::new(&temp_dir.path, "old-retained")?;
        let fresh_replacement = FdProbe::new(&temp_dir.path, "fresh-replacement")?;
        let reused_id = FdProbe::new(&temp_dir.path, "reused-id")?;
        let refreshed_reused_id = FdProbe::new(&temp_dir.path, "refreshed-reused-id")?;
        let new_session = FdProbe::new(&temp_dir.path, "new-session")?;

        let mut state = crate::handover::HandoverState {
            sessions: vec![session("session-1", 10)?, session("session-2", 20)?],
            has_tcp_listener: false,
            sends_teardown_commit: true,
            handover_owner_token: Some([1; 16]),
            handover_lineage_token: Some([1; 16]),
        };
        let mut fds = vec![old_replaced.fd, old_retained.fd];
        let recovered = crate::handover::HandoverState {
            sessions: vec![
                session("session-1", 10)?,
                session("session-2", 99)?,
                session("session-3", 30)?,
            ],
            has_tcp_listener: false,
            sends_teardown_commit: true,
            handover_owner_token: Some([2; 16]),
            handover_lineage_token: Some([2; 16]),
        };
        crate::handover::remember_recovered_handover_for_test(
            recovered,
            vec![fresh_replacement.fd, reused_id.fd, new_session.fd],
        );
        std::fs::write(temp_dir.path.join("session-2-99.log"), b"recovered history")?;
        let protected_log = temp_dir.path.join("session-2-recovered-99.log");
        std::fs::write(&protected_log, b"unrelated persisted history")?;

        crate::handover::merge_recovered_handovers(&mut state, &mut fds);
        assert!(!reused_id.is_closed());

        // A later recovery pass still identifies the child by process birth,
        // even though the first pass renamed its colliding display ID.
        crate::handover::remember_recovered_handover_for_test(
            crate::handover::HandoverState {
                sessions: vec![session("session-2", 99)?],
                has_tcp_listener: false,
                sends_teardown_commit: true,
                handover_owner_token: Some([3; 16]),
                handover_lineage_token: Some([3; 16]),
            },
            vec![refreshed_reused_id.fd],
        );
        crate::handover::merge_recovered_handovers(&mut state, &mut fds);

        assert!(old_replaced.is_closed(), "the stale duplicate must close");
        assert_eq!(state.sessions.len(), 4);
        assert_eq!(fds.len(), 4);
        assert!(
            state
                .sessions
                .iter()
                .any(|entry| entry.id.as_str() == "session-2-recovered-99-2" && entry.pid == 99),
            "a reused display id must not overwrite a different live child"
        );
        let renamed = state
            .sessions
            .iter()
            .find(|entry| entry.id.as_str() == "session-2-recovered-99-2")
            .expect("renamed recovered session");
        assert_eq!(
            renamed.log_path.file_name().and_then(|name| name.to_str()),
            Some("session-2-recovered-99-2.log")
        );
        assert_eq!(
            std::fs::read(&protected_log)?,
            b"unrelated persisted history",
            "renaming a recovered session must not truncate an existing log"
        );
        assert!(
            state
                .sessions
                .iter()
                .any(|entry| entry.id.as_str() == "session-3" && entry.pid == 30)
        );
        assert!(
            reused_id.is_closed(),
            "a later snapshot must replace, not duplicate, an already-renamed child"
        );
        assert!(!refreshed_reused_id.is_closed());

        for fd in fds {
            // SAFETY: the merged vector owns every remaining probe descriptor.
            unsafe { libc::close(fd) };
        }
        assert!(old_retained.is_closed());
        assert!(fresh_replacement.is_closed());
        assert!(reused_id.is_closed());
        assert!(refreshed_reused_id.is_closed());
        assert!(new_session.is_closed());
        Ok(())
    }

    #[test]
    fn partial_recovery_snapshot_preserves_sessions_from_an_earlier_snapshot() -> anyhow::Result<()>
    {
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        crate::handover::remember_handover_peer_token(Some([1; 16]));
        let stale = FdProbe::new(&temp_dir.path, "stale-recovery-session")?;
        let session = crate::handover::HandoverSession {
            id: SessionId::new("session-1")?,
            command: "/bin/sh".to_string(),
            args: Vec::new(),
            cwd: None,
            size: SessionSize::default(),
            log_path: temp_dir.path.join("session-1.log"),
            output_seq: 0,
            bytes_logged: 0,
            pid: 42,
            process_identity: None,
            last_activity_ms: 0,
            judge_override: None,
        };
        crate::handover::remember_recovered_handover_for_test(
            crate::handover::HandoverState {
                sessions: Vec::new(),
                has_tcp_listener: false,
                sends_teardown_commit: true,
                handover_owner_token: Some([2; 16]),
                handover_lineage_token: Some([9; 16]),
            },
            Vec::new(),
        );

        let mut state = crate::handover::HandoverState {
            sessions: vec![session],
            has_tcp_listener: false,
            sends_teardown_commit: true,
            handover_owner_token: Some([1; 16]),
            handover_lineage_token: Some([9; 16]),
        };
        let mut fds = vec![stale.fd];
        crate::handover::merge_recovered_handovers(&mut state, &mut fds);

        assert!(!stale.is_closed());
        assert_eq!(state.sessions.len(), 1);
        assert_eq!(fds.len(), 1);
        // SAFETY: the merged vector owns the retained probe descriptor.
        unsafe { libc::close(fds.remove(0)) };
        assert!(stale.is_closed());
        Ok(())
    }

    #[test]
    fn legacy_recovery_snapshot_does_not_prune_the_committed_transfer() -> anyhow::Result<()> {
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        crate::handover::remember_handover_peer_token(Some([1; 16]));
        let retained = FdProbe::new(&temp_dir.path, "legacy-retained")?;
        let session = crate::handover::HandoverSession {
            id: SessionId::new("session-1")?,
            command: "/bin/sh".to_string(),
            args: Vec::new(),
            cwd: None,
            size: SessionSize::default(),
            log_path: temp_dir.path.join("session-1.log"),
            output_seq: 0,
            bytes_logged: 0,
            pid: 42,
            process_identity: None,
            last_activity_ms: 0,
            judge_override: None,
        };
        crate::handover::remember_recovered_handover_for_test(
            crate::handover::HandoverState {
                sessions: Vec::new(),
                has_tcp_listener: false,
                sends_teardown_commit: false,
                handover_owner_token: Some([2; 16]),
                handover_lineage_token: Some([7; 16]),
            },
            Vec::new(),
        );

        let mut state = crate::handover::HandoverState {
            sessions: vec![session],
            has_tcp_listener: false,
            sends_teardown_commit: false,
            handover_owner_token: Some([1; 16]),
            handover_lineage_token: Some([7; 16]),
        };
        let mut fds = vec![retained.fd];
        crate::handover::merge_recovered_handovers(&mut state, &mut fds);

        assert_eq!(state.sessions.len(), 1);
        assert_eq!(fds.len(), 1);
        assert!(!retained.is_closed());
        // SAFETY: the merged vector still owns this probe descriptor.
        unsafe { libc::close(fds.remove(0)) };
        assert!(retained.is_closed());
        Ok(())
    }

    #[test]
    fn tokenless_recovery_snapshots_use_stable_socket_identity() -> anyhow::Result<()> {
        use std::os::unix::io::AsRawFd;
        use std::os::unix::net::UnixListener;

        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        crate::handover::remember_handover_peer_token(None);
        let listener = UnixListener::bind(temp_dir.path.join("owner.sock"))?;
        let socket_identity = crate::ipc::socket_fd_identity(listener.as_raw_fd())
            .expect("bound socket has an identity");
        let stale = FdProbe::new(&temp_dir.path, "tokenless-stale")?;
        let session = crate::handover::HandoverSession {
            id: SessionId::new("session-1")?,
            command: "/bin/sh".to_string(),
            args: Vec::new(),
            cwd: None,
            size: SessionSize::default(),
            log_path: temp_dir.path.join("session-1.log"),
            output_seq: 0,
            bytes_logged: 0,
            pid: 42,
            process_identity: None,
            last_activity_ms: 0,
            judge_override: None,
        };
        crate::handover::remember_tokenless_recovered_handover_for_test(
            socket_identity,
            crate::handover::HandoverState {
                sessions: vec![session],
                has_tcp_listener: false,
                sends_teardown_commit: true,
                handover_owner_token: None,
                handover_lineage_token: None,
            },
            vec![stale.fd],
        );
        crate::handover::remember_tokenless_recovered_handover_for_test(
            socket_identity,
            crate::handover::HandoverState {
                sessions: Vec::new(),
                has_tcp_listener: false,
                sends_teardown_commit: true,
                handover_owner_token: None,
                handover_lineage_token: None,
            },
            Vec::new(),
        );

        let mut state = crate::handover::HandoverState {
            sessions: Vec::new(),
            has_tcp_listener: false,
            sends_teardown_commit: true,
            handover_owner_token: None,
            handover_lineage_token: None,
        };
        let mut fds = Vec::new();
        crate::handover::merge_recovered_handovers(&mut state, &mut fds);

        assert!(!stale.is_closed());
        assert_eq!(state.sessions.len(), 1);
        assert_eq!(fds.len(), 1);
        // SAFETY: the merged vector owns the retained probe descriptor.
        unsafe { libc::close(fds.remove(0)) };
        assert!(stale.is_closed());
        Ok(())
    }

    #[test]
    fn repeated_recovery_snapshots_compact_duplicate_descriptors() -> anyhow::Result<()> {
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        crate::handover::remember_handover_peer_token(Some([1; 16]));
        let stale = FdProbe::new(&temp_dir.path, "stale-duplicate")?;
        let fresh = FdProbe::new(&temp_dir.path, "fresh-duplicate")?;
        let session = crate::handover::HandoverSession {
            id: SessionId::new("session-1")?,
            command: "/bin/sh".to_string(),
            args: Vec::new(),
            cwd: None,
            size: SessionSize::default(),
            log_path: temp_dir.path.join("session-1.log"),
            output_seq: 0,
            bytes_logged: 0,
            pid: 42,
            process_identity: None,
            last_activity_ms: 0,
            judge_override: None,
        };
        let snapshot = |owner_token, fd| {
            crate::handover::remember_recovered_handover_for_test(
                crate::handover::HandoverState {
                    sessions: vec![session.clone()],
                    has_tcp_listener: false,
                    sends_teardown_commit: true,
                    handover_owner_token: Some(owner_token),
                    handover_lineage_token: Some([9; 16]),
                },
                vec![fd],
            );
        };
        snapshot([2; 16], stale.fd);
        snapshot([3; 16], fresh.fd);
        assert!(
            stale.is_closed(),
            "a newer snapshot of the same child must close the retained duplicate immediately"
        );

        let mut state = crate::handover::HandoverState {
            sessions: Vec::new(),
            has_tcp_listener: false,
            sends_teardown_commit: true,
            handover_owner_token: Some([1; 16]),
            handover_lineage_token: Some([9; 16]),
        };
        let mut fds = Vec::new();
        crate::handover::merge_recovered_handovers(&mut state, &mut fds);
        assert_eq!(state.sessions.len(), 1);
        assert_eq!(fds.len(), 1);
        assert!(!fresh.is_closed());
        // SAFETY: merge transferred ownership of the fresh probe descriptor.
        unsafe { libc::close(fds.remove(0)) };
        assert!(fresh.is_closed());
        Ok(())
    }

    #[test]
    fn tokenless_recovery_treats_zero_foreground_group_as_stale() {
        assert!(crate::handover::tokenless_pty_foreground_is_live_for_test(
            42, None
        ));
        assert!(!crate::handover::tokenless_pty_foreground_is_live_for_test(
            0, None
        ));
        assert!(!crate::handover::tokenless_pty_foreground_is_live_for_test(
            -1,
            Some(libc::EIO)
        ));
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
    fn timeout_waits_for_a_committing_peer_but_adopts_from_a_legacy_peer() {
        // A current peer has not resolved ownership until its commit byte arrives,
        // so the successor retains descriptors without starting readers and uses
        // the recovery handover. Legacy peers keep the compatibility behavior.
        assert_eq!(
            teardown_outcome(true, TeardownSignal::Timeout),
            TeardownOutcome::Refuse
        );
        assert_eq!(
            teardown_outcome(false, TeardownSignal::Timeout),
            TeardownOutcome::Adopt
        );
    }

    #[test]
    fn committed_peer_timeout_triggers_termination_before_adoption() -> anyhow::Result<()> {
        use std::os::unix::net::UnixStream;
        let (mut client, server) = UnixStream::pair()?;
        client.set_read_timeout(Some(std::time::Duration::from_millis(20)))?;
        let mut blocking_peer = Some(server);
        crate::handover::wait_for_committed_peer_teardown_for_test(&mut client, || {
            if let Some(peer) = blocking_peer.take() {
                peer.shutdown(std::net::Shutdown::Both)
                    .expect("terminate committed peer fixture");
            }
        });
        assert!(
            blocking_peer.is_none(),
            "the committed peer must be terminated after its teardown grace"
        );
        Ok(())
    }

    #[test]
    fn stray_byte_follows_the_eof_rule() {
        // An unexpected byte is treated like no commit byte: refuse only when the
        // peer claimed it would commit, adopt otherwise.
        let signal = TeardownSignal::Byte(0x7f);
        assert_eq!(teardown_outcome(true, signal), TeardownOutcome::Refuse);
        assert_eq!(teardown_outcome(false, signal), TeardownOutcome::Adopt);
    }

    #[test]
    fn complete_handover_adoption_adopts_when_peer_dies_before_0x01_write() -> anyhow::Result<()> {
        use std::os::unix::net::UnixStream;
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        let dead_socket_path = temp_dir.path.join("dead.sock");

        let (client, server) = UnixStream::pair()?;
        server.shutdown(std::net::Shutdown::Both)?;
        drop(server);

        crate::handover::remember_handover_peer_identity(
            Some([1; 16]),
            Some(crate::ipc::definitely_dead_peer_process_identity_for_test()),
        );
        *crate::handover::HANDOVER_STREAM.lock().unwrap() = Some(client);
        crate::handover::complete_handover_adoption(&dead_socket_path, true)?;
        Ok(())
    }

    #[test]
    fn complete_handover_adoption_adopts_when_a_tokenless_original_is_dead() -> anyhow::Result<()> {
        use std::os::unix::net::{UnixListener, UnixStream};
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        let replacement_socket_path = temp_dir.path.join("replacement.sock");
        let replacement_listener = UnixListener::bind(&replacement_socket_path)?;
        let responder = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(100));
            drop(replacement_listener);
        });

        let (client, server) = UnixStream::pair()?;
        server.shutdown(std::net::Shutdown::Both)?;
        drop(server);

        // A pre-token daemon is still distinguishable by its authenticated
        // process identity on supported Unix platforms.
        crate::handover::remember_handover_peer_identity(
            None,
            Some(crate::ipc::definitely_dead_peer_process_identity_for_test()),
        );
        *crate::handover::HANDOVER_STREAM.lock().unwrap() = Some(client);
        crate::handover::complete_handover_adoption(&replacement_socket_path, true)?;
        responder.join().unwrap();
        Ok(())
    }

    #[test]
    fn complete_handover_adoption_does_not_wait_forever_without_process_identity()
    -> anyhow::Result<()> {
        use std::os::unix::net::UnixStream;
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        let absent_socket_path = temp_dir.path.join("absent.sock");
        let (client, server) = UnixStream::pair()?;
        server.shutdown(std::net::Shutdown::Both)?;
        drop(server);

        crate::handover::remember_handover_peer_identity(Some([7; 16]), None);
        *crate::handover::HANDOVER_STREAM.lock().unwrap() = Some(client);
        assert_eq!(
            crate::handover::complete_handover_adoption(&absent_socket_path, true)?,
            crate::handover::TeardownOutcome::Adopt
        );
        Ok(())
    }

    #[test]
    fn complete_handover_adoption_retries_when_peer_alive_on_0x01_write_failure()
    -> anyhow::Result<()> {
        use std::io::{BufRead, BufReader, Read, Write};
        use std::os::unix::net::{UnixListener, UnixStream};
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        let alive_socket_path = temp_dir.path.join("alive.sock");
        let listener = UnixListener::bind(&alive_socket_path)?;
        crate::handover::remember_handover_peer_token(Some([3; 16]));
        let responder = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut request)
                .unwrap();
            assert!(request.contains("HandoverProbe"));
            stream.write_all(b"{\"Ok\":\"Unit\"}\n").unwrap();

            let (mut stream, _) = listener.accept().unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut request)
                .unwrap();
            assert!(request.contains("Handover"));
            let response = serde_json::json!({
                "Ok": {
                    "HandoverState": {
                        "sessions": [],
                        "has_tcp_listener": false,
                        "sends_teardown_commit": true,
                        "handover_owner_token": vec![3; 16]
                    }
                }
            });
            crate::handover::send_fds(&stream, &[], &serde_json::to_vec(&response).unwrap())
                .unwrap();
            let mut adopt = [0; 1];
            stream.read_exact(&mut adopt).unwrap();
            assert_eq!(adopt[0], crate::handover::HANDOVER_ADOPT_BYTE);
            stream
                .write_all(&[crate::handover::HANDOVER_COMMIT_BYTE])
                .unwrap();
        });

        let (client, server) = UnixStream::pair()?;
        server.shutdown(std::net::Shutdown::Both)?;
        drop(server);

        *crate::handover::HANDOVER_STREAM.lock().unwrap() = Some(client);
        crate::handover::complete_handover_adoption(&alive_socket_path, true)?;
        responder.join().unwrap();
        Ok(())
    }

    #[test]
    fn complete_handover_adoption_adopts_when_the_original_is_dead_and_replacement_disappears()
    -> anyhow::Result<()> {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::{UnixListener, UnixStream};
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        let socket_path = temp_dir.path.join("peer.sock");
        let original_listener = UnixListener::bind(&socket_path)?;
        crate::handover::remember_handover_peer_identity(
            Some([7; 16]),
            Some(crate::ipc::definitely_dead_peer_process_identity_for_test()),
        );

        // launchd closes the original listener when it SIGKILLs the old daemon,
        // then its KeepAlive restart unlinks the stale node and binds a fresh one.
        drop(original_listener);
        std::fs::remove_file(&socket_path)?;
        let replacement_listener = UnixListener::bind(&socket_path)?;
        let responder = std::thread::spawn(move || {
            let (mut stream, _) = replacement_listener.accept().unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut request)
                .unwrap();
            assert!(request.contains("HandoverProbe"));
            stream
                .write_all(b"{\"Err\":{\"message\":\"replacement daemon\"}}\n")
                .unwrap();
        });

        let (client, server) = UnixStream::pair()?;
        server.shutdown(std::net::Shutdown::Both)?;
        drop(server);

        *crate::handover::HANDOVER_STREAM.lock().unwrap() = Some(client);
        crate::handover::complete_handover_adoption(&socket_path, true)?;
        responder.join().unwrap();
        Ok(())
    }

    #[test]
    fn complete_handover_adoption_adopts_when_commit_byte_received() -> anyhow::Result<()> {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixStream;
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        let socket_path = temp_dir.path.join("peer.sock");

        let (client, mut server) = UnixStream::pair()?;
        let handle = std::thread::spawn(move || {
            let mut buf = [0u8; 1];
            server.read_exact(&mut buf).unwrap();
            assert_eq!(buf[0], crate::handover::HANDOVER_ADOPT_BYTE);
            server
                .write_all(&[crate::handover::HANDOVER_COMMIT_BYTE])
                .unwrap();
            server.flush().unwrap();
        });

        *crate::handover::HANDOVER_STREAM.lock().unwrap() = Some(client);
        crate::handover::complete_handover_adoption(&socket_path, true)?;
        handle.join().unwrap();
        Ok(())
    }

    #[test]
    fn complete_handover_adoption_adopts_when_peer_dies_during_phase3() -> anyhow::Result<()> {
        use std::io::Read;
        use std::os::unix::net::UnixStream;
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        let dead_socket_path = temp_dir.path.join("dead.sock");

        let (client, mut server) = UnixStream::pair()?;
        let handle = std::thread::spawn(move || {
            let mut buf = [0u8; 1];
            server.read_exact(&mut buf).unwrap();
            assert_eq!(buf[0], crate::handover::HANDOVER_ADOPT_BYTE);
            server.shutdown(std::net::Shutdown::Both).unwrap();
            drop(server);
        });

        crate::handover::remember_handover_peer_identity(
            Some([2; 16]),
            Some(crate::ipc::definitely_dead_peer_process_identity_for_test()),
        );
        *crate::handover::HANDOVER_STREAM.lock().unwrap() = Some(client);
        crate::handover::complete_handover_adoption(&dead_socket_path, true)?;
        handle.join().unwrap();
        Ok(())
    }

    #[test]
    fn complete_handover_adoption_retries_when_peer_alive_during_phase3_eof() -> anyhow::Result<()>
    {
        use std::io::{BufRead, BufReader, Read, Write};
        use std::os::unix::net::{UnixListener, UnixStream};
        let _handover_lock = handover_state_lock();
        let temp_dir = TempDir::new()?;
        let alive_socket_path = temp_dir.path.join("alive.sock");
        let listener = UnixListener::bind(&alive_socket_path)?;
        crate::handover::remember_handover_peer_token(Some([5; 16]));
        let responder = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut request)
                .unwrap();
            assert!(request.contains("HandoverProbe"));
            stream.write_all(b"{\"Ok\":\"Unit\"}\n").unwrap();

            let (mut stream, _) = listener.accept().unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut request)
                .unwrap();
            assert!(request.contains("Handover"));
            let response = serde_json::json!({
                "Ok": {
                    "HandoverState": {
                        "sessions": [],
                        "has_tcp_listener": false,
                        "sends_teardown_commit": true,
                        "handover_owner_token": vec![5; 16]
                    }
                }
            });
            crate::handover::send_fds(&stream, &[], &serde_json::to_vec(&response).unwrap())
                .unwrap();
            let mut adopt = [0; 1];
            stream.read_exact(&mut adopt).unwrap();
            assert_eq!(adopt[0], crate::handover::HANDOVER_ADOPT_BYTE);
            stream
                .write_all(&[crate::handover::HANDOVER_COMMIT_BYTE])
                .unwrap();
        });

        let (client, mut server) = UnixStream::pair()?;
        let handle = std::thread::spawn(move || {
            let mut buf = [0u8; 1];
            server.read_exact(&mut buf).unwrap();
            assert_eq!(buf[0], crate::handover::HANDOVER_ADOPT_BYTE);
            server.shutdown(std::net::Shutdown::Both).unwrap();
            drop(server);
        });

        *crate::handover::HANDOVER_STREAM.lock().unwrap() = Some(client);
        crate::handover::complete_handover_adoption(&alive_socket_path, true)?;
        handle.join().unwrap();
        responder.join().unwrap();
        Ok(())
    }
}
