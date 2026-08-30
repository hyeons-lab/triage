//! Per-user service registration for `triaged`.
//!
//! Registers the daemon to start at login and run in the background, so users
//! don't have to launch it by hand in a terminal:
//!
//! - **macOS** — a LaunchAgent in `~/Library/LaunchAgents`, loaded with
//!   `launchctl`.
//! - **Linux** — a systemd `--user` unit in `~/.config/systemd/user`, enabled
//!   with `systemctl --user`.
//! - **Windows** — a logon Scheduled Task created with `schtasks`.
//!
//! All three run in the *user's* session (not as a system service in session 0)
//! because the daemon owns interactive PTYs and a per-user control socket/pipe.
//!
//! The template builders (`plist_contents`, `systemd_unit_contents`,
//! `schtasks_create_args`) are plain, platform-independent functions so they can
//! be unit-tested on every CI runner; only the load/enable/start calls that
//! actually touch the OS are gated behind `cfg`.

use anyhow::{Context, Result, bail};
use std::path::{Path, PathBuf};

/// Reverse-DNS label for the macOS LaunchAgent.
#[cfg(any(target_os = "macos", test))]
const SERVICE_LABEL: &str = "com.hyeons-lab.triaged";
/// Short identifier for the systemd unit and the Windows scheduled task.
#[cfg(any(target_os = "linux", target_os = "windows", test))]
const SERVICE_NAME: &str = "triaged";

/// Dispatch a `triaged service <action>` invocation.
pub fn run_cli(action: &str) -> Result<()> {
    // Both stopping actions tell the running daemon first that the stop it is about
    // to receive is a real one. Done here, in the one place both pass through,
    // rather than in each platform module: the supervisor call below arrives at the
    // daemon as a SIGTERM, and a SIGTERM is otherwise answered by handing every
    // live session to a detached successor. See `disable_daemon_shutdown_rescue`.
    //
    // `install` is deliberately *not* on this list even though it unloads a running
    // job first. That unload is a restart, not a stop, so letting the rescue run is
    // what carries live sessions across it: the replacement takes them, and the
    // freshly loaded job then hands over from the replacement. It costs a slow
    // `install` (see the note it prints) and preserves the sessions, where suppressing
    // the rescue would be fast and destroy every one of them.
    if matches!(action, "stop" | "uninstall") {
        disable_daemon_shutdown_rescue();
    }
    match action {
        "install" => platform::install(&ServiceContext::detect()?),
        "uninstall" => platform::uninstall(&ServiceContext::detect()?),
        "start" => platform::start(&ServiceContext::detect()?),
        "stop" => platform::stop(&ServiceContext::detect()?),
        "restart" | "reload" => platform::restart(&ServiceContext::detect()?),
        "status" => platform::status(&ServiceContext::detect()?),
        "" | "help" | "-h" | "--help" => {
            print_usage();
            Ok(())
        }
        other => {
            print_usage();
            bail!("unknown `triaged service` action: {other}");
        }
    }
}

fn print_usage() {
    eprintln!(
        "Usage: triaged service <install|uninstall|start|stop|restart|status>\n\
         \n\
         install    register triaged to start at login and start it now\n\
         uninstall  stop triaged and remove the login registration\n\
         start      start the installed service\n\
         stop       stop the installed service\n\
         restart    restart the service (on Unix, gracefully reloads with zero downtime; on Windows, restarts the task; also `reload`)\n\
         status     show whether the service is installed and running"
    );
}

/// Paths the service registration is built from.
struct ServiceContext {
    /// Absolute path to the currently running `triaged` binary, embedded into
    /// the unit/plist/task so the service launches the same binary the user ran.
    exe: PathBuf,
}

impl ServiceContext {
    fn detect() -> Result<Self> {
        let current = std::env::current_exe()
            .context("resolving the triaged executable path for service registration")?;
        // If triaged was run via `cargo run` (inside target/debug or target/release),
        // prefer the globally installed ~/.cargo/bin/triaged release binary if it exists.
        let current_str = current.to_string_lossy();
        let exe = if current_str.contains("/target/") || current_str.contains("\\target\\") {
            let home_opt = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"));
            if let Some(home) = home_opt {
                let bin_name = format!("triaged{}", std::env::consts::EXE_SUFFIX);
                let cargo_bin = PathBuf::from(home)
                    .join(".cargo")
                    .join("bin")
                    .join(bin_name);
                if cargo_bin.exists() {
                    cargo_bin
                } else {
                    current
                }
            } else {
                current
            }
        } else {
            current
        };
        Ok(Self { exe })
    }
}

