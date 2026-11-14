#![cfg(unix)]

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use triage_core::session::{SessionApi, StartSessionRequest};
use triage_core::workers::WorkerProfile;
use triaged::ipc::{IpcConfig, IpcServer};
use triaged::session::{SessionManager, SessionManagerConfig};

fn call_response(socket: &Path, name: &str, arguments: Value) -> Value {
    let mut child = Command::new(env!("CARGO_BIN_EXE_triage-mcp"))
        .arg("--socket")
        .arg(socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    writeln!(child.stdin.take().unwrap(), "{}", json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":name,"arguments":arguments}})).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let response: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(response.get("error").is_none(), "{response}");
    response
}

fn call(socket: &Path, name: &str, arguments: Value) -> Value {
    let response = call_response(socket, name, arguments);
    assert_ne!(response["result"]["isError"], true, "{response}");
    response["result"]["structuredContent"].clone()
}

struct Cleanup {
    manager: Arc<SessionManager>,
    dir: PathBuf,
}
impl Drop for Cleanup {
    fn drop(&mut self) {
        for id in self.manager.list_sessions().unwrap_or_default() {
            let _ = self.manager.shutdown_session(id);
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn mcp_launches_helper_that_reports_durable_results_through_cli_and_ipc() {
    let unique = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );
    // AF_UNIX paths must fit macOS's short sun_path, independent of the temp prefix.
    let dir = PathBuf::from("/tmp").join(format!("tw-{unique}"));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s");
    let result_path = dir.join("result.txt");
    let script = r#"
group=$(printf '%s\n' "$1" | sed -n 's/^Group: //p')
task=$(printf '%s\n' "$1" | sed -n 's/^Task ID: //p')
"$2" worker-update "$group" "$task" ready --socket "$3" || exit 1
"$2" worker-update "$group" "$task" running --socket "$3" || exit 1
printf '%s' 'verified helper result' > "$4"
"$2" worker-update "$group" "$task" succeeded --result-file "$4" --socket "$3" || exit 1
exec /bin/cat
"#;
    let missing_executable = dir.join("missing-worker-executable");
    let mut config = SessionManagerConfig::new(dir.join("logs"));
    config.worker_profiles = Some(BTreeMap::from([(
        "test-helper".into(),
        WorkerProfile {
            command: "/bin/sh".into(),
            args: vec![
                "-c".into(),
                script.into(),
                "worker".into(),
                "{prompt}".into(),
                env!("CARGO_BIN_EXE_triage-mcp").into(),
                socket.to_string_lossy().into_owned(),
                result_path.to_string_lossy().into_owned(),
            ],
        },
    )]));
    config.worker_profiles.as_mut().unwrap().insert(
        "missing-helper".into(),
        WorkerProfile {
            command: missing_executable.to_str().unwrap().into(),
            args: vec!["{prompt}".into()],
        },
    );
    let manager = Arc::new(SessionManager::new(config));
    let _cleanup = Cleanup {
        manager: manager.clone(),
        dir: dir.clone(),
    };
    let server = IpcServer::new(
        manager.clone(),
        Arc::new(triaged::http::WebAssetCache::new(None)),
        IpcConfig::new(&socket),
    );
    std::thread::spawn(move || server.serve().unwrap());
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut root_request = StartSessionRequest::new("/bin/cat");
    root_request.cwd = Some(dir.clone());
    let root = manager.start_session(root_request).unwrap();
    let profiles = call(&socket, "list_worker_profiles", json!({}));
    assert!(profiles["profiles"].get("test-helper").is_some());
    let group = call(
        &socket,
        "create_worker_group",
        json!({"parent_session_id":root,"key":"integration","topic":"End-to-end worker"}),
    );
    let group_id = &group["group"]["group_id"];
    let args = json!({"group_id":group_id,"parent_session_id":root,"key":"worker","profile":"test-helper","cwd":dir,"task":"Produce a durable result, then wait."});
    let worker = call(&socket, "spawn_worker", args.clone());
    let retried = call(&socket, "spawn_worker", args);
    assert_eq!(worker["worker"]["session"], retried["worker"]["session"]);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = call(&socket, "get_worker_group", json!({"group_id":group_id}));
        if status["group"]["workers"][0]["phase"] == "succeeded" {
            assert_eq!(
                status["group"]["workers"][0]["result"],
                "verified helper result"
            );
            break;
        }
        assert!(Instant::now() < deadline, "{status}");
        std::thread::sleep(Duration::from_millis(20));
    }
    let launch_failure = call_response(
        &socket,
        "spawn_worker",
        json!({"group_id":group_id,"parent_session_id":root,"key":"missing","profile":"missing-helper","cwd":dir,"task":"Report the missing executable."}),
    );
    let log_directory = dir.join("logs");
    let saved_log_directory = dir.join("saved-logs");
    std::fs::rename(&log_directory, &saved_log_directory).unwrap();
    std::fs::write(&log_directory, b"blocked directory").unwrap();
    let expected_directory_io_error = std::fs::create_dir_all(&log_directory)
        .unwrap_err()
        .to_string();
    let directory_failure = call_response(
        &socket,
        "cleanup_worker_group",
        json!({"group_id":group_id}),
    );
    std::fs::remove_file(&log_directory).unwrap();
    std::fs::rename(&saved_log_directory, &log_directory).unwrap();

    let report = call(
        &socket,
        "cleanup_worker_group",
        json!({"group_id":group_id}),
    );
    assert_eq!(report["group"]["phase"], "closed");
    assert_eq!(
        report["group"]["workers"][0]["result"],
        "verified helper result"
    );
    let registry_path = dir.join("logs/worker-groups.json");
    let saved_registry = registry_path.with_extension("saved");
    std::fs::rename(&registry_path, &saved_registry).unwrap();
    std::fs::create_dir(&registry_path).unwrap();
    let expected_io_error = std::fs::write(&registry_path, b"").unwrap_err().to_string();
    let persistence_failure = call_response(
        &socket,
        "create_worker_group",
        json!({"parent_session_id":root,"key":"blocked","topic":"Report registry persistence failure."}),
    );
    std::fs::remove_dir(&registry_path).unwrap();
    std::fs::rename(&saved_registry, &registry_path).unwrap();

    assert_eq!(
        launch_failure["result"]["isError"], true,
        "{launch_failure}"
    );
    let launch_error = launch_failure["result"]["content"][0]["text"]
        .as_str()
        .unwrap();
    for expected in [
        missing_executable.to_str().unwrap(),
        "spawning PTY child",
        "ENOENT",
    ] {
        assert!(launch_error.contains(expected), "{launch_failure}");
    }
    assert_eq!(
        persistence_failure["result"]["isError"], true,
        "{persistence_failure}"
    );
    let persistence_error = persistence_failure["result"]["content"][0]["text"]
        .as_str()
        .unwrap();
    for expected in [registry_path.to_str().unwrap(), expected_io_error.as_str()] {
        assert!(
            persistence_error.contains(expected),
            "{persistence_failure}"
        );
    }
    assert_eq!(
        directory_failure["result"]["isError"], true,
        "{directory_failure}"
    );
    let directory_error = directory_failure["result"]["content"][0]["text"]
        .as_str()
        .unwrap();
    for expected in [
        registry_path.to_str().unwrap(),
        expected_directory_io_error.as_str(),
    ] {
        assert!(directory_error.contains(expected), "{directory_failure}");
    }
    assert_eq!(manager.list_sessions().unwrap(), vec![root]);
    assert!(result_path.is_file());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(dir.join("logs/worker-groups.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
