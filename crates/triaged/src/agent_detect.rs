//! Detect AI coding agents running inside session PTYs.
//!
//! Each triage session is a shell, but the interesting occupant is usually an
//! agent TUI (Claude Code, Codex, Antigravity, Muse) running inside it. This
//! module identifies those agents from process names and argv, resolves their
//! conversation ids, and builds resume commands, so a session restored after
//! a reboot can re-enter the same conversation instead of a fresh shell.
//!
//! Detection is read-only observation: process names, argv, and transcript
//! metadata. Transcript *content* is never read.

use std::path::{Path, PathBuf};

pub use triage_core::agent::{AgentAttachment, AgentKind};

/// Whether an agent invocation runs an interactive session or a one-shot
/// headless task. Only interactive runs are tracked: resuming a
/// `--print`/`exec` invocation is meaningless.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentRunMode {
    Interactive,
    Headless,
}

/// Classified agent argv: run mode plus a conversation id when argv carries
/// one (agents started fresh have none; see transcript correlation).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentArgv {
    pub mode: AgentRunMode,
    pub conversation_id: Option<String>,
}

/// Classify an agent command line. `argv` includes argv[0].
///
/// Returns `None` when the invocation is not a trackable agent run at all
/// (`--help`, `--version`, `mcp`/`login` bookkeeping subcommands, ...),
/// so session plumbing never masquerades as an agent to resume.
pub fn classify_argv(kind: AgentKind, argv: &[String]) -> Option<AgentArgv> {
    let args: Vec<&str> = argv.iter().skip(1).map(String::as_str).collect();
    match kind {
        AgentKind::Claude => classify_claude(&args),
        AgentKind::Codex => classify_codex(&args),
        AgentKind::Antigravity => classify_agy(&args),
        AgentKind::Muse => classify_muse(&args),
    }
}

/// Positional tokens that are not flag values: a non-flag token immediately
/// following a flag token is treated as that flag's value and skipped. This
/// misreads a subcommand after a boolean flag as a value, which degrades to
/// "bare interactive run" rather than a wrong classification.
fn positional_tokens<'a>(args: &[&'a str]) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut prev_was_flag = false;
    for arg in args {
        if arg.starts_with('-') {
            prev_was_flag = true;
            continue;
        }
        if prev_was_flag {
            prev_was_flag = false;
            continue;
        }
        out.push(*arg);
    }
    out
}

/// Value of `--flag value` or `--flag=value` for a long flag.
fn long_flag_value<'a>(args: &[&'a str], flag: &str) -> Option<&'a str> {
    let mut iter = args.iter().peekable();
    while let Some(arg) = iter.next() {
        if let Some(value) = arg.strip_prefix(&format!("{flag}=")) {
            return Some(value);
        }
        if *arg == flag {
            return iter.next().copied();
        }
    }
    None
}

fn classify_claude(args: &[&str]) -> Option<AgentArgv> {
    if args.iter().any(|a| *a == "--help" || *a == "-h") {
        return None;
    }
    if args.iter().any(|a| *a == "--version" || *a == "-V") {
        return None;
    }
    if positional_tokens(args).first() == Some(&"mcp") {
        return None;
    }
    let mode = if args.iter().any(|a| *a == "--print" || *a == "-p") {
        AgentRunMode::Headless
    } else {
        AgentRunMode::Interactive
    };
    Some(AgentArgv {
        mode,
        conversation_id: long_flag_value(args, "--resume").map(str::to_string),
    })
}

fn classify_codex(args: &[&str]) -> Option<AgentArgv> {
    if args.iter().any(|a| *a == "--help" || *a == "-h") {
        return None;
    }
    if args.iter().any(|a| *a == "--version" || *a == "-V") {
        return None;
    }
    let positionals = positional_tokens(args);
    match positionals.first().copied() {
        // `codex exec|review` (and short alias `e`) run headless one-shots.
        Some("exec" | "e" | "review") => Some(AgentArgv {
            mode: AgentRunMode::Headless,
            conversation_id: None,
        }),
        // `codex resume [SESSION_ID] [PROMPT]`: the id is the next positional.
        Some("resume") => Some(AgentArgv {
            mode: AgentRunMode::Interactive,
            conversation_id: positionals.get(1).map(ToString::to_string),
        }),
        // Bookkeeping subcommands are not agent runs.
        Some(
            "login" | "logout" | "mcp" | "plugin" | "app-server" | "app" | "completion" | "update"
            | "doctor" | "sandbox" | "debug" | "apply" | "a" | "queue" | "archive" | "delete"
            | "migrate-rollouts" | "unarchive" | "fork" | "cloud" | "exec-server" | "features"
            | "agents" | "help",
        ) => None,
        // Anything else (including bare `codex` and `codex "prompt"`) is the
        // interactive TUI: an unknown token is prompt text, not a subcommand.
        _ => Some(AgentArgv {
            mode: AgentRunMode::Interactive,
            conversation_id: None,
        }),
    }
}

fn classify_agy(args: &[&str]) -> Option<AgentArgv> {
    if args
        .iter()
        .any(|a| *a == "--help" || *a == "-h" || *a == "help")
    {
        return None;
    }
    if positional_tokens(args).first().is_some_and(|sub| {
        matches!(
            *sub,
            "agent"
                | "agents"
                | "changelog"
                | "install"
                | "mcp"
                | "mic-serve"
                | "models"
                | "plugin"
                | "plugins"
                | "remote-control"
                | "update"
                | "help"
        )
    }) {
        return None;
    }
    let mode = if args
        .iter()
        .any(|a| *a == "--print" || *a == "-p" || *a == "--prompt")
    {
        AgentRunMode::Headless
    } else {
        AgentRunMode::Interactive
    };
    Some(AgentArgv {
        mode,
        conversation_id: long_flag_value(args, "--conversation").map(str::to_string),
    })
}

