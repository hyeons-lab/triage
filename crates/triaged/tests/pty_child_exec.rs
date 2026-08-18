#![cfg(unix)]
#![allow(unsafe_code)]

use std::process::Command;

#[test]
fn probe_default_job_control_dispositions() {
    if std::env::var_os("TRIAGE_PTY_SIGNAL_PROBE").is_none() {
        return;
    }

    for signal in [libc::SIGTTIN, libc::SIGTTOU] {
        let mut action = std::mem::MaybeUninit::<libc::sigaction>::uninit();
        // SAFETY: `action` points to writable storage for one sigaction value;
        // a null second argument asks only for the current disposition.
        let result = unsafe { libc::sigaction(signal, std::ptr::null(), action.as_mut_ptr()) };
        assert_eq!(result, 0, "read signal {signal} disposition");
        // SAFETY: sigaction initialized `action` after returning zero.
        let action = unsafe { action.assume_init() };
        assert_eq!(action.sa_sigaction, libc::SIG_DFL);
    }
}

#[test]
fn pty_child_exec_resets_ignored_job_control_signals() {
    // SAFETY: the previous dispositions are saved and restored below. The child
    // must inherit SIG_IGN to reproduce the daemon state this shim exists for.
    let (old_ttin, old_ttou) = unsafe {
        (
            libc::signal(libc::SIGTTIN, libc::SIG_IGN),
            libc::signal(libc::SIGTTOU, libc::SIG_IGN),
        )
    };
    let output = Command::new(env!("CARGO_BIN_EXE_triaged"))
        .arg(triaged::session::PTY_CHILD_EXEC_ARG)
        .arg(std::env::current_exe().expect("resolve probe executable"))
        .args([
            "--exact",
            "probe_default_job_control_dispositions",
            "--nocapture",
        ])
        .env("TRIAGE_PTY_SIGNAL_PROBE", "1")
        .output()
        .expect("run PTY child exec shim");
    // SAFETY: restore exactly the dispositions returned by signal above.
    unsafe {
        libc::signal(libc::SIGTTIN, old_ttin);
        libc::signal(libc::SIGTTOU, old_ttou);
    }

    assert!(
        output.status.success(),
        "shim probe failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
