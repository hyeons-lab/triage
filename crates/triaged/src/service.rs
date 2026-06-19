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
    match action {
        "install" => platform::install(&ServiceContext::detect()?),
        "uninstall" => platform::uninstall(&ServiceContext::detect()?),
        "start" => platform::start(&ServiceContext::detect()?),
        "stop" => platform::stop(&ServiceContext::detect()?),
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
        "Usage: triaged service <install|uninstall|start|stop|status>\n\
         \n\
         install    register triaged to start at login and start it now\n\
         uninstall  stop triaged and remove the login registration\n\
         start      start the installed service\n\
         stop       stop the installed service\n\
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
        let exe = std::env::current_exe()
            .context("resolving the triaged executable path for service registration")?;
        Ok(Self { exe })
    }
}

/// `$HOME` as a path. Used to place the LaunchAgent plist (macOS) and the
/// systemd user unit (Linux); the Windows logon task needs no home lookup.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn home_dir() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .context("neither HOME nor USERPROFILE environment variable is set")?;
    Ok(PathBuf::from(home))
}

/// Directory for the daemon's stdout/stderr logs. Only macOS needs this: the
/// LaunchAgent plist redirects the daemon's streams here. systemd captures
/// stdout via the journal, and the Windows logon task runs the daemon detached
/// (it logs through `triage_core::logging`'s file appender either way).
#[cfg(target_os = "macos")]
fn default_log_dir() -> Result<PathBuf> {
    Ok(home_dir()?.join("Library/Logs/triage"))
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

/// macOS LaunchAgent plist that runs `exe` at load, keeps it alive, and captures
/// stdout/stderr to the given log files.
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
        stdout = xml_escape(&stdout_log.display().to_string()),
        stderr = xml_escape(&stderr_log.display().to_string()),
    )
}

/// systemd `--user` unit that runs `exe` and restarts it on failure. `ExecStart`
/// is quoted so a home directory with spaces still parses.
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
         Restart=on-failure\n\
         RestartSec=2\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n",
        exe = exe.display(),
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
            bail!("launchctl load failed; the LaunchAgent was written to {} but not loaded", plist.display());
        }
        println!(
            "Installed and started triaged LaunchAgent ({SERVICE_LABEL}).\n  plist: {}\n  logs:  {}",
            plist.display(),
            log_dir.display()
        );
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
        Ok(home_dir()?
            .join(".config/systemd/user")
            .join(unit_name()))
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
        Ok(())
    }

    pub(super) fn uninstall(_ctx: &ServiceContext) -> Result<()> {
        let unit = unit_path()?;
        if unit.exists() {
            let _ = systemctl(&["disable", "--now", &unit_name()]);
            std::fs::remove_file(&unit)
                .with_context(|| format!("removing {}", unit.display()))?;
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
            bail!("systemctl --user start failed; is the service installed? (triaged service install)");
        }
        println!("Started triaged.");
        Ok(())
    }

    pub(super) fn stop(_ctx: &ServiceContext) -> Result<()> {
        systemctl(&["stop", &unit_name()])?;
        println!("Stopped triaged.");
        Ok(())
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
        Ok(())
    }

    pub(super) fn uninstall(_ctx: &ServiceContext) -> Result<()> {
        let _ = stop(_ctx);
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
        // Best-effort: kill any running daemon process. The task itself only
        // runs at logon, so there is no long-lived task instance to end.
        let _ = Command::new("taskkill")
            .args(["/IM", "triaged.exe", "/F"])
            .status();
        println!("Stopped triaged.");
        Ok(())
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
        assert!(unit.contains("Restart=on-failure"));
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
        assert!(args.iter().any(|a| a.contains(r#"start "" /b "C:\Users\me\triaged.exe""#)));
    }
}