fn classify_muse(args: &[&str]) -> Option<AgentArgv> {
    if args.iter().any(|a| *a == "--help" || *a == "-h") {
        return None;
    }
    if args.iter().any(|a| *a == "--version" || *a == "-V") {
        return None;
    }
    let positionals = positional_tokens(args);
    match positionals.first().copied() {
        Some("exec") => Some(AgentArgv {
            mode: AgentRunMode::Headless,
            conversation_id: None,
        }),
        // `muse resume [--last|<session-ref>]`.
        Some("resume") => Some(AgentArgv {
            mode: AgentRunMode::Interactive,
            conversation_id: positionals.get(1).map(ToString::to_string),
        }),
        Some(
            "config" | "export" | "trace" | "skills" | "plugins" | "sandbox" | "schema" | "serve"
            | "session-message" | "mcp" | "auth" | "login" | "logout" | "init" | "help",
        ) => None,
        // Bare `muse`, `muse "prompt"`, or an unknown token (prompt text).
        _ => Some(AgentArgv {
            mode: AgentRunMode::Interactive,
            conversation_id: None,
        }),
    }
}

/// Build the command restoring an agent conversation: resume the given id,
/// or the agent's most-recent conversation when no id is known.
pub fn resume_command(kind: AgentKind, conversation_id: Option<&str>) -> (String, Vec<String>) {
    let args: Vec<String> = match (kind, conversation_id) {
        (AgentKind::Claude, Some(id)) => vec!["--resume".into(), id.into()],
        (AgentKind::Claude, None) => vec!["--continue".into()],
        (AgentKind::Codex, Some(id)) => vec!["resume".into(), id.into()],
        (AgentKind::Codex, None) => vec!["resume".into(), "--last".into()],
        (AgentKind::Antigravity, Some(id)) => vec!["--conversation".into(), id.into()],
        (AgentKind::Antigravity, None) => vec!["--continue".into()],
        (AgentKind::Muse, Some(id)) => vec!["resume".into(), id.into()],
        (AgentKind::Muse, None) => vec!["resume".into(), "--last".into()],
    };
    (kind.primary_binary().to_string(), args)
}

/// Home directory following the repo convention (`HOME`, else `USERPROFILE`).
fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

/// Root of an agent's local transcript store, or `None` when the home
/// directory is unknown (Antigravity has no known local store at all).
pub fn transcript_store_root(kind: AgentKind) -> Option<PathBuf> {
    match kind {
        AgentKind::Antigravity => None,
        _ => {
            let home = home_dir()?;
            Some(match kind {
                AgentKind::Claude => home.join(".claude").join("projects"),
                AgentKind::Codex => home.join(".codex").join("sessions"),
                AgentKind::Muse => std::env::var_os("XDG_DATA_HOME")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| home.join(".local").join("share"))
                    .join("muse")
                    .join("sessions"),
                AgentKind::Antigravity => unreachable!("handled above"),
            })
        }
    }
}

/// Claude's project directory for a cwd: the absolute path with every `/`
/// replaced by `-` (e.g. `/Users/me/repo` becomes `-Users-me-repo`).
/// Returns `None` for relative cwds, which have no stable mapping.
pub fn claude_project_dir(projects_root: &Path, cwd: &Path) -> Option<PathBuf> {
    if !cwd.is_absolute() {
        return None;
    }
    let slug: String = cwd
        .to_string_lossy()
        .chars()
        .map(|c| if c == '/' { '-' } else { c })
        .collect();
    Some(projects_root.join(slug))
}

/// A transcript file plausibly belonging to a live agent: conversation id,
/// transcript path, and the working directory the transcript records.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptHit {
    pub conversation_id: String,
    pub path: PathBuf,
    pub cwd: PathBuf,
}

/// Outcome of transcript correlation for one agent process.
///
/// `Single` requires exactly one fresh candidate: with several live agents
/// sharing a directory, newest-file matching misattributes, and resuming
/// the wrong conversation is worse than a shell, so contenders degrade to
/// `Multiple` (kind-only tracking) rather than a guess.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Correlation {
    None,
    Single(TranscriptHit),
    Multiple,
}

/// Correlate an agent process (by its cwd, and pid when known) to a
/// transcript written within `max_age` of `now`. Store roots are parameters
/// so tests run against fixture dirs.
///
/// Antigravity has no known local store and always correlates `None`.
pub fn correlate(
    kind: AgentKind,
    store_root: Option<&Path>,
    cwd: &Path,
    pid: Option<u32>,
    now: std::time::SystemTime,
    max_age: std::time::Duration,
) -> Correlation {
    let Some(root) = store_root else {
        return Correlation::None;
    };
    let candidates = match kind {
        AgentKind::Claude => claude_candidates(root, cwd, now, max_age),
        AgentKind::Codex => codex_candidates(root, cwd, now, max_age),
        AgentKind::Antigravity => return Correlation::None,
        AgentKind::Muse => muse_candidates(root, cwd, pid, now, max_age),
    };
    match candidates.len() {
        0 => Correlation::None,
        1 => Correlation::Single(candidates.into_iter().next().unwrap()),
        _ => Correlation::Multiple,
    }
}