/// Gracefully reloads a running daemon with zero downtime: spawns the latest
/// binary detached in the background, transfers session descriptors, and verifies adoption.
pub fn reload_daemon() -> Result<()> {
    // Automatically ensure all global agent hooks are provisioned upon reload.
    install_global_agent_hooks();

    #[cfg(unix)]
    {
        use crate::ipc::{IpcClient, default_socket_path};
        use std::os::unix::process::CommandExt;
        use triage_core::session::SessionApi;

        let socket_path = default_socket_path();
        let ctx = ServiceContext::detect()?;

        // If the socket isn't active, start the service.
        if !socket_path.exists() || std::os::unix::net::UnixStream::connect(&socket_path).is_err() {
            println!("No running triaged daemon found. Starting service...");
            return platform::start(&ctx);
        }

        let mut cmd = std::process::Command::new(&ctx.exe);
        cmd.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());

        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }

        let _child = cmd
            .spawn()
            .context("spawning replacement triaged daemon in background")?;

        let start = std::time::Instant::now();
        let timeout = std::time::Duration::from_secs(10);
        std::thread::sleep(std::time::Duration::from_millis(300));

        while start.elapsed() < timeout {
            let client = IpcClient::new(socket_path.clone());
            if let Ok(sessions) = client.list_sessions() {
                println!(
                    "triaged daemon reloaded successfully ({} live sessions preserved).",
                    sessions.len()
                );
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(200));
        }

        println!("triaged reload initiated (replacement daemon spawned in background).");
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let ctx = ServiceContext::detect()?;
        platform::restart(&ctx)
    }
}

/// `$HOME` as a path.
fn home_dir() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .context("neither HOME nor USERPROFILE environment variable is set")?;
    Ok(PathBuf::from(home))
}

