#[cfg(all(unix, test))]
mod tests {
    use crate::session::{SessionManager, SessionManagerConfig};
    use std::path::PathBuf;
    use triage_core::session::{SessionApi, SessionSize, StartSessionRequest};

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

    // The two-process Phase-3 handshake (complete_handover_adoption /
    // handle_handover_server) can't be exercised in-process — it does socket I/O
    // between two daemons and ends in process::exit. The adopt-vs-refuse decision
    // is factored into `teardown_outcome` precisely so its contract is testable
    // here without that dance.
    use crate::handover::{TeardownOutcome, teardown_outcome};

    #[test]
    fn commit_byte_always_adopts() {
        // 0x03 is the explicit teardown-commit: adopt regardless of what the peer
        // announced (a peer that sends the byte obviously supports it).
        assert_eq!(teardown_outcome(true, Some(0x03)), TeardownOutcome::Adopt);
        assert_eq!(teardown_outcome(false, Some(0x03)), TeardownOutcome::Adopt);
    }

    #[test]
    fn done_byte_always_adopts() {
        // 0x02 is a clean teardown from a daemon predating the commit byte; it
        // detached before sending, so adopt.
        assert_eq!(teardown_outcome(true, Some(0x02)), TeardownOutcome::Adopt);
        assert_eq!(teardown_outcome(false, Some(0x02)), TeardownOutcome::Adopt);
    }

    #[test]
    fn eof_from_committing_peer_refuses() {
        // The peer announced it commits before detaching, yet sent no commit
        // byte: it aborted and still owns its sessions. Adopting would put a
        // second destructive reader on each master — refuse.
        assert_eq!(teardown_outcome(true, None), TeardownOutcome::Refuse);
    }

    #[test]
    fn eof_from_legacy_peer_adopts() {
        // An older daemon that never announces the commit byte: EOF cannot tell an
        // abort from a lost 0x02, and refusing would strand a real handover, so
        // adopt — the historical behavior we must preserve for old peers.
        assert_eq!(teardown_outcome(false, None), TeardownOutcome::Adopt);
    }

    #[test]
    fn stray_byte_follows_the_eof_rule() {
        // An unexpected byte is treated like no commit byte: refuse only when the
        // peer claimed it would commit, adopt otherwise.
        assert_eq!(teardown_outcome(true, Some(0x7f)), TeardownOutcome::Refuse);
        assert_eq!(teardown_outcome(false, Some(0x7f)), TeardownOutcome::Adopt);
    }
}