/// Canonicalize for comparison, falling back to the raw path when the file
/// is gone (macOS `/tmp` symlinks make raw comparison unreliable).
fn canonical_or_raw(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn is_fresh(path: &Path, now: std::time::SystemTime, max_age: std::time::Duration) -> bool {
    let Ok(modified) = std::fs::metadata(path).and_then(|m| m.modified()) else {
        return false;
    };
    // A transcript newer than `now` (clock skew) counts as fresh: its age
    // saturates at zero rather than reading as ancient.
    now.duration_since(modified).unwrap_or_default() <= max_age
}

fn claude_candidates(
    projects_root: &Path,
    cwd: &Path,
    now: std::time::SystemTime,
    max_age: std::time::Duration,
) -> Vec<TranscriptHit> {
    let Some(dir) = claude_project_dir(projects_root, cwd) else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext == "jsonl")
                && path.is_file()
                && is_fresh(&path, now, max_age)
            {
                Some(TranscriptHit {
                    conversation_id: path.file_stem()?.to_string_lossy().into_owned(),
                    path,
                    cwd: cwd.to_path_buf(),
                })
            } else {
                None
            }
        })
        .collect()
}

/// First JSON object of a `.jsonl` file, or `None` when unreadable.
fn read_first_json_line(path: &Path) -> Option<serde_json::Value> {
    use std::io::BufRead;
    let file = std::fs::File::open(path).ok()?;
    let mut reader = std::io::BufReader::new(file);
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

fn codex_candidates(
    sessions_root: &Path,
    cwd: &Path,
    now: std::time::SystemTime,
    max_age: std::time::Duration,
) -> Vec<TranscriptHit> {
    // Rollouts shard by date (`YYYY/MM/DD/rollout-*.jsonl`); only fresh
    // files matter, and only the first line (session_meta) is ever read.
    let mut hits = Vec::new();
    let Ok(years) = std::fs::read_dir(sessions_root) else {
        return hits;
    };
    let want = canonical_or_raw(cwd);
    for year in years.flatten() {
        let Ok(months) = std::fs::read_dir(year.path()) else {
            continue;
        };
        for month in months.flatten() {
            let Ok(days) = std::fs::read_dir(month.path()) else {
                continue;
            };
            for day in days.flatten() {
                let Ok(files) = std::fs::read_dir(day.path()) else {
                    continue;
                };
                for file in files.flatten() {
                    let path = file.path();
                    if !path
                        .file_name()
                        .is_some_and(|n| n.to_string_lossy().starts_with("rollout-"))
                        || !is_fresh(&path, now, max_age)
                    {
                        continue;
                    }
                    if let Some(hit) = codex_hit(&path, &want) {
                        hits.push(hit);
                    }
                }
            }
        }
    }
    hits
}

/// Parse a rollout's `session_meta` first line into a hit, restricted to
/// root threads at the target cwd. Subagent threads (`parent_thread_id`
/// set) are never correlation targets.
fn codex_hit(path: &Path, want_cwd: &Path) -> Option<TranscriptHit> {
    let value = read_first_json_line(path)?;
    if value.get("type")?.as_str()? != "session_meta" {
        return None;
    }
    let meta = value.get("payload")?;
    if meta.get("parent_thread_id").is_some_and(|v| !v.is_null()) {
        return None;
    }
    let recorded_cwd = meta.get("cwd")?.as_str()?;
    if canonical_or_raw(Path::new(recorded_cwd)) != *want_cwd {
        return None;
    }
    // Root threads use one id for thread and session (verified on disk).
    let id = meta.get("id")?.as_str()?;
    Some(TranscriptHit {
        conversation_id: id.to_string(),
        path: path.to_path_buf(),
        cwd: PathBuf::from(recorded_cwd),
    })
}

fn muse_candidates(
    sessions_root: &Path,
    cwd: &Path,
    pid: Option<u32>,
    now: std::time::SystemTime,
    max_age: std::time::Duration,
) -> Vec<TranscriptHit> {
    // Sessions shard by date (`YYYY/MM/DD/<uuid>/session.jsonl`).
    let mut hits = Vec::new();
    let Ok(years) = std::fs::read_dir(sessions_root) else {
        return hits;
    };
    let want = canonical_or_raw(cwd);
    for year in years.flatten() {
        let Ok(months) = std::fs::read_dir(year.path()) else {
            continue;
        };
        for month in months.flatten() {
            let Ok(days) = std::fs::read_dir(month.path()) else {
                continue;
            };
            for day in days.flatten() {
                let Ok(sessions) = std::fs::read_dir(day.path()) else {
                    continue;
                };
                for session in sessions.flatten() {
                    let path = session.path().join("session.jsonl");
                    if !path.is_file() || !is_fresh(&path, now, max_age) {
                        continue;
                    }
                    if let Some(hit) = muse_hit(&path, &want, pid) {
                        hits.push(hit);
                    }
                }
            }
        }
    }
    hits
}

/// Parse a muse `session.jsonl` header into a hit: top-level sessions only
/// (no `parent_task_id`), at the target cwd, preferring the agent pid when
/// the sampler knows it. Reads at most the first 200 lines; both records
/// appear before then.
fn muse_hit(path: &Path, want_cwd: &Path, pid: Option<u32>) -> Option<TranscriptHit> {
    use std::io::BufRead;
    let file = std::fs::File::open(path).ok()?;
    let reader = std::io::BufReader::new(file);
    let mut cwd: Option<PathBuf> = None;
    let mut recorded_pid: Option<u32> = None;
    let mut top_level: Option<bool> = None;
    for line in reader.lines().take(200).flatten() {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        match value.get("payload_type").and_then(|t| t.as_str()) {
            Some("runtime.session.route_facts") => {
                let record = value.get("payload")?.get("record")?;
                cwd = record
                    .get("cwd")
                    .and_then(|c| c.as_str())
                    .map(PathBuf::from);
                recorded_pid = record.get("pid").and_then(|p| p.as_u64()).map(|p| p as u32);
            }
            Some("runtime.session") => {
                let record = value.get("payload")?.get("record")?;
                top_level = Some(record.get("parent_task_id").is_none_or(|v| v.is_null()));
            }
            _ => {}
        }
        if cwd.is_some() && top_level.is_some() {
            break;
        }
    }
    if top_level != Some(true) {
        return None;
    }
    let recorded_cwd = cwd?;
    if canonical_or_raw(&recorded_cwd) != *want_cwd {
        return None;
    }
    // A pid mismatch rules the transcript out; an absent pid record keeps
    // it as a cwd-only candidate for the single-candidate gate.
    if let (Some(want_pid), Some(recorded)) = (pid, recorded_pid)
        && want_pid != recorded
    {
        return None;
    }
    let id = path.parent()?.file_name()?.to_string_lossy().into_owned();
    Some(TranscriptHit {
        conversation_id: id,
        path: path.to_path_buf(),
        cwd: recorded_cwd,
    })
}

/// A process observed by pid: executable path plus full argv.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PidProcess {
    pub pid: u32,
    pub exe_path: PathBuf,
    pub argv: Vec<String>,
}