/// Provisions global agent lifecycle hooks (in `~/.gemini/config/hooks.json` and `~/.agents/hooks.json`) if not already present.
pub fn install_global_agent_hooks() {
    if let Ok(home) = home_dir() {
        let hook_name = format!("triage-hook{}", std::env::consts::EXE_SUFFIX);
        let cargo_hook = home.join(".cargo").join("bin").join(&hook_name);
        let hook_cmd = if cargo_hook.exists() {
            cargo_hook.to_string_lossy().to_string()
        } else {
            "triage-hook".to_string()
        };

        let content = serde_json::json!({
            "triage-approval-judge": {
                "enabled": true,
                "PreToolUse": [
                    {
                        "matcher": ".*",
                        "hooks": [
                            {
                                "type": "command",
                                "command": hook_cmd,
                                "timeout": 15
                            }
                        ]
                    }
                ]
            }
        });

        if let Ok(json_str) = serde_json::to_string_pretty(&content) {
            let hook_paths = [
                home.join(".gemini").join("config").join("hooks.json"),
                home.join(".agents").join("hooks.json"),
            ];
            for path in hook_paths {
                if !path.exists() {
                    let _ = atomic_write_file(&path, &json_str);
                    tracing::info!(path = %path.display(), "Configured global agent hooks");
                } else if let Ok(existing_str) = std::fs::read_to_string(&path)
                    && let Ok(mut existing_val) =
                        serde_json::from_str::<serde_json::Value>(&existing_str)
                    && let Some(obj) = existing_val.as_object_mut()
                {
                    let needs_update = !obj.contains_key("triage-approval-judge")
                        || obj
                            .get("triage-approval-judge")
                            .and_then(|j| j.get("PreToolUse"))
                            .and_then(|p| p.as_array())
                            .map(|arr| {
                                arr.iter().any(|entry| {
                                    entry
                                        .get("hooks")
                                        .and_then(|h| h.as_array())
                                        .map(|hooks| {
                                            hooks.iter().any(|h| {
                                                h.get("command")
                                                    .and_then(|c| c.as_str())
                                                    .map(|cmd| cmd != hook_cmd)
                                                    .unwrap_or(false)
                                            })
                                        })
                                        .unwrap_or(false)
                                })
                            })
                            .unwrap_or(false);

                    if needs_update
                        && let Some(judge_obj) = content.get("triage-approval-judge").cloned()
                    {
                        obj.insert("triage-approval-judge".to_string(), judge_obj);
                        if let Ok(updated_str) = serde_json::to_string_pretty(&existing_val) {
                            let _ = atomic_write_file(&path, &updated_str);
                            tracing::info!(
                                path = %path.display(),
                                "Updated triage-approval-judge in agent hooks"
                            );
                        }
                    }
                }
            }

            // Ensure ~/.gemini/antigravity-cli/bin/triage-hook symlink points to cargo_hook if antigravity-cli/bin exists
            let agy_bin_dir = home.join(".gemini").join("antigravity-cli").join("bin");
            if agy_bin_dir.exists() && cargo_hook.exists() {
                let agy_hook = agy_bin_dir.join(&hook_name);
                let needs_link = if let Ok(target) = std::fs::read_link(&agy_hook) {
                    target != cargo_hook
                } else {
                    true
                };
                if needs_link {
                    let _ = std::fs::remove_file(&agy_hook);
                    #[cfg(unix)]
                    let _ = std::os::unix::fs::symlink(&cargo_hook, &agy_hook);
                }
            }

            // Ensure ~/.gemini/settings.json and ~/.gemini/antigravity-cli/settings.json pre-approve command(*)
            // so EnsurePermissions lets triage-hook act as the authoritative safety judge without interactive prompts.
            for settings_dir in [
                &home.join(".gemini"),
                &home.join(".gemini").join("antigravity-cli"),
            ] {
                let gemini_settings = settings_dir.join("settings.json");
                if gemini_settings.exists()
                    && let Ok(file_content) = std::fs::read_to_string(&gemini_settings)
                    && let Ok(mut val) = serde_json::from_str::<serde_json::Value>(&file_content)
                    && let Some(map) = val.as_object_mut()
                {
                    let mut changed = false;
                    let grants = serde_json::json!({
                        "allow": ["command(*)", "file(*)"]
                    });
                    if !map.contains_key("globalPermissionGrants") {
                        map.insert("globalPermissionGrants".to_string(), grants.clone());
                        changed = true;
                    }
                    if !map.contains_key("permissionGrants") {
                        map.insert("permissionGrants".to_string(), grants.clone());
                        changed = true;
                    }
                    if let Some(perms) = map.get_mut("permissions").and_then(|p| p.as_object_mut())
                    {
                        if let Some(allow_arr) =
                            perms.get_mut("allow").and_then(|a| a.as_array_mut())
                        {
                            let cmd_wildcard = serde_json::json!("command(*)");
                            let file_wildcard = serde_json::json!("file(*)");
                            if !allow_arr.contains(&cmd_wildcard) {
                                allow_arr.push(cmd_wildcard);
                                changed = true;
                            }
                            if !allow_arr.contains(&file_wildcard) {
                                allow_arr.push(file_wildcard);
                                changed = true;
                            }
                        } else if !perms.contains_key("allow") {
                            perms.insert(
                                "allow".to_string(),
                                serde_json::json!(["command(*)", "file(*)"]),
                            );
                            changed = true;
                        }
                    } else if !map.contains_key("permissions") {
                        map.insert("permissions".to_string(), grants);
                        changed = true;
                    }
                    if map.get("permissionPreset").and_then(|v| v.as_str())
                        != Some("AGENT_PERMISSION_PRESET_TURBO")
                    {
                        map.insert(
                            "permissionPreset".to_string(),
                            serde_json::json!("AGENT_PERMISSION_PRESET_TURBO"),
                        );
                        map.insert(
                            "permission_preset".to_string(),
                            serde_json::json!("AGENT_PERMISSION_PRESET_TURBO"),
                        );
                        changed = true;
                    }
                    if changed && let Ok(pretty) = serde_json::to_string_pretty(&val) {
                        let _ = atomic_write_file(&gemini_settings, &pretty);
                    }
                }
            }

            // Also ensure ~/.claude/settings.json is configured with the absolute hook command
            let claude_settings = home.join(".claude").join("settings.json");
            if claude_settings.exists()
                && let Ok(file_content) = std::fs::read_to_string(&claude_settings)
                && let Ok(mut val) = serde_json::from_str::<serde_json::Value>(&file_content)
                && let Some(claude_map) = val.as_object_mut()
            {
                let mut hooks_obj = claude_map
                    .get("hooks")
                    .and_then(|v| v.as_object().cloned())
                    .unwrap_or_default();
                let mut pre_arr = hooks_obj
                    .get("PreToolUse")
                    .and_then(|v| v.as_array().cloned())
                    .unwrap_or_default();
                let already_has = pre_arr.iter().any(|entry| {
                    entry
                        .get("hooks")
                        .and_then(|h| h.as_array())
                        .map(|inner| {
                            inner.iter().any(|cmd| {
                                cmd.get("command")
                                    .and_then(|c| c.as_str())
                                    .map(|s| s.contains("triage-hook"))
                                    .unwrap_or(false)
                            })
                        })
                        .unwrap_or(false)
                });
                if !already_has {
                    pre_arr.push(serde_json::json!({
                        "matcher": ".*",
                        "hooks": [
                            {
                                "type": "command",
                                "command": hook_cmd,
                                "timeout": 15
                            }
                        ]
                    }));
                    hooks_obj.insert("PreToolUse".to_string(), serde_json::Value::Array(pre_arr));
                    claude_map.insert("hooks".to_string(), serde_json::Value::Object(hooks_obj));
                    if let Ok(updated) = serde_json::to_string_pretty(&val) {
                        let _ = atomic_write_file(&claude_settings, &updated);
                        tracing::info!(
                            path = %claude_settings.display(),
                            "Configured Claude Code hooks"
                        );
                    }
                }
            }
        }
    }
}

fn atomic_write_file(path: &std::path::Path, content: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = path.with_extension(format!("tmp.{}.{}", std::process::id(), nanos));
    std::fs::write(&tmp, content)?;
    if let Err(err) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(err);
    }
    Ok(())
}

/// Directory for the daemon's stdout/stderr logs. Only macOS needs this: the
/// LaunchAgent plist redirects the daemon's streams here. systemd captures
/// stdout via the journal, and the Windows logon task runs the daemon detached
/// (it logs through `triage_core::logging`'s file appender either way).
#[cfg(target_os = "macos")]
fn default_log_dir() -> Result<PathBuf> {
    Ok(home_dir()?.join("Library/Logs/triage"))
}

/// Path of the file the Windows daemon writes its PID to, so `service stop` can
/// target exactly this process instead of every `triaged.exe` the user owns.
/// `launchctl` / `systemctl --user` already track the process on Unix, so this
/// is Windows-only.
#[cfg(target_os = "windows")]
fn pid_file_path() -> Option<PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("USERPROFILE")
                .map(|home| PathBuf::from(home).join("AppData").join("Local"))
        })?;
    Some(base.join("triage").join("triaged.pid"))
}

/// Record the running daemon's PID for `service stop`. Best-effort: a failure
/// here just means `stop` falls back to killing by image name. Called once at
/// daemon startup. Handover is Unix-only, so on Windows there is exactly one
/// daemon process and the file never goes stale mid-run.
#[cfg(windows)]
pub fn record_running_pid() {
    if let Some(path) = pid_file_path() {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&path, std::process::id().to_string());
    }
}

// ---------------------------------------------------------------------------
// Pure template builders (unit-tested on every platform)
// ---------------------------------------------------------------------------

/// XML-escape a string for safe inclusion in a `.plist` body. Paths rarely
/// contain these characters, but escaping keeps a `&` in a home directory from
/// producing malformed XML.
#[cfg(any(target_os = "macos", test))]
fn xml_escape(input: &str) -> String {
    input
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Seconds launchd waits between respawns of the daemon. Deliberately above
/// launchd's 10s default: a binary that cannot launch at all — e.g. one macOS
/// SIGKILLs for an invalid code signature after an in-place upgrade — is
/// otherwise retried every 10s indefinitely.
#[cfg(any(target_os = "macos", test))]
const THROTTLE_INTERVAL_SECS: u32 = 30;

#[cfg(any(target_os = "macos", test))]
const _: () = assert!(
    THROTTLE_INTERVAL_SECS > 10,
    "the throttle must exceed launchd's 10s default, or it slows nothing down"
);

/// Seconds launchd waits after SIGTERM before escalating to SIGKILL.
///
/// launchd silently caps `ExitTimeOut` at 60 seconds (any value above 60 is
/// replaced with 60 by launchd). Setting 60 requests the true maximum grace
/// period launchd will grant.
#[cfg(any(target_os = "macos", test))]
const LAUNCHD_STOP_GRACE_SECS: u32 = 60;

#[cfg(any(target_os = "macos", test))]
const _: () = assert!(
    LAUNCHD_STOP_GRACE_SECS == 60,
    "launchd caps ExitTimeOut at 60s, so setting any other value either requests less \
     grace than available or claims a budget launchd silently ignores"
);

/// Seconds systemd waits after SIGTERM before escalating to SIGKILL.
///
/// systemd's default is 90s, and a SIGTERM'd daemon answers by starting a
/// successor and handing it every live session (see `crate::shutdown`), which takes
/// as long as a cold start (session log replay and warm-up). An escalation to
/// SIGKILL mid-rescue destroys exactly the sessions the rescue is saving. Unlike
/// launchd, systemd has no 60s cap on `TimeoutStopSec`, so 150s provides ample
/// headroom exceeding `SHUTDOWN_RESCUE_TIMEOUT` (90s).
#[cfg(any(target_os = "linux", test))]
const SYSTEMD_STOP_GRACE_SECS: u32 = 150;

#[cfg(any(target_os = "linux", test))]
const _: () = assert!(
    SYSTEMD_STOP_GRACE_SECS as u64 > crate::handover::SHUTDOWN_RESCUE_TIMEOUT.as_secs(),
    "the systemd stop grace period must outlast the session rescue, or SIGKILL lands \
     mid-handover and takes every live session with it"
);

/// macOS LaunchAgent plist that runs `exe` at load, keeps it alive, and captures
/// stdout/stderr to the given log files.
///
/// `KeepAlive` stays unconditional. Making it conditional on `SuccessfulExit`
/// looks tempting: it would stop launchd respawning the job after the clean
/// exit that ends a handover, but that respawn is load-bearing: it is how
/// supervision returns to a launchd-owned process after a manual handover (see
/// `devlog/000085-fix-daemon-smart-start.md`), and `main`'s refused-teardown
/// path documents that it relies on being respawned regardless of exit status.
#[cfg(any(target_os = "macos", test))]
fn plist_contents(exe: &Path, stdout_log: &Path, stderr_log: &Path) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{exe}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>{throttle}</integer>
    <key>ExitTimeOut</key>
    <integer>{stop_grace}</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>{stdout}</string>
    <key>StandardErrorPath</key>
    <string>{stderr}</string>
</dict>
</plist>
"#,
        label = SERVICE_LABEL,
        exe = xml_escape(&exe.display().to_string()),
        throttle = THROTTLE_INTERVAL_SECS,
        stop_grace = LAUNCHD_STOP_GRACE_SECS,
        stdout = xml_escape(&stdout_log.display().to_string()),
        stderr = xml_escape(&stderr_log.display().to_string()),
    )
}