impl PidProcess {
    /// Executable file name for agent matching.
    pub fn exe_name(&self) -> String {
        self.exe_path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    }
}

/// Read one process's executable name and argv from the kernel.
///
/// Linux reads `/proc`; macOS uses `proc_pidpath` plus a `KERN_PROCARGS2`
/// sysctl. Other platforms (Windows) have no reader yet and return `None`,
/// which degrades detection to nothing rather than a wrong answer.
pub fn read_process(pid: u32) -> Option<PidProcess> {
    read_process_platform(pid)
}

/// An agent observed in a session's foreground: its kind, pid, and binary
/// path, plus the conversation id and transcript path when argv or
/// correlation resolved them. Both are `None` for kind-only observations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObservedAgent {
    pub kind: AgentKind,
    pub pid: u32,
    pub exe_path: PathBuf,
    pub conversation_id: Option<String>,
    pub transcript_path: Option<PathBuf>,
}

/// Observe one pid as a potential agent: match the executable, classify
/// argv, and correlate a transcript when argv carries no id.
///
/// Only interactive runs observe; headless invocations and bookkeeping
/// subcommands return `None`. `session_cwd` backs correlation when the
/// agent's own cwd is unreadable.
pub fn observe_pid(
    pid: u32,
    session_cwd: Option<&Path>,
    now: std::time::SystemTime,
    max_transcript_age: std::time::Duration,
) -> Option<ObservedAgent> {
    let process = read_process(pid)?;
    let kind = AgentKind::detect(&process.exe_name())?;
    let classified = classify_argv(kind, &process.argv)?;
    if classified.mode != AgentRunMode::Interactive {
        return None;
    }
    let cwd = crate::session::child_cwd(pid).or_else(|| session_cwd.map(Path::to_path_buf));
    if let Some(id) = classified.conversation_id {
        // Claude's transcript path is deterministic from the id, so argv
        // observations still get a staleness-checkable path.
        let transcript_path = match kind {
            AgentKind::Claude => cwd.as_ref().and_then(|cwd| {
                let path = claude_project_dir(&transcript_store_root(kind)?, cwd)?
                    .join(format!("{id}.jsonl"));
                path.is_file().then_some(path)
            }),
            _ => None,
        };
        return Some(ObservedAgent {
            kind,
            pid,
            exe_path: process.exe_path,
            conversation_id: Some(id),
            transcript_path,
        });
    }
    let root = transcript_store_root(kind);
    let cwd = cwd?;
    match correlate(
        kind,
        root.as_deref(),
        &cwd,
        Some(pid),
        now,
        max_transcript_age,
    ) {
        Correlation::Single(hit) => Some(ObservedAgent {
            kind,
            pid,
            exe_path: process.exe_path,
            conversation_id: Some(hit.conversation_id),
            transcript_path: Some(hit.path),
        }),
        Correlation::None | Correlation::Multiple => Some(ObservedAgent {
            kind,
            pid,
            exe_path: process.exe_path,
            conversation_id: None,
            transcript_path: None,
        }),
    }
}

#[cfg(target_os = "linux")]
fn read_process_platform(pid: u32) -> Option<PidProcess> {
    let exe_path = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let argv = cmdline
        .split(|b| *b == 0)
        .filter(|arg| !arg.is_empty())
        .map(|arg| String::from_utf8_lossy(arg).into_owned())
        .collect();
    Some(PidProcess {
        pid,
        exe_path,
        argv,
    })
}

#[cfg(target_os = "macos")]
fn read_process_platform(pid: u32) -> Option<PidProcess> {
    Some(PidProcess {
        pid,
        exe_path: mac_exe_path(pid)?,
        argv: mac_argv(pid)?,
    })
}

#[cfg(target_os = "macos")]
fn mac_exe_path(pid: u32) -> Option<PathBuf> {
    let mut buf = vec![0 as libc::c_char; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: `buf` is a writable `PROC_PIDPATHINFO_MAXSIZE` buffer, the
    // documented size for `proc_pidpath`.
    let len = unsafe {
        libc::proc_pidpath(
            pid as libc::c_int,
            buf.as_mut_ptr().cast(),
            buf.len() as u32,
        )
    };
    if len <= 0 {
        return None;
    }
    let path =
        std::ffi::CStr::from_bytes_until_nul(&buf.iter().map(|c| *c as u8).collect::<Vec<_>>())
            .ok()?
            .to_string_lossy()
            .into_owned();
    Some(PathBuf::from(path))
}

#[cfg(target_os = "macos")]
fn mac_argv(pid: u32) -> Option<Vec<String>> {
    use std::os::raw::c_int;
    let mut mib = [
        libc::CTL_KERN as c_int,
        libc::KERN_PROCARGS2 as c_int,
        pid as c_int,
    ];
    let mut size: libc::size_t = 0;
    // SAFETY: size query with null buffer, the documented two-call idiom.
    if unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        return None;
    }
    let mut buf = vec![0u8; size];
    // SAFETY: `buf` is exactly the kernel-reported size.
    if unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            buf.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        return None;
    }
    buf.truncate(size);
    // Layout: argc (int), exec path cstring, then argc argv cstrings, then
    // the environment. NUL padding sits between the strings, so each read
    // skips a NUL run first. Only argv is read.
    if buf.len() < 4 {
        return None;
    }
    let argc = i32::from_ne_bytes(buf[0..4].try_into().ok()?) as usize;
    let mut offset = 4;
    let next_cstring = |offset: &mut usize| -> Option<String> {
        while buf.get(*offset) == Some(&0) {
            *offset += 1;
        }
        let end = buf[*offset..].iter().position(|b| *b == 0)? + *offset;
        let s = String::from_utf8_lossy(&buf[*offset..end]).into_owned();
        *offset = end + 1;
        Some(s)
    };
    next_cstring(&mut offset)?; // exec path
    let mut argv = Vec::with_capacity(argc.min(1024));
    for _ in 0..argc.min(1024) {
        argv.push(next_cstring(&mut offset)?);
    }
    Some(argv)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn read_process_platform(_pid: u32) -> Option<PidProcess> {
    // No process reader on this platform yet (Windows): detection stays
    // off rather than guessing. See the module docs.
    None
}

/// Minimum poll spacing: the actor calls this from a 20ms idle loop.
pub const AGENT_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(750);
/// How long an agent must continuously hold the foreground before it
/// attaches. Kills sub-second flashes (a quick `codex --help` never
/// becomes an attachment).
pub const AGENT_ATTACH_AFTER: std::time::Duration = std::time::Duration::from_secs(3);
/// How often a kind-only attachment re-resolves its transcript: transcripts
/// appear with the first message, after the agent is already attached.
pub const AGENT_RECORRELATE_AFTER: std::time::Duration = std::time::Duration::from_secs(60);
/// Transcripts older than this never correlate to a live agent.
pub const TRANSCRIPT_MAX_AGE: std::time::Duration = std::time::Duration::from_secs(900);

/// Whether foreground-agent tracking runs. `TRIAGE_DISABLE_AGENT_TRACKING`
/// opts out when set to anything but empty, `0`, or `false` (same
/// convention as `TRIAGE_SKIP_FLUTTER_BUILD`): a value that reads as
/// negative must not silently disable tracking.
pub fn agent_tracking_enabled() -> bool {
    enabled_from(
        std::env::var("TRIAGE_DISABLE_AGENT_TRACKING")
            .ok()
            .as_deref(),
    )
}

fn enabled_from(value: Option<&str>) -> bool {
    let Some(value) = value else {
        return true;
    };
    let normalized = value.trim().to_ascii_lowercase();
    normalized.is_empty() || normalized == "0" || normalized == "false"
}

/// Tracks one session's foreground agent across polls.
///
/// The actor feeds each poll the PTY's foreground pgid plus a resolver;
/// the tracker reports an attachment only when the reported state changes:
/// `Some(Some(attachment))` attaches or refines, `Some(None)` detaches,
/// `None` means no change. Resolution (process reads, transcript scans)
/// runs only on foreground changes and kind-only re-correlation, never on
/// every poll.
pub struct FgAgentTracker {
    last_poll: Option<std::time::Instant>,
    last_fg_pid: Option<u32>,
    candidate: Option<(ObservedAgent, std::time::Instant)>,
    reported: Option<AgentAttachment>,
    last_correlate: Option<std::time::Instant>,
}

impl FgAgentTracker {
    pub fn new() -> Self {
        Self {
            last_poll: None,
            last_fg_pid: None,
            candidate: None,
            reported: None,
            last_correlate: None,
        }
    }

    pub fn poll(
        &mut self,
        fg_pid: Option<u32>,
        resolve: &impl Fn(u32) -> Option<ObservedAgent>,
        now: std::time::Instant,
        now_ms: u64,
    ) -> Option<Option<AgentAttachment>> {
        if let Some(last) = self.last_poll
            && now.duration_since(last) < AGENT_POLL_INTERVAL
        {
            return None;
        }
        self.last_poll = Some(now);
        if fg_pid != self.last_fg_pid {
            self.last_fg_pid = fg_pid;
            self.candidate = match fg_pid {
                Some(pid) => resolve(pid).map(|obs| (obs, now)),
                None => None,
            };
            self.last_correlate = Some(now);
        } else if let Some(pid) = fg_pid
            && self.needs_recorrelate(now)
            && let Some(obs) = resolve(pid)
        {
            let first = self.candidate.as_ref().map(|(_, t)| *t).unwrap_or(now);
            self.candidate = Some((obs, first));
            self.last_correlate = Some(now);
        }
        match &self.candidate {
            Some((obs, first)) if now.duration_since(*first) >= AGENT_ATTACH_AFTER => {
                let attachment = AgentAttachment {
                    kind: obs.kind,
                    conversation_id: obs.conversation_id.clone(),
                    transcript_path: obs.transcript_path.clone(),
                    exe_path: Some(obs.exe_path.clone()),
                    last_seen_ms: now_ms,
                };
                if self
                    .reported
                    .as_ref()
                    .is_some_and(|reported| reported.same_observation(&attachment))
                {
                    None
                } else {
                    self.reported = Some(attachment.clone());
                    Some(Some(attachment))
                }
            }
            Some(_) => None,
            None if self.reported.is_some() => {
                self.reported = None;
                Some(None)
            }
            None => None,
        }
    }

    fn needs_recorrelate(&self, now: std::time::Instant) -> bool {
        self.reported
            .as_ref()
            .is_some_and(|reported| reported.conversation_id.is_none())
            && self
                .last_correlate
                .is_some_and(|at| now.duration_since(at) >= AGENT_RECORRELATE_AFTER)
    }
}