/// systemd `--user` unit that runs `exe` and restarts it after every exit. `ExecStart`
/// is quoted so a home directory with spaces still parses.
///
/// `KillMode=process` is load-bearing, not a preference. systemd's default
/// (`control-group`) signals *every* process left in the unit's cgroup on stop, and
/// `setsid` does not move a process out of a cgroup, so the successor the daemon starts
/// to carry its live sessions across a stop (see `crate::shutdown`) would be killed
/// along with the daemon that started it, and every session child with it. With
/// `process`, systemd signals only the main process and lets the rescue work, which is
/// the same relationship launchd already has with a `setsid`-detached child.
#[cfg(any(target_os = "linux", test))]
fn systemd_unit_contents(exe: &Path) -> String {
    format!(
        "[Unit]\n\
         Description=Triage terminal session daemon\n\
         After=default.target\n\
         \n\
         [Service]\n\
         Type=simple\n\
         ExecStart=\"{exe}\"\n\
         Restart=always\n\
         RestartSec=2\n\
         TimeoutStopSec={stop_grace}\n\
         KillMode=process\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n",
        exe = exe.display(),
        stop_grace = SYSTEMD_STOP_GRACE_SECS,
    )
}

/// `schtasks /Create` arguments for a logon task that launches `exe` without a
/// visible console window (`cmd /c start "" /b` detaches it from a console).
#[cfg(any(target_os = "windows", test))]
fn schtasks_create_args(exe: &Path) -> Vec<String> {
    let run = format!(r#"cmd /c start "" /b "{}""#, exe.display());
    vec![
        "/Create".to_string(),
        "/TN".to_string(),
        SERVICE_NAME.to_string(),
        "/TR".to_string(),
        run,
        "/SC".to_string(),
        "ONLOGON".to_string(),
        "/RL".to_string(),
        "LIMITED".to_string(),
        "/F".to_string(),
    ]
}

/// Tell a running daemon that the stop we are about to request is a real one.
///
/// `stop` and `uninstall` work by asking the supervisor to stop the job, which
/// arrives at the daemon as a SIGTERM, and a SIGTERM is answered by handing every
/// live session to a detached successor rather than dying (see
/// [`crate::shutdown`]). That is right for a bootout, a logout, or a stray `kill`,
/// and wrong here: the operator asked for a stop, and `uninstall` in particular
/// must not leave a daemon running.
///
/// Best-effort by design. No daemon running, an older daemon that does not know
/// the request, a socket that has gone stale: none of those should stop an
/// uninstall, and all of them mean there is nothing that would resurrect itself.
///
/// The suppression it asks for expires on its own (see
/// `crate::shutdown::disable_rescue`), which matters because this runs *before* the
/// stop is attempted: a stop that then fails must not leave a still-running daemon
/// permanently unable to save its sessions.
#[cfg(unix)]
fn disable_daemon_shutdown_rescue() {
    let socket_path = crate::ipc::default_socket_path();
    if let Err(error) = crate::ipc::IpcClient::new(socket_path).disable_shutdown_rescue() {
        tracing::debug!(%error, "could not disable the daemon's shutdown rescue before stopping");
    }
}

/// Windows has no handover and so no shutdown rescue to disable.
#[cfg(not(unix))]
fn disable_daemon_shutdown_rescue() {}

// ---------------------------------------------------------------------------
// Platform side effects
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use std::process::Command;

    fn agent_path() -> Result<PathBuf> {
        Ok(home_dir()?
            .join("Library/LaunchAgents")
            .join(format!("{SERVICE_LABEL}.plist")))
    }

    fn launchctl(args: &[&str]) -> Result<std::process::ExitStatus> {
        Command::new("launchctl")
            .args(args)
            .status()
            .context("running launchctl (is this macOS?)")
    }

    pub(super) fn install(ctx: &ServiceContext) -> Result<()> {
        let plist = agent_path()?;
        if let Some(parent) = plist.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        let log_dir = default_log_dir()?;
        std::fs::create_dir_all(&log_dir)
            .with_context(|| format!("creating {}", log_dir.display()))?;
        let stdout_log = log_dir.join("triaged.out.log");
        let stderr_log = log_dir.join("triaged.err.log");
        std::fs::write(&plist, plist_contents(&ctx.exe, &stdout_log, &stderr_log))
            .with_context(|| format!("writing {}", plist.display()))?;

        // Reload cleanly if a previous agent is already loaded, then load with
        // `-w` so it persists across logins.
        let _ = launchctl(&["unload", &plist.display().to_string()]);
        let status = launchctl(&["load", "-w", &plist.display().to_string()])?;
        if !status.success() {
            bail!(
                "launchctl load failed; the LaunchAgent was written to {} but not loaded",
                plist.display()
            );
        }
        println!(
            "Installed and started triaged LaunchAgent ({SERVICE_LABEL}).\n  plist: {}\n  logs:  {}",
            plist.display(),
            log_dir.display()
        );
        println!(
            "Note: a daemon that was already running hands its live sessions to a replacement \
             before restarting, so this can take up to a minute with many sessions open. On the \
             first install after upgrading, the job being replaced is still governed by the old \
             plist's shorter stop timeout, so that one handover can be cut short."
        );
        super::install_global_agent_hooks();
        Ok(())
    }

    pub(super) fn uninstall(_ctx: &ServiceContext) -> Result<()> {
        let plist = agent_path()?;
        if plist.exists() {
            let _ = launchctl(&["unload", "-w", &plist.display().to_string()]);
            std::fs::remove_file(&plist)
                .with_context(|| format!("removing {}", plist.display()))?;
            println!("Removed triaged LaunchAgent ({SERVICE_LABEL}).");
        } else {
            println!("triaged LaunchAgent is not installed.");
        }
        Ok(())
    }

    pub(super) fn start(_ctx: &ServiceContext) -> Result<()> {
        let status = launchctl(&["start", SERVICE_LABEL])?;
        if !status.success() {
            bail!("launchctl start failed; is the service installed? (triaged service install)");
        }
        println!("Started triaged.");
        Ok(())
    }

    pub(super) fn stop(_ctx: &ServiceContext) -> Result<()> {
        launchctl(&["stop", SERVICE_LABEL])?;
        println!("Stopped triaged.");
        Ok(())
    }

    pub(super) fn restart(_ctx: &ServiceContext) -> Result<()> {
        super::reload_daemon()
    }

    pub(super) fn status(_ctx: &ServiceContext) -> Result<()> {
        let status = launchctl(&["list", SERVICE_LABEL])?;
        if !status.success() {
            println!("triaged is not loaded (run: triaged service install).");
        }
        Ok(())
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use std::process::Command;

    fn unit_name() -> String {
        format!("{SERVICE_NAME}.service")
    }

    fn unit_path() -> Result<PathBuf> {
        Ok(home_dir()?.join(".config/systemd/user").join(unit_name()))
    }

    fn systemctl(args: &[&str]) -> Result<std::process::ExitStatus> {
        Command::new("systemctl")
            .arg("--user")
            .args(args)
            .status()
            .context("running systemctl --user (is systemd available?)")
    }

    pub(super) fn install(ctx: &ServiceContext) -> Result<()> {
        let unit = unit_path()?;
        if let Some(parent) = unit.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        std::fs::write(&unit, systemd_unit_contents(&ctx.exe))
            .with_context(|| format!("writing {}", unit.display()))?;

        systemctl(&["daemon-reload"])?;
        let status = systemctl(&["enable", "--now", &unit_name()])?;
        if !status.success() {
            bail!(
                "systemctl --user enable --now failed; the unit was written to {} but not enabled",
                unit.display()
            );
        }
        println!(
            "Installed and started triaged systemd unit ({}).\n  unit: {}\n\
             Tip: run `loginctl enable-linger {}` to keep triaged running after you log out.",
            unit_name(),
            unit.display(),
            whoami()
        );
        super::install_global_agent_hooks();
        Ok(())
    }

    pub(super) fn uninstall(_ctx: &ServiceContext) -> Result<()> {
        let unit = unit_path()?;
        if unit.exists() {
            let _ = systemctl(&["disable", "--now", &unit_name()]);
            std::fs::remove_file(&unit).with_context(|| format!("removing {}", unit.display()))?;
            systemctl(&["daemon-reload"])?;
            println!("Removed triaged systemd unit ({}).", unit_name());
        } else {
            println!("triaged systemd unit is not installed.");
        }
        Ok(())
    }

    pub(super) fn start(_ctx: &ServiceContext) -> Result<()> {
        let status = systemctl(&["start", &unit_name()])?;
        if !status.success() {
            bail!(
                "systemctl --user start failed; is the service installed? (triaged service install)"
            );
        }
        println!("Started triaged.");
        Ok(())
    }

    pub(super) fn stop(_ctx: &ServiceContext) -> Result<()> {
        systemctl(&["stop", &unit_name()])?;
        println!("Stopped triaged.");
        Ok(())
    }

    pub(super) fn restart(_ctx: &ServiceContext) -> Result<()> {
        super::reload_daemon()
    }

    pub(super) fn status(_ctx: &ServiceContext) -> Result<()> {
        // `status` exits non-zero when inactive; surface its output regardless.
        systemctl(&["status", &unit_name()])?;
        Ok(())
    }

    fn whoami() -> String {
        std::env::var("USER").unwrap_or_else(|_| "<user>".to_string())
    }
}

#[cfg(target_os = "windows")]
mod platform {
    use super::*;
    use std::process::Command;

    fn schtasks(args: &[String]) -> Result<std::process::ExitStatus> {
        Command::new("schtasks")
            .args(args)
            .status()
            .context("running schtasks (is this Windows?)")
    }

    pub(super) fn install(ctx: &ServiceContext) -> Result<()> {
        let status = schtasks(&schtasks_create_args(&ctx.exe))?;
        if !status.success() {
            bail!("schtasks /Create failed; could not register the logon task");
        }
        // Start it now so the user doesn't have to log out and back in.
        let _ = schtasks(&[
            "/Run".to_string(),
            "/TN".to_string(),
            SERVICE_NAME.to_string(),
        ]);
        println!(
            "Installed and started triaged logon task ({SERVICE_NAME}). It will start automatically at each login."
        );
        super::install_global_agent_hooks();
        Ok(())
    }

    pub(super) fn uninstall(_ctx: &ServiceContext) -> Result<()> {
        let _ = stop(_ctx);
        if let Some(path) = pid_file_path() {
            let _ = std::fs::remove_file(path);
        }
        let status = schtasks(&[
            "/Delete".to_string(),
            "/TN".to_string(),
            SERVICE_NAME.to_string(),
            "/F".to_string(),
        ])?;
        if status.success() {
            println!("Removed triaged logon task ({SERVICE_NAME}).");
        } else {
            println!("triaged logon task is not installed.");
        }
        Ok(())
    }

    pub(super) fn start(_ctx: &ServiceContext) -> Result<()> {
        let status = schtasks(&[
            "/Run".to_string(),
            "/TN".to_string(),
            SERVICE_NAME.to_string(),
        ])?;
        if !status.success() {
            bail!("schtasks /Run failed; is the service installed? (triaged service install)");
        }
        println!("Started triaged.");
        Ok(())
    }

    pub(super) fn stop(_ctx: &ServiceContext) -> Result<()> {
        // The logon task launches the daemon detached, so there's no task
        // instance to end — kill the process directly. Prefer the PID the daemon
        // recorded at startup so we stop exactly the service-managed daemon and
        // not a triaged the user started by hand. The PID file can be stale (the
        // daemon was force-killed last time, or its PID was reused), so only the
        // image-name-filtered kill counts as success; otherwise fall back to
        // killing by image name.
        let killed_by_pid = recorded_pid().is_some_and(taskkill_pid);
        if !killed_by_pid {
            // Fall back to killing by image name — but exclude our own PID: this
            // CLI (`triaged service stop` / `uninstall`) is itself a triaged.exe,
            // so a blanket `/IM` would terminate the command mid-run (e.g.
            // `uninstall` would never reach `schtasks /Delete`).
            let _ = Command::new("taskkill")
                .args([
                    "/FI",
                    "IMAGENAME eq triaged.exe",
                    "/FI",
                    &format!("PID ne {}", std::process::id()),
                    "/F",
                ])
                .status();
        }
        // Always drop the PID file so a stale PID is never read again.
        if let Some(path) = pid_file_path() {
            let _ = std::fs::remove_file(path);
        }
        println!("Stopped triaged.");
        Ok(())
    }

    /// Force-kill `pid`, but only if it is actually a `triaged.exe` (the recorded
    /// PID may be stale and reused by an unrelated process). Returns whether a
    /// matching process was killed.
    fn taskkill_pid(pid: u32) -> bool {
        Command::new("taskkill")
            .args([
                "/FI",
                &format!("PID eq {pid}"),
                "/FI",
                "IMAGENAME eq triaged.exe",
                "/F",
            ])
            .status()
            .is_ok_and(|status| status.success())
    }

    /// The PID the running daemon recorded at startup, if the file is present
    /// and parseable.
    fn recorded_pid() -> Option<u32> {
        let path = pid_file_path()?;
        std::fs::read_to_string(path)
            .ok()?
            .trim()
            .parse::<u32>()
            .ok()
    }

    pub(super) fn restart(ctx: &ServiceContext) -> Result<()> {
        let _ = stop(ctx);
        start(ctx)
    }

    pub(super) fn status(_ctx: &ServiceContext) -> Result<()> {
        let status = schtasks(&[
            "/Query".to_string(),
            "/TN".to_string(),
            SERVICE_NAME.to_string(),
        ])?;
        if !status.success() {
            println!("triaged logon task is not installed (run: triaged service install).");
        }
        Ok(())
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
mod platform {
    use super::*;

    fn unsupported() -> Result<()> {
        bail!(
            "`triaged service` is not supported on this platform; run `triaged` directly to start the daemon"
        )
    }

    pub(super) fn install(_ctx: &ServiceContext) -> Result<()> {
        unsupported()
    }
    pub(super) fn uninstall(_ctx: &ServiceContext) -> Result<()> {
        unsupported()
    }
    pub(super) fn start(_ctx: &ServiceContext) -> Result<()> {
        unsupported()
    }
    pub(super) fn stop(_ctx: &ServiceContext) -> Result<()> {
        unsupported()
    }
    pub(super) fn status(_ctx: &ServiceContext) -> Result<()> {
        unsupported()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plist_embeds_exe_and_logs() {
        let body = plist_contents(
            Path::new("/usr/local/bin/triaged"),
            Path::new("/tmp/out.log"),
            Path::new("/tmp/err.log"),
        );
        assert!(body.contains("<string>com.hyeons-lab.triaged</string>"));
        assert!(body.contains("<string>/usr/local/bin/triaged</string>"));
        assert!(body.contains("<string>/tmp/out.log</string>"));
        assert!(body.contains("<string>/tmp/err.log</string>"));
        assert!(body.contains("<key>RunAtLoad</key>"));
        assert!(body.contains("<key>KeepAlive</key>"));
    }

    /// The daemon must stay supervised unconditionally, but a binary launchd
    /// cannot start — one macOS SIGKILLs for an invalid code signature after an
    /// in-place upgrade — must not be retried at launchd's 10s default forever.
    #[test]
    fn plist_keeps_alive_unconditionally_and_throttles_respawns() {
        let body = plist_contents(
            Path::new("/usr/local/bin/triaged"),
            Path::new("/tmp/out.log"),
            Path::new("/tmp/err.log"),
        );

        // KeepAlive must stay unconditional. Making it depend on SuccessfulExit
        // would stop launchd respawning the job after a handover's clean exit,
        // which is how supervision returns to a launchd-owned process.
        assert!(
            body.contains("<key>KeepAlive</key>\n    <true/>"),
            "KeepAlive must be unconditional <true/>: {body}"
        );

        // The value must belong to the ThrottleInterval key, not merely appear
        // somewhere in the plist. (That it exceeds launchd's 10s default is
        // pinned by a compile-time assertion on the constant itself.)
        let throttle = body
            .split_once("<key>ThrottleInterval</key>")
            .expect("plist declares ThrottleInterval")
            .1;
        assert!(
            throttle
                .trim_start()
                .starts_with(&format!("<integer>{THROTTLE_INTERVAL_SECS}</integer>")),
            "ThrottleInterval must be followed by its value: {throttle}"
        );
    }

    /// The daemon answers SIGTERM by handing its live sessions to a successor
    /// rather than dying (`crate::shutdown`), and that takes as long as a cold
    /// start. launchd's 20s default and systemd's 90s default both escalate to
    /// SIGKILL partway through.
    ///
    /// macOS launchd silently caps ExitTimeOut at 60s (values above 60 are
    /// replaced by 60 outright), while systemd TimeoutStopSec has no such cap and
    /// is set to 150s to provide headroom exceeding the rescue budget.
    #[test]
    fn units_grant_the_session_rescue_time_to_finish() {
        let plist = plist_contents(
            Path::new("/usr/local/bin/triaged"),
            Path::new("/tmp/out.log"),
            Path::new("/tmp/err.log"),
        );
        let exit_timeout = plist
            .split_once("<key>ExitTimeOut</key>")
            .expect("plist declares ExitTimeOut")
            .1;
        assert!(
            exit_timeout
                .trim_start()
                .starts_with(&format!("<integer>{LAUNCHD_STOP_GRACE_SECS}</integer>")),
            "ExitTimeOut must be followed by its value: {exit_timeout}"
        );

        let unit = systemd_unit_contents(Path::new("/home/me/.cargo/bin/triaged"));
        assert!(
            unit.contains(&format!("TimeoutStopSec={SYSTEMD_STOP_GRACE_SECS}")),
            "the systemd unit must extend the stop timeout: {unit}"
        );
        // A longer timeout is useless on its own under systemd: the default kill mode
        // takes the whole cgroup, including the successor the rescue just handed the
        // sessions to.
        assert!(
            unit.contains("KillMode=process"),
            "the systemd unit must not let a stop reap the rescue's successor: {unit}"
        );
    }

    #[test]
    fn plist_escapes_xml_metacharacters() {
        let body = plist_contents(
            Path::new("/home/a&b/triaged"),
            Path::new("/tmp/out.log"),
            Path::new("/tmp/err.log"),
        );
        assert!(body.contains("/home/a&amp;b/triaged"));
        assert!(!body.contains("a&b/triaged"));
    }

    #[test]
    fn systemd_unit_quotes_execstart_and_restarts() {
        let unit = systemd_unit_contents(Path::new("/home/me/.cargo/bin/triaged"));
        assert!(unit.contains("ExecStart=\"/home/me/.cargo/bin/triaged\""));
        assert!(unit.contains("Restart=always"));
        assert!(unit.contains("WantedBy=default.target"));
    }

    #[test]
    fn schtasks_args_create_a_windowless_logon_task() {
        let args = schtasks_create_args(Path::new(r"C:\Users\me\triaged.exe"));
        assert_eq!(args[0], "/Create");
        // The task name and logon schedule are present.
        let joined = args.join(" ");
        assert!(joined.contains("/TN triaged"));
        assert!(joined.contains("/SC ONLOGON"));
        // The run command detaches from a console so no window flashes at logon.
        assert!(
            args.iter()
                .any(|a| a.contains(r#"start "" /b "C:\Users\me\triaged.exe""#))
        );
    }
}