impl Default for FgAgentTracker {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn unique_dir(name: &str) -> PathBuf {
        let id = COUNTER.fetch_add(1, Ordering::SeqCst);
        std::env::temp_dir().join(format!(
            "triage-agent-detect-{name}-{}-{:?}-{id}",
            std::process::id(),
            std::thread::current().id()
        ))
    }

    fn argv(parts: &[&str]) -> Vec<String> {
        parts.iter().map(ToString::to_string).collect()
    }

    fn interactive(id: Option<&str>) -> Option<AgentArgv> {
        Some(AgentArgv {
            mode: AgentRunMode::Interactive,
            conversation_id: id.map(str::to_string),
        })
    }

    fn headless() -> Option<AgentArgv> {
        Some(AgentArgv {
            mode: AgentRunMode::Headless,
            conversation_id: None,
        })
    }

    #[test]
    fn classify_claude_modes_and_ids() {
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "--resume", "abc"])),
            interactive(Some("abc"))
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "--resume=abc"])),
            interactive(Some("abc"))
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "--continue"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "--print", "hi"])),
            headless()
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "--help"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "mcp", "list"])),
            None
        );
    }

    #[test]
    fn classify_codex_subcommands() {
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "fix the bug"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(
                AgentKind::Codex,
                &argv(&["codex", "-c", "model=\"o3\"", "resume", "abc"])
            ),
            interactive(Some("abc"))
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "resume", "--last"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "exec", "ls"])),
            headless()
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "login"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "--version"])),
            None
        );
    }

    #[test]
    fn classify_agy_flags() {
        assert_eq!(
            classify_argv(AgentKind::Antigravity, &argv(&["agy"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(
                AgentKind::Antigravity,
                &argv(&["agy", "--conversation", "abc"])
            ),
            interactive(Some("abc"))
        );
        assert_eq!(
            classify_argv(AgentKind::Antigravity, &argv(&["agy", "-c"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Antigravity, &argv(&["agy", "--print", "hi"])),
            headless()
        );
        assert_eq!(
            classify_argv(AgentKind::Antigravity, &argv(&["agy", "mcp", "list"])),
            None
        );
    }

    #[test]
    fn classify_muse_subcommands() {
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(
                AgentKind::Muse,
                &argv(&["muse", "--workspace", "/tmp/x", "resume", "abc"])
            ),
            interactive(Some("abc"))
        );
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "resume", "--last"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "exec", "hi"])),
            headless()
        );
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "trace", "inspect"])),
            None
        );
    }

    #[test]
    fn resume_commands_cover_id_and_fallback() {
        assert_eq!(
            resume_command(AgentKind::Claude, Some("abc")),
            (
                "claude".to_string(),
                vec!["--resume".to_string(), "abc".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Claude, None),
            ("claude".to_string(), vec!["--continue".to_string()])
        );
        assert_eq!(
            resume_command(AgentKind::Codex, Some("abc")),
            (
                "codex".to_string(),
                vec!["resume".to_string(), "abc".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Codex, None),
            (
                "codex".to_string(),
                vec!["resume".to_string(), "--last".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Antigravity, Some("abc")),
            (
                "agy".to_string(),
                vec!["--conversation".to_string(), "abc".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Antigravity, None),
            ("agy".to_string(), vec!["--continue".to_string()])
        );
        assert_eq!(
            resume_command(AgentKind::Muse, Some("abc")),
            (
                "muse".to_string(),
                vec!["resume".to_string(), "abc".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Muse, None),
            (
                "muse".to_string(),
                vec!["resume".to_string(), "--last".to_string()]
            )
        );
    }

    #[test]
    fn claude_project_slug_replaces_separators() {
        let root = Path::new("/home/me/.claude/projects");
        assert_eq!(
            claude_project_dir(root, Path::new("/Users/me/repo")),
            Some(root.join("-Users-me-repo"))
        );
        assert_eq!(claude_project_dir(root, Path::new("repo")), None);
    }

    fn write(path: &Path, content: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, content).unwrap();
    }

    #[test]
    fn correlate_claude_single_and_contenders() {
        let root = unique_dir("claude");
        let cwd = root.join("work").join("repo");
        let dir = claude_project_dir(&root.join("projects"), &cwd).unwrap();
        write(&dir.join("aaa.jsonl"), "{}\n");
        let now = std::time::SystemTime::now();
        let max_age = std::time::Duration::from_secs(900);
        match correlate(
            AgentKind::Claude,
            Some(&root.join("projects")),
            &cwd,
            None,
            now,
            max_age,
        ) {
            Correlation::Single(hit) => {
                assert_eq!(hit.conversation_id, "aaa");
                assert!(hit.path.ends_with("aaa.jsonl"));
            }
            other => panic!("expected single hit, got {other:?}"),
        }
        // A second fresh transcript degrades to Multiple, never a guess.
        write(&dir.join("bbb.jsonl"), "{}\n");
        assert_eq!(
            correlate(
                AgentKind::Claude,
                Some(&root.join("projects")),
                &cwd,
                None,
                now,
                max_age
            ),
            Correlation::Multiple
        );
        // Stale transcripts (older than max_age) do not count.
        let later = now + std::time::Duration::from_secs(3600);
        assert_eq!(
            correlate(
                AgentKind::Claude,
                Some(&root.join("projects")),
                &cwd,
                None,
                later,
                max_age
            ),
            Correlation::None
        );
    }

    #[test]
    fn correlate_codex_filters_roots_and_cwd() {
        let root = unique_dir("codex");
        let day = root.join("2026").join("09").join("20");
        let cwd = root.join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        let meta = |id: &str, parent: &str, cwd: &str| {
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"session_id\":\"{id}\",\
                 \"parent_thread_id\":{parent},\"originator\":\"codex-tui\",\"cwd\":\"{cwd}\"}}}}\n"
            )
        };
        write(
            &day.join("rollout-a.jsonl"),
            &meta("aaa", "null", &cwd.to_string_lossy()),
        );
        let now = std::time::SystemTime::now();
        let max_age = std::time::Duration::from_secs(900);
        match correlate(AgentKind::Codex, Some(&root), &cwd, None, now, max_age) {
            Correlation::Single(hit) => assert_eq!(hit.conversation_id, "aaa"),
            other => panic!("expected single hit, got {other:?}"),
        }
        // Subagent threads and other-cwd threads are not candidates.
        write(
            &day.join("rollout-sub.jsonl"),
            &meta("sub", "\"aaa\"", &cwd.to_string_lossy()),
        );
        write(
            &day.join("rollout-else.jsonl"),
            &meta("els", "null", "/somewhere/else"),
        );
        match correlate(AgentKind::Codex, Some(&root), &cwd, None, now, max_age) {
            Correlation::Single(hit) => assert_eq!(hit.conversation_id, "aaa"),
            other => panic!("expected still-single hit, got {other:?}"),
        }
        // A second root at the same cwd degrades to Multiple.
        write(
            &day.join("rollout-b.jsonl"),
            &meta("bbb", "null", &cwd.to_string_lossy()),
        );
        assert_eq!(
            correlate(AgentKind::Codex, Some(&root), &cwd, None, now, max_age),
            Correlation::Multiple
        );
    }

    #[test]
    fn correlate_muse_uses_pid_and_top_level() {
        let root = unique_dir("muse");
        let day = root.join("2026").join("09").join("20");
        let cwd = root.join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        let session = |facts: &str, session: &str| format!("{facts}\n{session}\n");
        let facts = |cwd: &str, pid: u32| {
            format!(
                "{{\"payload_type\":\"runtime.session.route_facts\",\
             \"payload\":{{\"record\":{{\"cwd\":\"{cwd}\",\"pid\":{pid}}}}}}}"
            )
        };
        let top = "{\"payload_type\":\"runtime.session\",\"payload\":{\"record\":{}}}".to_string();
        let sub = "{\"payload_type\":\"runtime.session\",\"payload\":{\"record\":\
             {\"parent_task_id\":\"t1\"}}}";
        write(
            &day.join("aaa").join("session.jsonl"),
            &session(&facts(&cwd.to_string_lossy(), 111), &top),
        );
        write(
            &day.join("sub").join("session.jsonl"),
            &session(&facts(&cwd.to_string_lossy(), 222), sub),
        );
        let now = std::time::SystemTime::now();
        let max_age = std::time::Duration::from_secs(900);
        // The subagent session is filtered; the top-level one matches alone.
        match correlate(AgentKind::Muse, Some(&root), &cwd, None, now, max_age) {
            Correlation::Single(hit) => assert_eq!(hit.conversation_id, "aaa"),
            other => panic!("expected single hit, got {other:?}"),
        }
        // A pid mismatch rules the transcript out.
        assert_eq!(
            correlate(AgentKind::Muse, Some(&root), &cwd, Some(999), now, max_age),
            Correlation::None
        );
        // A second top-level contender degrades to Multiple, unless the pid
        // disambiguates back to Single.
        write(
            &day.join("bbb").join("session.jsonl"),
            &session(&facts(&cwd.to_string_lossy(), 333), &top),
        );
        assert_eq!(
            correlate(AgentKind::Muse, Some(&root), &cwd, None, now, max_age),
            Correlation::Multiple
        );
        match correlate(AgentKind::Muse, Some(&root), &cwd, Some(333), now, max_age) {
            Correlation::Single(hit) => assert_eq!(hit.conversation_id, "bbb"),
            other => panic!("expected pid-disambiguated hit, got {other:?}"),
        }
    }

    #[test]
    #[cfg(unix)]
    fn read_process_self() {
        let me = read_process(std::process::id()).expect("read own process");
        assert!(!me.exe_name().is_empty());
        assert!(me.exe_path.is_absolute());
        assert!(!me.argv.is_empty());
    }

    #[test]
    #[cfg(unix)]
    fn read_process_dead_pid() {
        assert_eq!(read_process(u32::MAX), None);
    }

    /// Path to the stub-agent helper binary the build script compiles into
    /// OUT_DIR. It ignores argv and blocks quietly until killed.
    fn stub_agent_bin() -> PathBuf {
        PathBuf::from(env!("OUT_DIR"))
            .join(format!("triage-stub-agent{}", std::env::consts::EXE_SUFFIX))
    }

    /// Copy the stub agent to a temp agent binary name and spawn it, so
    /// observation tests run against a real kernel-visible process with
    /// controlled argv. Returns the child plus the bin dir (kept alive by
    /// the caller for the child's lifetime).
    #[cfg(unix)]
    fn spawn_stub_agent(name: &str, args: &[&str]) -> (std::process::Child, PathBuf) {
        let dir = unique_dir("stub");
        let bin = dir.join(format!("{name}{}", std::env::consts::EXE_SUFFIX));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::copy(stub_agent_bin(), &bin).unwrap();
        let child = std::process::Command::new(&bin)
            .args(args)
            .spawn()
            .expect("spawn stub agent");
        (child, dir)
    }

    #[test]
    #[cfg(unix)]
    fn observe_pid_stub_agent_with_argv_id() {
        let (mut child, _dir) = spawn_stub_agent("claude", &["--resume", "abc123"]);
        let observed = observe_pid(
            child.id(),
            None,
            std::time::SystemTime::now(),
            std::time::Duration::from_secs(900),
        )
        .expect("observe stub agent");
        assert_eq!(observed.kind, AgentKind::Claude);
        assert_eq!(observed.conversation_id.as_deref(), Some("abc123"));
        let _ = child.kill();
        let _ = child.wait();
    }

    #[test]
    #[cfg(unix)]
    fn observe_pid_headless_stub_is_ignored() {
        let (mut child, _dir) = spawn_stub_agent("codex", &["exec"]);
        assert_eq!(
            observe_pid(
                child.id(),
                None,
                std::time::SystemTime::now(),
                std::time::Duration::from_secs(900),
            ),
            None
        );
        let _ = child.kill();
        let _ = child.wait();
    }

    fn observed(kind: AgentKind, pid: u32, id: Option<&str>) -> ObservedAgent {
        ObservedAgent {
            kind,
            pid,
            exe_path: PathBuf::from("/bin/stub"),
            conversation_id: id.map(str::to_string),
            transcript_path: None,
        }
    }

    fn attached(report: &Option<Option<AgentAttachment>>) -> Option<AgentAttachment> {
        report.clone().flatten()
    }

    #[test]
    fn tracking_opt_out_follows_negative_value_convention() {
        assert!(enabled_from(None));
        assert!(enabled_from(Some("")));
        assert!(enabled_from(Some("0")));
        assert!(enabled_from(Some("false")));
        assert!(enabled_from(Some("FALSE")));
        assert!(!enabled_from(Some("1")));
        assert!(!enabled_from(Some("true")));
        assert!(!enabled_from(Some("yes")));
    }

    #[test]
    fn tracker_attaches_after_hold_and_detaches_immediately() {
        let mut tracker = FgAgentTracker::new();
        let t0 = std::time::Instant::now();
        let resolve =
            |pid: u32| (pid == 111).then(|| observed(AgentKind::Claude, pid, Some("abc")));
        // First sighting only warms the candidate.
        assert_eq!(tracker.poll(Some(111), &resolve, t0, 1), None);
        // Throttled polls report nothing.
        assert_eq!(
            tracker.poll(
                Some(111),
                &resolve,
                t0 + std::time::Duration::from_millis(100),
                2
            ),
            None
        );
        // Still warming before the hold elapses.
        assert_eq!(
            tracker.poll(
                Some(111),
                &resolve,
                t0 + std::time::Duration::from_secs(2),
                3
            ),
            None
        );
        // Hold elapsed: attach.
        let report = tracker.poll(
            Some(111),
            &resolve,
            t0 + std::time::Duration::from_secs(4),
            4,
        );
        let attachment = attached(&report).expect("attach");
        assert_eq!(attachment.kind, AgentKind::Claude);
        assert_eq!(attachment.conversation_id.as_deref(), Some("abc"));
        // Steady state re-reports nothing.
        assert_eq!(
            tracker.poll(
                Some(111),
                &resolve,
                t0 + std::time::Duration::from_secs(5),
                5
            ),
            None
        );
        // Foreground change away detaches on the first poll.
        assert_eq!(
            tracker.poll(None, &resolve, t0 + std::time::Duration::from_secs(6), 6),
            Some(None)
        );
        assert_eq!(
            tracker.poll(None, &resolve, t0 + std::time::Duration::from_secs(7), 7),
            None
        );
    }

    #[test]
    fn tracker_foreground_change_restarts_hold() {
        let mut tracker = FgAgentTracker::new();
        let t0 = std::time::Instant::now();
        let resolve = |pid: u32| Some(observed(AgentKind::Muse, pid, None));
        assert_eq!(tracker.poll(Some(111), &resolve, t0, 1), None);
        // A different agent pid restarts the hold from zero.
        assert_eq!(
            tracker.poll(
                Some(222),
                &resolve,
                t0 + std::time::Duration::from_secs(4),
                2
            ),
            None
        );
        let report = tracker.poll(
            Some(222),
            &resolve,
            t0 + std::time::Duration::from_secs(8),
            3,
        );
        let attachment = attached(&report).expect("attach second agent");
        assert_eq!(attachment.kind, AgentKind::Muse);
        assert_eq!(attachment.conversation_id, None);
    }

    #[test]
    fn tracker_recorrelates_kind_only_attachments() {
        use std::cell::Cell;
        let refined = Cell::new(false);
        let mut tracker = FgAgentTracker::new();
        let t0 = std::time::Instant::now();
        let resolve = |pid: u32| {
            let id = refined.get().then_some("late-id");
            Some(observed(AgentKind::Codex, pid, id))
        };
        assert_eq!(tracker.poll(Some(111), &resolve, t0, 1), None);
        let report = tracker.poll(
            Some(111),
            &resolve,
            t0 + std::time::Duration::from_secs(4),
            2,
        );
        assert_eq!(attached(&report).unwrap().conversation_id, None);
        // Before the re-correlation interval: no refinement traffic.
        assert_eq!(
            tracker.poll(
                Some(111),
                &resolve,
                t0 + std::time::Duration::from_secs(30),
                3
            ),
            None
        );
        // The transcript appears; past the interval the tracker refines.
        refined.set(true);
        let report = tracker.poll(
            Some(111),
            &resolve,
            t0 + std::time::Duration::from_secs(70),
            4,
        );
        assert_eq!(
            attached(&report).unwrap().conversation_id.as_deref(),
            Some("late-id")
        );
    }

    #[test]
    fn correlate_missing_roots_and_antigravity() {
        let now = std::time::SystemTime::now();
        let max_age = std::time::Duration::from_secs(900);
        let cwd = std::env::temp_dir();
        assert_eq!(
            correlate(AgentKind::Claude, None, &cwd, None, now, max_age),
            Correlation::None
        );
        assert_eq!(
            correlate(
                AgentKind::Claude,
                Some(Path::new("/definitely/not/here")),
                &cwd,
                None,
                now,
                max_age
            ),
            Correlation::None
        );
        assert_eq!(
            correlate(AgentKind::Antigravity, None, &cwd, None, now, max_age),
            Correlation::None
        );
    }
}
