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

/// Classify an agent command line. `argv` includes `argv[0]`.
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

/// Positional tokens that are not flag values: only the values of known
/// value-taking flags are skipped, and `--flag=value` never skips (its
/// value rides along). Unknown flags are assumed boolean: skipping after
/// every flag hid real subcommands behind boolean flags, losing resume
/// ids and mistaking one-shot `exec` runs for interactive sessions. A
/// flag-like token is never skipped as a value: the flag was bare
/// (optional-value options) or the invocation is malformed, and either
/// way the token keeps its own meaning.
fn positional_tokens<'a>(args: &[&'a str], value_flags: &[&str]) -> Vec<&'a str> {
    positional_tokens_split(args, value_flags).0
}

/// As [`positional_tokens`], plus the count of positionals from before a
/// bare `--`. Tokens after `--` are positional (never flags) but, for
/// the clap-style CLIs, never subcommands; subcommand scans use
/// `[..boundary]` while resume-id lookup uses the full vec.
fn positional_tokens_split<'a>(args: &[&'a str], value_flags: &[&str]) -> (Vec<&'a str>, usize) {
    let mut out: Vec<&'a str> = Vec::new();
    let mut iter = args.iter().peekable();
    while let Some(arg) = iter.next() {
        if *arg == "--" {
            let boundary = out.len();
            for rest in iter {
                out.push(*rest);
            }
            return (out, boundary);
        }
        if !arg.starts_with('-') {
            out.push(*arg);
            continue;
        }
        let name = arg.split('=').next().unwrap_or(*arg);
        let takes_value = !arg.contains('=') && value_flags.contains(&name);
        if takes_value && iter.peek().is_some_and(|next| !next.starts_with('-')) {
            iter.next();
        }
    }
    let boundary = out.len();
    (out, boundary)
}

/// Index of the first positional naming a known subcommand, if any.
/// Unknown flags may precede the subcommand, and an unknown flag's value
/// is indistinguishable from prompt text, so the scan tolerates leading
/// tokens rather than trusting the first positional alone. Residual: a
/// prompt word (or unknown flag value) that spells a subcommand
/// misclassifies; that needs a standalone subcommand word among
/// unquoted prompt tokens.
fn find_subcommand(positionals: &[&str], known: &[&str]) -> Option<usize> {
    positionals.iter().position(|token| known.contains(token))
}

/// Value of `--flag value` or `--flag=value` for a long flag: the last
/// value wins (commander-style), and a bare or empty occurrence keeps
/// scanning rather than blinding later ones. `None` when the flag is
/// absent or never carries a usable value.
fn long_flag_value<'a>(args: &[&'a str], flag: &str) -> Option<&'a str> {
    flag_value(args, flag, true)
}

/// Shared `--flag value` scanner behind [`long_flag_value`] (which also
/// accepts `--flag=value`) and [`short_flag_value`]: one peek-before-
/// consume loop, so arity fixes cannot land on one and miss the other.
/// An empty next token is never a usable value for either spelling.
fn flag_value<'a>(args: &[&'a str], flag: &str, equals_form: bool) -> Option<&'a str> {
    let prefix = format!("{flag}=");
    let mut seen = None;
    let mut iter = args.iter().peekable();
    while let Some(arg) = iter.next() {
        if equals_form && let Some(value) = arg.strip_prefix(&prefix) {
            if !value.is_empty() {
                seen = Some(value);
            }
            continue;
        }
        // Peek before consuming: a flag-like next token may itself be
        // another occurrence, which must stay in the stream.
        if *arg == flag {
            match iter.peek() {
                Some(next) if !next.starts_with('-') && !next.is_empty() => {
                    seen = Some(**next);
                    iter.next();
                }
                _ => {}
            }
        }
    }
    seen
}

/// True when any arg is one of the given flags.
fn has_any(args: &[&str], flags: &[&str]) -> bool {
    args.iter().any(|a| flags.contains(a))
}

/// True for `--help`/`--version` style invocations, which are never
/// trackable agent runs. (Antigravity differs and keeps its own guard;
/// Claude's extra `-v` is checked at its own call site.)
fn requests_help_or_version(args: &[&str]) -> bool {
    has_any(args, &["--help", "-h"]) || has_any(args, &["--version", "-V"])
}

/// Value of the short flag's next token (`-r <id>`): the last value
/// wins, and a bare or empty occurrence keeps scanning rather than
/// blinding later ones. `None` when the flag is absent or never carries
/// a usable value.
fn short_flag_value<'a>(args: &[&'a str], flag: &str) -> Option<&'a str> {
    flag_value(args, flag, false)
}

/// Subcommands Claude treats as something other than the interactive
/// session. Unlike codex/muse, Claude follows commander grammar: only
/// the FIRST positional can be a subcommand, so the classifier decides
/// from it alone rather than scanning.
const CLAUDE_SUBCOMMANDS: &[&str] = &[
    "agents",
    "attach",
    "auth",
    "auto-mode",
    "doctor",
    "gateway",
    "import",
    "install",
    "logs",
    "mcp",
    "plugin",
    "plugins",
    "project",
    "respawn",
    "rm",
    "setup-token",
    "stop",
    "kill",
    "ultrareview",
    "update",
    "upgrade",
];

/// Claude options that consume the following token as their value.
/// Commander consumes even for `[optional]` options (`-r`/`--resume`,
/// `--from-pr`, `--cloud`), so they are listed; a flag-like next token
/// still keeps its own meaning (see `positional_tokens`).
const CLAUDE_VALUE_FLAGS: &[&str] = &[
    "--add-dir",
    "--agent",
    "--agents",
    "--allowedTools",
    "--allowed-tools",
    "--append-system-prompt",
    "--append-system-prompt-file",
    "--autocompact",
    "--betas",
    "--cloud",
    "-d",
    "--debug",
    "--debug-file",
    "--disallowed-tools",
    "--disallowedTools",
    "--effort",
    "--environment",
    "--fallback-model",
    "--file",
    "--from-pr",
    "--input-format",
    "--json-schema",
    "--max-budget-usd",
    "--mcp-config",
    "--model",
    "-n",
    "--name",
    "--output-format",
    "--permission-mode",
    "--permission-prompt-tool",
    "--permission-prompts",
    "--plugin-dir",
    "--plugin-url",
    "--prompt-suggestions",
    "--remote-control",
    "--remote-control-session-name-prefix",
    "--resume",
    "-r",
    "--session-id",
    "--setting-sources",
    "--settings",
    "--system-prompt",
    "--system-prompt-file",
    "--system-prompt-snapshot",
    "--teleport",
    "--tools",
    "-w",
    "--worktree",
];

fn classify_claude(args: &[&str]) -> Option<AgentArgv> {
    // `-v` is Claude's version short flag alongside `-V`.
    if requests_help_or_version(args) || has_any(args, &["-v"]) {
        return None;
    }
    let positionals = positional_tokens(args, CLAUDE_VALUE_FLAGS);
    match positionals.first().copied() {
        // `claude attach <id>` opens a background session: interactive,
        // with the id when given.
        Some("attach") => Some(AgentArgv {
            mode: AgentRunMode::Interactive,
            conversation_id: positionals.get(1).map(ToString::to_string),
        }),
        // `claude ultrareview` runs a cloud review one-shot.
        Some("ultrareview") => Some(AgentArgv {
            mode: AgentRunMode::Headless,
            conversation_id: None,
        }),
        // Bookkeeping subcommands (servers, installers, session
        // management) are not agent runs.
        Some(sub) if CLAUDE_SUBCOMMANDS.contains(&sub) => None,
        // Bare `claude`, `claude "prompt"`, or an unknown token: the
        // interactive session, with the id when flag-carried.
        _ => {
            let mode = if has_any(args, &["--print", "-p"]) {
                AgentRunMode::Headless
            } else {
                AgentRunMode::Interactive
            };
            Some(AgentArgv {
                mode,
                conversation_id: long_flag_value(args, "--resume")
                    .or_else(|| short_flag_value(args, "-r"))
                    .map(str::to_string),
            })
        }
    }
}

/// Subcommands codex treats as something other than the interactive
/// TUI. The classifier locates the first positional naming one of these
/// (see [`find_subcommand`]).
const CODEX_SUBCOMMANDS: &[&str] = &[
    "exec",
    "e",
    "review",
    "resume",
    "login",
    "logout",
    "mcp",
    "plugin",
    "app-server",
    "app",
    "completion",
    "update",
    "doctor",
    "sandbox",
    "debug",
    "apply",
    "a",
    "queue",
    "archive",
    "delete",
    "migrate-rollouts",
    "unarchive",
    "fork",
    "cloud",
    "exec-server",
    "features",
    "agents",
    "remote-control",
    "help",
];

/// Codex options that consume the following token as their value.
/// (`--worktree` is boolean here, not the optional-value muse flag.)
const CODEX_VALUE_FLAGS: &[&str] = &[
    "-c",
    "--config",
    "-p",
    "--profile",
    "-m",
    "--model",
    "-C",
    "--cd",
    "--add-dir",
    "-i",
    "--image",
    "-a",
    "--ask-for-approval",
    "-s",
    "--sandbox",
    "--enable",
    "--disable",
    "--remote",
    "--remote-auth-token-env",
    "--local-provider",
];

fn classify_codex(args: &[&str]) -> Option<AgentArgv> {
    // clap ends flag parsing at `--` (verified: `codex -- --help`
    // launches instead of printing help), so help and subcommand scans
    // cover only the tokens before it.
    let dash = args.iter().position(|a| *a == "--").unwrap_or(args.len());
    if requests_help_or_version(&args[..dash]) {
        return None;
    }
    let (positionals, boundary) = positional_tokens_split(args, CODEX_VALUE_FLAGS);
    let Some(at) = find_subcommand(&positionals[..boundary], CODEX_SUBCOMMANDS) else {
        // Bare `codex` or prompt text: no known subcommand anywhere.
        return Some(AgentArgv {
            mode: AgentRunMode::Interactive,
            conversation_id: None,
        });
    };
    match positionals[at] {
        // `codex exec|review` (and short alias `e`) run headless one-shots.
        "exec" | "e" | "review" => Some(AgentArgv {
            mode: AgentRunMode::Headless,
            conversation_id: None,
        }),
        // `codex resume [SESSION_ID] [PROMPT]`: the id is the next positional.
        "resume" => Some(AgentArgv {
            mode: AgentRunMode::Interactive,
            conversation_id: positionals.get(at + 1).map(ToString::to_string),
        }),
        // Bookkeeping subcommands are not agent runs.
        _ => None,
    }
}

/// Agy options that consume the following token as their value (Go
/// flags: a value-taking flag always consumes the next token).
const AGY_VALUE_FLAGS: &[&str] = &[
    "--conversation",
    "--project",
    "--model",
    "--agent",
    "--mode",
    "--effort",
    "--add-dir",
    "--log-file",
    "--input-format",
    "--output-format",
    "--json-schema",
    "--print-timeout",
];

/// Subcommands agy treats as something other than the interactive
/// session. Go dispatches only `Args()[0]`, so the classifier decides
/// from the first positional alone rather than scanning.
const AGY_SUBCOMMANDS: &[&str] = &[
    "agent",
    "agents",
    "changelog",
    "install",
    "mcp",
    "mic-serve",
    "models",
    "plugin",
    "plugins",
    "remote-control",
    "update",
    "help",
];

/// Rewrite Go single-dash long flags (`-model`, `-print`, `-help`,
/// including `-flag=value`) to double-dash. Go accepts both spellings
/// (verified: `-help` prints usage, `-conversation` without a value
/// errors `flag needs an argument`); without this the tables below miss
/// every single-dash use. Single-letter flags (`-p`, `-h`) and bare `-`
/// pass through untouched.
fn normalize_agy_args(args: &[&str]) -> Vec<String> {
    args.iter()
        .map(|arg| {
            if let Some(rest) = arg.strip_prefix('-')
                && !rest.starts_with('-')
                && rest.split('=').next().is_some_and(|name| name.len() > 1)
            {
                return format!("--{rest}");
            }
            (*arg).to_string()
        })
        .collect()
}

fn classify_agy(args: &[&str]) -> Option<AgentArgv> {
    let normalized = normalize_agy_args(args);
    let loaned: Vec<&str> = normalized.iter().map(String::as_str).collect();
    let args = loaned.as_slice();
    // Bare `help` is NOT matched anywhere: Go reads only Args()[0], so a
    // later `help` is prompt text (the first-positional `help` below
    // still covers the real help subcommand).
    if has_any(args, &["--help", "-h"]) {
        return None;
    }
    if positional_tokens(args, AGY_VALUE_FLAGS)
        .first()
        .is_some_and(|sub| AGY_SUBCOMMANDS.contains(sub))
    {
        return None;
    }
    let mode = if has_any(args, &["--print", "-p", "--prompt"]) {
        AgentRunMode::Headless
    } else {
        AgentRunMode::Interactive
    };
    Some(AgentArgv {
        mode,
        conversation_id: long_flag_value(args, "--conversation").map(str::to_string),
    })
}

/// Subcommands muse treats as something other than the interactive
/// TUI. The classifier locates the first positional naming one of these
/// (see [`find_subcommand`]).
const MUSE_SUBCOMMANDS: &[&str] = &[
    "exec",
    "resume",
    "config",
    "export",
    "trace",
    "skills",
    "plugins",
    "sandbox",
    "schema",
    "serve",
    "session-message",
    "mcp",
    "auth",
    "login",
    "logout",
    "init",
    "help",
];

/// Muse options that consume the following token as their value.
/// `-w`/`--worktree` is deliberately excluded: its value is optional,
/// so after a bare `-w` the next token is the subcommand, not a value.
/// Leaving it unlisted keeps both readings working through the
/// subcommand scan; listing it would eat the subcommand itself.
const MUSE_VALUE_FLAGS: &[&str] = &[
    "--workspace",
    "--model",
    "--provider",
    "--preset",
    "--agents",
    "--reasoning-effort",
    "--base-url",
    "--image",
    "--worktree-base",
    "--worktree-existing",
    "--approval-mode",
    "--permission-profile",
    "--approval-judge",
    "--echo-delay-ms",
    "--sandbox-network",
];

fn classify_muse(args: &[&str]) -> Option<AgentArgv> {
    // muse pre-scans `--help`/`--version` anywhere (verified: `muse --
    // --help`, `muse -- --version`, and `muse foo --help` all answer),
    // so the help scan stays global; only subcommand dispatch stops at
    // `--` (verified: `muse -- exec` errors as an unknown argument
    // instead of dispatching).
    if requests_help_or_version(args) {
        return None;
    }
    let (positionals, boundary) = positional_tokens_split(args, MUSE_VALUE_FLAGS);
    let Some(at) = find_subcommand(&positionals[..boundary], MUSE_SUBCOMMANDS) else {
        // Bare `muse`, `muse "prompt"`, or an unknown token (prompt text).
        return Some(AgentArgv {
            mode: AgentRunMode::Interactive,
            conversation_id: None,
        });
    };
    match positionals[at] {
        "exec" => Some(AgentArgv {
            mode: AgentRunMode::Headless,
            conversation_id: None,
        }),
        // `muse resume [--last|<session-ref>]`.
        "resume" => Some(AgentArgv {
            mode: AgentRunMode::Interactive,
            conversation_id: positionals.get(at + 1).map(ToString::to_string),
        }),
        // Bookkeeping subcommands are not agent runs.
        _ => None,
    }
}

/// Build the command restoring an agent conversation: resume the given id,
/// or the agent's most-recent conversation when no id is known. The
/// binary is the recorded path when it still exists, else the primary
/// binary name for a `PATH` lookup.
pub fn resume_command(
    kind: AgentKind,
    conversation_id: Option<&str>,
    exe_path: Option<&Path>,
) -> (String, Vec<String>) {
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
    let binary = exe_path
        .filter(|path| path.is_file())
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|| kind.primary_binary().to_string());
    (binary, args)
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
    // Single exhaustive match: a future `AgentKind` fails closed at
    // compile time instead of hitting a runtime `unreachable!` on the
    // observation path.
    let home = home_dir()?;
    match kind {
        AgentKind::Claude => Some(home.join(".claude").join("projects")),
        AgentKind::Codex => Some(home.join(".codex").join("sessions")),
        AgentKind::Muse => Some(
            std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".local").join("share"))
                .join("muse")
                .join("sessions"),
        ),
        AgentKind::Antigravity => None,
    }
}

/// Claude's project directory for a cwd: the absolute path with every `/`
/// replaced by `-` (e.g. `/Users/me/repo` becomes `-Users-me-repo`).
/// `\` and `:` are replaced too, so a Windows path can never make the
/// slug absolute and discard the store root at `join` time.
/// Returns `None` for relative cwds, which have no stable mapping.
pub fn claude_project_dir(projects_root: &Path, cwd: &Path) -> Option<PathBuf> {
    if !cwd.is_absolute() {
        return None;
    }
    let slug: String = cwd
        .to_string_lossy()
        .chars()
        .map(|c| {
            if c == '/' || c == '\\' || c == ':' {
                '-'
            } else {
                c
            }
        })
        .collect();
    Some(projects_root.join(slug))
}

/// A transcript file plausibly belonging to a live agent: conversation id
/// plus transcript path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptHit {
    pub conversation_id: String,
    pub path: PathBuf,
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
///
/// The candidate scans below are deliberately exhaustive rather than
/// pruned by shard date: a still-active session keeps appending to its
/// start-date shard, so pruning could hide a fresh contender and flip
/// `Multiple` to a wrong `Single`. Stale files cost only a stat, and
/// the scan measures milliseconds at realistic store sizes.
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
    let mut hits = candidates.into_iter();
    match (hits.next(), hits.next()) {
        (None, _) => Correlation::None,
        (Some(hit), None) => Correlation::Single(hit),
        (Some(_), Some(_)) => Correlation::Multiple,
    }
}

/// Canonicalize for comparison, falling back to the raw path when the file
/// is gone (macOS `/tmp` symlinks make raw comparison unreliable).
fn canonical_or_raw(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// Fresh regular file within `max_age` of `now`, in a single metadata
/// fetch: the candidate scans run on the actor thread, so the
/// regular-file check rides along instead of stat-ing twice.
fn is_fresh_file(path: &Path, now: std::time::SystemTime, max_age: std::time::Duration) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    let Ok(modified) = metadata.modified() else {
        return false;
    };
    // A transcript newer than `now` (clock skew) counts as fresh: its age
    // saturates at zero rather than reading as ancient.
    now.duration_since(modified).unwrap_or_default() <= max_age
}

/// Visit every leaf under a `YYYY/MM/DD` date-sharded store (codex
/// rollouts, muse session dirs): four nested directory levels with
/// unreadable levels skipped, so one walk serves both scanners.
fn for_each_shard_leaf(root: &Path, mut visit: impl FnMut(&Path)) {
    let Ok(years) = std::fs::read_dir(root) else {
        return;
    };
    for year in years.flatten() {
        let Ok(months) = std::fs::read_dir(year.path()) else {
            continue;
        };
        for month in months.flatten() {
            let Ok(days) = std::fs::read_dir(month.path()) else {
                continue;
            };
            for day in days.flatten() {
                let Ok(leaves) = std::fs::read_dir(day.path()) else {
                    continue;
                };
                for leaf in leaves.flatten() {
                    visit(&leaf.path());
                }
            }
        }
    }
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
                && is_fresh_file(&path, now, max_age)
            {
                let id = path.file_stem()?.to_string_lossy().into_owned();
                // A stray stemless or dirty stem would attach an unusable
                // id; skip it rather than building bad resume argv.
                if !is_clean_id(&id) {
                    return None;
                }
                Some(TranscriptHit {
                    conversation_id: id,
                    path,
                })
            } else {
                None
            }
        })
        .collect()
}

/// First JSON object of a `.jsonl` file, or `None` when unreadable.
/// The stream is capped: a corrupt transcript with one huge line must not
/// OOM the actor thread on a metadata probe.
fn read_first_json_line(path: &Path) -> Option<serde_json::Value> {
    use std::io::{BufRead, Read};
    let file = std::fs::File::open(path).ok()?;
    let mut reader = std::io::BufReader::new(file.take(64 * 1024));
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
    let want = canonical_or_raw(cwd);
    for_each_shard_leaf(sessions_root, |leaf| {
        if !leaf
            .file_name()
            .is_some_and(|n| n.to_string_lossy().starts_with("rollout-"))
            || !is_fresh_file(leaf, now, max_age)
        {
            return;
        }
        if let Some(hit) = codex_hit(leaf, &want) {
            hits.push(hit);
        }
    });
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
    // A corrupt rollout can name an empty or dirty id; attaching it
    // would make resume argv the CLI rejects, or smuggle control
    // characters into badges and logs.
    if !is_clean_id(id) {
        return None;
    }
    Some(TranscriptHit {
        conversation_id: id.to_string(),
        path: path.to_path_buf(),
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
    let want = canonical_or_raw(cwd);
    for_each_shard_leaf(sessions_root, |leaf| {
        let path = leaf.join("session.jsonl");
        if !is_fresh_file(&path, now, max_age) {
            return;
        }
        if let Some(hit) = muse_hit(&path, &want, pid) {
            hits.push(hit);
        }
    });
    hits
}

/// Parse a muse `session.jsonl` header into a hit: top-level sessions only
/// (no `parent_task_id`), at the target cwd, preferring the agent pid when
/// the sampler knows it. Reads at most the first 200 lines within the
/// first megabyte; both records appear before then, and the cap keeps a
/// corrupt transcript from OOMing the actor thread on a metadata probe.
fn muse_hit(path: &Path, want_cwd: &Path, pid: Option<u32>) -> Option<TranscriptHit> {
    use std::io::{BufRead, Read};
    let file = std::fs::File::open(path).ok()?;
    let reader = std::io::BufReader::new(file.take(1024 * 1024));
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
                // `try_from` (not `as`): a huge pid must degrade to a
                // cwd-only candidate, never wrap into a false pid match.
                recorded_pid = record
                    .get("pid")
                    .and_then(|p| p.as_u64())
                    .and_then(|p| u32::try_from(p).ok());
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
    // Directory names can hold anything on Unix; a dirty one would
    // smuggle control characters into badges, logs, and resume argv.
    if !is_clean_id(&id) {
        return None;
    }
    Some(TranscriptHit {
        conversation_id: id,
        path: path.to_path_buf(),
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
/// agent's own cwd is unreadable, and when neither resolves a bare run
/// still observes kind-only.
pub fn observe_pid(
    pid: u32,
    session_cwd: Option<&Path>,
    now: std::time::SystemTime,
    max_transcript_age: std::time::Duration,
) -> Option<ObservedAgent> {
    let process = read_process(pid)?;
    let cwd = crate::session::child_cwd(pid).or_else(|| session_cwd.map(Path::to_path_buf));
    observe_process(&process, cwd.as_deref(), now, max_transcript_age)
}

/// True when a conversation id is safe to keep: non-empty with no
/// control characters, so ids from argv, transcripts, or filenames can
/// never smuggle terminal escapes into badges, logs, or resume argv.
fn is_clean_id(id: &str) -> bool {
    !id.is_empty() && !id.chars().any(|c| c.is_control())
}

/// True when an argv-supplied conversation id is safe to join into a
/// transcript path: a single file stem with no separators, so a hostile
/// or display-name id can never escape the project directory.
fn is_path_safe_id(id: &str) -> bool {
    !id.is_empty()
        && id != "."
        && id != ".."
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// Transcript path derived from an argv-carried conversation id. Only
/// Claude's store is deterministic from the id (so argv observations
/// still get a staleness-checkable path), and only path-safe ids derive
/// one: the id comes straight from argv, so a hostile or display-name id
/// must never escape the project directory. The id itself is still kept
/// for resume argv.
fn argv_transcript_path(
    kind: AgentKind,
    id: &str,
    cwd: Option<&Path>,
    store_root: Option<&Path>,
) -> Option<PathBuf> {
    match kind {
        AgentKind::Claude if is_path_safe_id(id) => {
            let cwd = cwd?;
            let store_root = store_root?;
            let path = claude_project_dir(store_root, cwd)?.join(format!("{id}.jsonl"));
            path.is_file().then_some(path)
        }
        _ => None,
    }
}

/// Classify an already-read process, correlating a bare run to its
/// transcript when the cwd is known. Split from [`observe_pid`] so the
/// unresolvable-cwd path gets unit coverage without a live pid: it
/// yields kind-only tracking rather than dropping the observation.
fn observe_process(
    process: &PidProcess,
    cwd: Option<&Path>,
    now: std::time::SystemTime,
    max_transcript_age: std::time::Duration,
) -> Option<ObservedAgent> {
    let kind = AgentKind::detect(&process.exe_name())?;
    let classified = classify_argv(kind, &process.argv)?;
    if classified.mode != AgentRunMode::Interactive {
        return None;
    }
    // A dirty argv id falls through to correlation (usually kind-only):
    // control characters must never reach badges, logs, or resume argv.
    if classified
        .conversation_id
        .as_ref()
        .is_some_and(|id| !is_clean_id(id))
    {
        tracing::debug!(
            kind = ?kind,
            pid = process.pid,
            "dropping dirty argv conversation id; falling through to correlation"
        );
    }
    if let Some(id) = classified.conversation_id.filter(|id| is_clean_id(id)) {
        let transcript_path =
            argv_transcript_path(kind, &id, cwd, transcript_store_root(kind).as_deref());
        return Some(ObservedAgent {
            kind,
            pid: process.pid,
            exe_path: process.exe_path.clone(),
            conversation_id: Some(id),
            transcript_path,
        });
    }
    let root = transcript_store_root(kind);
    // No resolvable cwd skips correlation instead of dropping the
    // observation: kind-only tracking still restores the agent's
    // most-recent conversation.
    let correlation = match cwd {
        Some(cwd) => correlate(
            kind,
            root.as_deref(),
            cwd,
            Some(process.pid),
            now,
            max_transcript_age,
        ),
        None => Correlation::None,
    };
    let (conversation_id, transcript_path) = match correlation {
        Correlation::Single(hit) => (Some(hit.conversation_id), Some(hit.path)),
        Correlation::None => (None, None),
        Correlation::Multiple => {
            tracing::debug!(
                kind = ?kind,
                pid = process.pid,
                "transcript correlation found multiple contenders; tracking kind-only"
            );
            (None, None)
        }
    };
    Some(ObservedAgent {
        kind,
        pid: process.pid,
        exe_path: process.exe_path.clone(),
        conversation_id,
        transcript_path,
    })
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
    // Kernel pids fit `c_int`; refuse to wrap instead of querying the
    // wrong process at the FFI boundary.
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut buf = vec![0 as libc::c_char; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: `buf` is a writable `PROC_PIDPATHINFO_MAXSIZE` buffer, the
    // documented size for `proc_pidpath`.
    let len = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
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
    // Kernel pids fit `c_int`; refuse to wrap instead of querying the
    // wrong process at the FFI boundary.
    let pid = c_int::try_from(pid).ok()?;
    let mut mib = [libc::CTL_KERN as c_int, libc::KERN_PROCARGS2 as c_int, pid];
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
    parse_procargs2_argv(&buf)
}

/// Parse a `KERN_PROCARGS2` buffer into argv. Layout: argc (int), exec path
/// cstring, then argc argv cstrings, then the environment. NUL padding sits
/// between the strings, so each read skips a NUL run first. Only argv is
/// read. Split from the sysctl call so truncated or inconsistent kernel
/// buffers get unit coverage on every platform; every slice is checked, so
/// a short buffer yields `None`, never a panic.
#[cfg(any(target_os = "macos", test))]
fn parse_procargs2_argv(buf: &[u8]) -> Option<Vec<String>> {
    let argc_bytes: [u8; 4] = buf.get(0..4)?.try_into().ok()?;
    let argc_i32 = i32::from_ne_bytes(argc_bytes);
    if argc_i32 < 0 {
        return None;
    }
    let argc = argc_i32 as usize;
    let mut offset = 4;
    let next_cstring = |offset: &mut usize| -> Option<String> {
        while buf.get(*offset) == Some(&0) {
            *offset += 1;
        }
        let rest = buf.get(*offset..)?;
        let end = rest.iter().position(|b| *b == 0)? + *offset;
        let s = String::from_utf8_lossy(buf.get(*offset..end)?).into_owned();
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
#[derive(Default)]
pub struct FgAgentTracker {
    last_poll: Option<std::time::Instant>,
    last_fg_pid: Option<u32>,
    candidate: Option<(ObservedAgent, std::time::Instant)>,
    reported: Option<AgentAttachment>,
    last_correlate: Option<std::time::Instant>,
    /// A foreground pid whose first resolution failed and is owed one
    /// retry: transient read misses (process mid-exec, /proc races) must
    /// neither wedge attach nor emit a spurious detach.
    pending_resolve: Option<u32>,
    /// A seeded attachment still owes its first confirmation. The first
    /// steady re-observation emits the seed once (the flush treats it as
    /// compared-equal, so this costs one message and no persist); without
    /// that signal the manager cannot tell "tracker alive and steady"
    /// from "resume failed before any observation" at demote time.
    seed_unconfirmed: bool,
    /// Whether any processed poll has seen a foreground pid. A seed
    /// detaches only on proof (a resolved non-agent pid, a foreground
    /// that went away), never on an initial `None` reading, which on a
    /// fresh seed means "nothing observed yet".
    observed_fg: bool,
}

impl FgAgentTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// A tracker that already reports `initial`, for restores and handover
    /// adoption: seeding the live entry alone would strand the attachment,
    /// since a fresh tracker has nothing to clear it with when the
    /// foreground turns out not to be that agent. A seed also owes one
    /// confirmation, emitted on the first steady re-observation.
    pub fn seeded(initial: Option<AgentAttachment>) -> Self {
        Self {
            seed_unconfirmed: initial.is_some(),
            reported: initial,
            ..Self::default()
        }
    }

    /// True when a poll now would do work rather than hit the throttle.
    /// Lets the actor skip its `tcgetpgrp` on ticks the tracker would
    /// discard.
    pub fn poll_due(&self, now: std::time::Instant) -> bool {
        self.last_poll
            .is_none_or(|last| now.duration_since(last) >= AGENT_POLL_INTERVAL)
    }

    pub fn poll(
        &mut self,
        fg_pid: Option<u32>,
        resolve: &impl Fn(u32) -> Option<ObservedAgent>,
        now: std::time::Instant,
        now_ms: u64,
    ) -> Option<Option<AgentAttachment>> {
        if !self.poll_due(now) {
            return None;
        }
        self.last_poll = Some(now);
        if fg_pid.is_some() {
            self.observed_fg = true;
        }
        if fg_pid != self.last_fg_pid {
            self.last_fg_pid = fg_pid;
            self.candidate = match fg_pid {
                Some(pid) => {
                    let observed = resolve(pid).map(|obs| (obs, now));
                    // A failed first read is owed one retry, not a
                    // verdict: definitively-non-agent pids resolve None
                    // again on the retry and detach one poll late.
                    self.pending_resolve = if observed.is_none() { fg_pid } else { None };
                    observed
                }
                None => {
                    self.pending_resolve = None;
                    None
                }
            };
            self.last_correlate = Some(now);
        } else if let Some(pid) = fg_pid
            && self.pending_resolve == Some(pid)
        {
            // Second sample for a pid whose first resolution failed: a
            // transient miss attaches now, a definitive None detaches.
            self.pending_resolve = None;
            if let Some(obs) = resolve(pid) {
                self.candidate = Some((obs, now));
                self.last_correlate = Some(now);
            }
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
                // Borrowed identity check: steady-state polls must not
                // clone only to discover nothing changed. The compared
                // set lives in `matches_observation`, shared with
                // `same_observation`, so the two cannot diverge.
                let unchanged = self.reported.as_ref().is_some_and(|reported| {
                    reported.matches_observation(
                        obs.kind,
                        obs.conversation_id.as_deref(),
                        obs.transcript_path.as_deref(),
                        Some(obs.exe_path.as_path()),
                    )
                });
                if unchanged {
                    // First steady re-observation confirms a seed; any
                    // later one is quiet. A transition below supersedes
                    // the seed instead, and clears the debt the same way.
                    if self.seed_unconfirmed {
                        self.seed_unconfirmed = false;
                        Some(self.reported.clone())
                    } else {
                        None
                    }
                } else {
                    let attachment = AgentAttachment {
                        kind: obs.kind,
                        conversation_id: obs.conversation_id.clone(),
                        transcript_path: obs.transcript_path.clone(),
                        exe_path: Some(obs.exe_path.clone()),
                        last_seen_ms: now_ms,
                    };
                    self.seed_unconfirmed = false;
                    self.reported = Some(attachment.clone());
                    Some(Some(attachment))
                }
            }
            Some(_) => None,
            // No detach while a retry is owed: the None may be a
            // transient read miss, not a real foreground change. And no
            // detach before any foreground was ever observed: on a fresh
            // seed that None means "nothing seen yet", not disproof.
            None if self.reported.is_some()
                && self.pending_resolve.is_none()
                && self.observed_fg =>
            {
                self.seed_unconfirmed = false;
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

/// Path to the stub-agent helper binary the build script compiles into
/// OUT_DIR. It ignores argv and blocks quietly until killed. Shared by
/// this module's observation tests and `session.rs`' restore tests, so
/// the `EXE_SUFFIX` handling cannot drift between the two suites.
#[cfg(all(test, unix))]
pub(crate) fn stub_agent_bin() -> PathBuf {
    PathBuf::from(env!("OUT_DIR"))
        .join(format!("triage-stub-agent{}", std::env::consts::EXE_SUFFIX))
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
        // A flag after `--resume` is not its value: bare `--resume`
        // continues the most-recent conversation.
        assert_eq!(
            classify_argv(
                AgentKind::Claude,
                &argv(&["claude", "--resume", "--model", "sonnet"])
            ),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "--resume="])),
            interactive(None)
        );
        // Last value wins; a bare occurrence keeps scanning.
        assert_eq!(
            classify_argv(
                AgentKind::Claude,
                &argv(&["claude", "--resume", "aaa", "--resume", "bbb"])
            ),
            interactive(Some("bbb"))
        );
        assert_eq!(
            classify_argv(
                AgentKind::Claude,
                &argv(&["claude", "--resume", "--resume", "bbb"])
            ),
            interactive(Some("bbb"))
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "--help"])),
            None
        );
        // Subcommands: bookkeeping is untracked, attach carries its id,
        // ultrareview runs headless. Only the first positional decides.
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "doctor"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "gateway"])),
            None
        );
        assert_eq!(
            classify_argv(
                AgentKind::Claude,
                &argv(&["claude", "--model", "sonnet", "mcp", "list"])
            ),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "attach", "sess-9"])),
            interactive(Some("sess-9"))
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "ultrareview"])),
            headless()
        );
        // Commander consumes the token after `--resume` as its id, even
        // when it spells a subcommand.
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "--resume", "mcp"])),
            interactive(Some("mcp"))
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "-v"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "-V"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "-r", "abc"])),
            interactive(Some("abc"))
        );
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "mcp", "list"])),
            None
        );
        // An empty short-flag value is unusable like its long sibling,
        // never an id.
        assert_eq!(
            classify_argv(AgentKind::Claude, &argv(&["claude", "-r", ""])),
            interactive(None)
        );
    }

    #[test]
    fn classify_claude_value_flag_table() {
        // Each spelling below was verified value-taking against the
        // installed binary (`--help` arity or live acceptance). Both
        // directions matter: the consumed token must not surface as a
        // subcommand, and a real subcommand after the value must still
        // dispatch.
        for flag in [
            "--append-system-prompt-file",
            "-d",
            "--debug",
            "--disallowed-tools",
            "--disallowedTools",
            "-n",
            "--name",
            "--permission-prompt-tool",
            "--prompt-suggestions",
            "--remote-control",
            "--system-prompt-file",
            "--teleport",
            "-w",
            "--worktree",
        ] {
            assert_eq!(
                classify_argv(AgentKind::Claude, &argv(&["claude", flag, "mcp"])),
                interactive(None),
                "{flag} must consume the following token",
            );
            assert_eq!(
                classify_argv(AgentKind::Claude, &argv(&["claude", flag, "foo", "mcp"])),
                None,
                "{flag} must leave the subcommand after its value visible",
            );
        }
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
        // Unknown flags ahead of the subcommand hide neither the
        // subcommand nor its id.
        assert_eq!(
            classify_argv(
                AgentKind::Codex,
                &argv(&["codex", "--verbose", "resume", "abc"])
            ),
            interactive(Some("abc"))
        );
        assert_eq!(
            classify_argv(
                AgentKind::Codex,
                &argv(&["codex", "--verbose", "exec", "ls"])
            ),
            headless()
        );
        assert_eq!(
            classify_argv(
                AgentKind::Codex,
                &argv(&["codex", "--profile", "foo", "resume", "abc"])
            ),
            interactive(Some("abc"))
        );
        // Known value flags skip their values even when they spell a
        // subcommand or precede one.
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "--cd", "app"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "-p", "resume", "foo"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "login"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "remote-control"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "--version"])),
            None
        );
        // clap ends flag parsing at `--`: nothing after it is a flag or
        // a subcommand (verified: `codex -- --help` launches instead of
        // printing help).
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "--", "exec"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "--", "resume", "abc"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "--", "--help"])),
            interactive(None)
        );
        // ...but a subcommand before `--` still takes its id after it.
        assert_eq!(
            classify_argv(AgentKind::Codex, &argv(&["codex", "resume", "--", "abc"])),
            interactive(Some("abc"))
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
        // Value flags skip ahead of the subcommand; a non-first `help`
        // is prompt text under Go flag grammar.
        assert_eq!(
            classify_argv(
                AgentKind::Antigravity,
                &argv(&["agy", "--project", "myproj", "mcp", "list"])
            ),
            None
        );
        assert_eq!(
            classify_argv(
                AgentKind::Antigravity,
                &argv(&["agy", "please", "help", "me"])
            ),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Antigravity, &argv(&["agy", "--help"])),
            None
        );
        // Go accepts single-dash long flags (verified: `-help` prints
        // usage), so each spelling below behaves as its double-dash twin.
        assert_eq!(
            classify_argv(
                AgentKind::Antigravity,
                &argv(&["agy", "-conversation", "abc"])
            ),
            interactive(Some("abc"))
        );
        assert_eq!(
            classify_argv(AgentKind::Antigravity, &argv(&["agy", "-conversation=abc"])),
            interactive(Some("abc"))
        );
        assert_eq!(
            classify_argv(AgentKind::Antigravity, &argv(&["agy", "-print", "hi"])),
            headless()
        );
        assert_eq!(
            classify_argv(
                AgentKind::Antigravity,
                &argv(&["agy", "-model", "foo", "mcp", "list"])
            ),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Antigravity, &argv(&["agy", "-help"])),
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
        // `--flag=value` never swallows the following subcommand.
        assert_eq!(
            classify_argv(
                AgentKind::Muse,
                &argv(&["muse", "--workspace=/tmp/x", "resume", "abc"])
            ),
            interactive(Some("abc"))
        );
        // Known value flags skip their values even when they spell a
        // subcommand.
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "--image", "config"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(
                AgentKind::Muse,
                &argv(&["muse", "--approval-judge", "off", "resume", "abc"])
            ),
            interactive(Some("abc"))
        );
        // `-w` takes an optional value, so a bare `-w` leaves the
        // subcommand in place rather than eating it.
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "-w", "resume", "abc"])),
            interactive(Some("abc"))
        );
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "--help"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "--version"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "exec", "hi"])),
            headless()
        );
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "trace", "inspect"])),
            None
        );
        // Subcommand dispatch stops at `--` (verified: `muse -- exec`
        // errors as an unknown argument instead of dispatching), while
        // `--help`/`--version` answer from anywhere (verified: `muse --
        // --help`, `muse -- --version`, and `muse foo --help`).
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "--", "exec"])),
            interactive(None)
        );
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "--", "--help"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "--", "--version"])),
            None
        );
        assert_eq!(
            classify_argv(AgentKind::Muse, &argv(&["muse", "resume", "--", "abc"])),
            interactive(Some("abc"))
        );
    }

    #[test]
    fn resume_commands_cover_id_and_fallback() {
        assert_eq!(
            resume_command(AgentKind::Claude, Some("abc"), None),
            (
                "claude".to_string(),
                vec!["--resume".to_string(), "abc".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Claude, None, None),
            ("claude".to_string(), vec!["--continue".to_string()])
        );
        assert_eq!(
            resume_command(AgentKind::Codex, Some("abc"), None),
            (
                "codex".to_string(),
                vec!["resume".to_string(), "abc".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Codex, None, None),
            (
                "codex".to_string(),
                vec!["resume".to_string(), "--last".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Antigravity, Some("abc"), None),
            (
                "agy".to_string(),
                vec!["--conversation".to_string(), "abc".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Antigravity, None, None),
            ("agy".to_string(), vec!["--continue".to_string()])
        );
        assert_eq!(
            resume_command(AgentKind::Muse, Some("abc"), None),
            (
                "muse".to_string(),
                vec!["resume".to_string(), "abc".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Muse, None, None),
            (
                "muse".to_string(),
                vec!["resume".to_string(), "--last".to_string()]
            )
        );
        // A recorded binary that still exists is used verbatim; a moved
        // one degrades to a `PATH` lookup.
        let dir = unique_dir("exebin");
        let exe = dir.join("codex");
        write(&exe, "x");
        assert_eq!(
            resume_command(AgentKind::Codex, Some("abc"), Some(&exe)),
            (
                exe.to_string_lossy().into_owned(),
                vec!["resume".to_string(), "abc".to_string()]
            )
        );
        assert_eq!(
            resume_command(AgentKind::Codex, Some("abc"), Some(&dir.join("gone"))).0,
            "codex".to_string(),
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // Unix path contract (`/Users/...` is not absolute on Windows); the
    // Windows slug mapping rides with the Windows observation follow-up.
    #[test]
    #[cfg(unix)]
    fn claude_project_slug_replaces_separators() {
        let root = Path::new("/home/me/.claude/projects");
        assert_eq!(
            claude_project_dir(root, Path::new("/Users/me/repo")),
            Some(root.join("-Users-me-repo"))
        );
        assert_eq!(claude_project_dir(root, Path::new("repo")), None);
    }

    #[test]
    #[cfg(windows)]
    fn claude_project_slug_replaces_windows_separators() {
        let root = Path::new(r"C:\Users\me\.claude\projects");
        // `\` and `:` map to `-` so the slug stays relative and `join`
        // cannot discard the store root.
        assert_eq!(
            claude_project_dir(root, Path::new(r"C:\repo")),
            Some(root.join("C--repo"))
        );
        assert_eq!(claude_project_dir(root, Path::new("repo")), None);
    }

    #[test]
    fn path_safe_ids_reject_separators_and_dot_segments() {
        assert!(is_path_safe_id("abc123"));
        assert!(is_path_safe_id("550e8400-e29b-41d4-a716-446655440000"));
        assert!(!is_path_safe_id(""));
        assert!(!is_path_safe_id("."));
        assert!(!is_path_safe_id(".."));
        assert!(!is_path_safe_id("../planted"));
        assert!(!is_path_safe_id("a/b"));
        assert!(!is_path_safe_id("a\\b"));
        assert!(!is_path_safe_id("display name"));
    }

    #[test]
    fn argv_transcript_path_gates_on_kind_safety_and_existence() {
        let root = unique_dir("projects");
        let cwd = root.join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        let projects = root.join("projects");
        let dir = claude_project_dir(&projects, &cwd).unwrap();
        // Safe id with an existing transcript resolves.
        write(&dir.join("abc.jsonl"), "{}\n");
        assert_eq!(
            argv_transcript_path(AgentKind::Claude, "abc", Some(&cwd), Some(&projects)),
            Some(dir.join("abc.jsonl"))
        );
        // Safe id with no transcript resolves to nothing.
        assert_eq!(
            argv_transcript_path(AgentKind::Claude, "missing", Some(&cwd), Some(&projects)),
            None
        );
        // A traversal id resolves to nothing even with its escape
        // target planted: the guard runs before the existence check.
        write(&projects.join("planted.jsonl"), "{}\n");
        assert_eq!(
            argv_transcript_path(AgentKind::Claude, "../planted", Some(&cwd), Some(&projects)),
            None
        );
        // Non-Claude stores are never deterministic from the id.
        assert_eq!(
            argv_transcript_path(AgentKind::Codex, "abc", Some(&cwd), Some(&projects)),
            None
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn observe_process_treats_dirty_argv_id_as_bare() {
        let process = PidProcess {
            pid: 4242,
            exe_path: PathBuf::from("/bin/codex"),
            argv: argv(&["codex", "resume", "a\nb"]),
        };
        let observed = observe_process(
            &process,
            None,
            std::time::SystemTime::now(),
            std::time::Duration::from_secs(900),
        )
        .expect("dirty argv id still observes kind-only");
        assert_eq!(observed.kind, AgentKind::Codex);
        assert_eq!(observed.conversation_id, None);
        assert_eq!(observed.transcript_path, None);
    }

    #[test]
    fn correlate_codex_skips_empty_and_dirty_ids() {
        let root = unique_dir("codex-ids");
        let day = root.join("2026").join("09").join("20");
        let cwd = root.join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        let meta = |id: &str| {
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"session_id\":\"{id}\",\
                 \"parent_thread_id\":null,\"originator\":\"codex-tui\",\"cwd\":\"{}\"}}}}\n",
                cwd.to_string_lossy().replace('\\', "\\\\"),
            )
        };
        // Empty and control-character ids are corrupt; neither attaches
        // (both present would otherwise read as Multiple).
        write(&day.join("rollout-empty.jsonl"), &meta(""));
        write(&day.join("rollout-dirty.jsonl"), &meta("a\\nb"));
        let now = std::time::SystemTime::now();
        let max_age = std::time::Duration::from_secs(900);
        assert_eq!(
            correlate(AgentKind::Codex, Some(&root), &cwd, None, now, max_age),
            Correlation::None
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn read_first_json_line_caps_huge_lines() {
        let dir = unique_dir("huge-line");
        let path = dir.join("rollout-huge.jsonl");
        // Valid JSON past the 64 KiB cap truncates and fails to parse
        // instead of allocating unboundedly.
        write(&path, &format!("{{\"a\":\"{}\"}}\n", "x".repeat(200_000)));
        assert_eq!(read_first_json_line(&path), None);
        let _ = std::fs::remove_dir_all(&dir);
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
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn correlate_codex_filters_roots_and_cwd() {
        let root = unique_dir("codex");
        let day = root.join("2026").join("09").join("20");
        let cwd = root.join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        let meta = |id: &str, parent: &str, cwd: &str| {
            // Real transcripts JSON-escape the cwd; raw Windows backslashes
            // would be invalid escapes and fail to parse.
            let cwd = cwd.replace('\\', "\\\\");
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
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn correlate_muse_uses_pid_and_top_level() {
        let root = unique_dir("muse");
        let day = root.join("2026").join("09").join("20");
        let cwd = root.join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        let session = |facts: &str, session: &str| format!("{facts}\n{session}\n");
        let facts = |cwd: &str, pid: u32| {
            // Real transcripts JSON-escape the cwd; raw Windows backslashes
            // would be invalid escapes and fail to parse.
            let cwd = cwd.replace('\\', "\\\\");
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
        let _ = std::fs::remove_dir_all(&root);
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
        let (mut child, dir) = spawn_stub_agent("claude", &["--resume", "abc123"]);
        // The child may not have exec'd when the parent first reads /proc
        // (a loaded runner schedules it late), and the pre-exec image
        // observes as nothing. Retry briefly rather than flaking.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let observed = loop {
            if let Some(observed) = observe_pid(
                child.id(),
                None,
                std::time::SystemTime::now(),
                std::time::Duration::from_secs(900),
            ) {
                break observed;
            }
            assert!(std::time::Instant::now() < deadline, "observe stub agent");
            std::thread::sleep(std::time::Duration::from_millis(10));
        };
        assert_eq!(observed.kind, AgentKind::Claude);
        assert_eq!(observed.conversation_id.as_deref(), Some("abc123"));
        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn observe_pid_headless_stub_is_ignored() {
        let (mut child, dir) = spawn_stub_agent("codex", &["exec"]);
        // Wait for exec first: the pre-exec image also observes as None,
        // which would pass without touching the headless path.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            if read_process(child.id()).is_some_and(|p| p.exe_name() == "codex") {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "stub agent never exec'd"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
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
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    fn read_process_without_reader_degrades_to_nothing() {
        // No process reader on this platform yet: detection stays off
        // rather than guessing.
        assert_eq!(read_process(std::process::id()), None);
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

    /// Build a `KERN_PROCARGS2`-shaped buffer: argc plus NUL-terminated
    /// strings with `pad` extra NULs between them, like the kernel emits.
    fn procargs2(argc: i32, strings: &[&str], pad: usize) -> Vec<u8> {
        let mut buf = argc.to_ne_bytes().to_vec();
        for s in strings {
            buf.extend_from_slice(s.as_bytes());
            buf.resize(buf.len() + 1 + pad, 0);
        }
        buf
    }

    #[test]
    fn procargs2_parses_argv_with_nul_padding() {
        let buf = procargs2(2, &["/bin/claude", "claude", "--resume"], 2);
        assert_eq!(
            parse_procargs2_argv(&buf),
            Some(vec!["claude".to_string(), "--resume".to_string()])
        );
    }

    #[test]
    fn procargs2_truncated_buffer_returns_none() {
        // argc promises two argv entries; the buffer ends mid-string.
        let mut buf = procargs2(2, &["/bin/claude", "claude"], 0);
        buf.truncate(buf.len() - 3);
        assert_eq!(parse_procargs2_argv(&buf), None);
    }

    #[test]
    fn procargs2_inconsistent_argc_returns_none() {
        // argc far beyond what the buffer holds: no panic, just None.
        let buf = procargs2(i32::MAX, &["/bin/claude"], 0);
        assert_eq!(parse_procargs2_argv(&buf), None);
    }

    #[test]
    fn procargs2_short_buffer_returns_none() {
        assert_eq!(parse_procargs2_argv(&[]), None);
        assert_eq!(parse_procargs2_argv(&[1, 0, 0]), None);
    }

    #[test]
    fn procargs2_negative_argc_returns_none() {
        let buf = procargs2(-1, &["/bin/claude", "claude"], 0);
        assert_eq!(parse_procargs2_argv(&buf), None);
    }

    #[test]
    fn observe_process_without_cwd_yields_kind_only() {
        // A bare run whose cwd is unresolvable (sandboxed or exited
        // process) still observes: correlation is skipped, tracking is
        // kind-only, and nothing touches the transcript store.
        let process = PidProcess {
            pid: 999_999_999,
            exe_path: PathBuf::from("/usr/local/bin/codex"),
            argv: argv(&["codex"]),
        };
        let observed = observe_process(
            &process,
            None,
            std::time::SystemTime::now(),
            std::time::Duration::from_secs(900),
        )
        .expect("bare agent without cwd still observes");
        assert_eq!(observed.kind, AgentKind::Codex);
        assert_eq!(observed.pid, 999_999_999);
        assert_eq!(observed.conversation_id, None);
        assert_eq!(observed.transcript_path, None);
    }

    fn seed_attachment() -> AgentAttachment {
        AgentAttachment {
            kind: AgentKind::Claude,
            conversation_id: Some("abc".to_string()),
            transcript_path: Some(PathBuf::from("/tmp/triage-seed-transcript.jsonl")),
            exe_path: Some(PathBuf::from("/usr/local/bin/claude")),
            last_seen_ms: 1,
        }
    }

    #[test]
    fn seeded_tracker_detaches_when_foreground_is_not_the_agent() {
        let mut tracker = FgAgentTracker::seeded(Some(seed_attachment()));
        let resolve = |_pid: u32| -> Option<ObservedAgent> { None };
        let start = std::time::Instant::now();
        // First poll owes the new pid one retry rather than detaching on a
        // possibly transient read miss.
        assert_eq!(tracker.poll(Some(999), &resolve, start, 2), None);
        assert_eq!(
            tracker.poll(Some(999), &resolve, start + AGENT_POLL_INTERVAL, 3),
            Some(None)
        );
    }

    #[test]
    fn seeded_tracker_confirms_once_then_stays_quiet() {
        let seed = seed_attachment();
        let mut tracker = FgAgentTracker::seeded(Some(seed.clone()));
        let resolve = |pid: u32| -> Option<ObservedAgent> {
            Some(ObservedAgent {
                kind: seed.kind,
                pid,
                exe_path: seed.exe_path.clone().unwrap(),
                conversation_id: seed.conversation_id.clone(),
                transcript_path: seed.transcript_path.clone(),
            })
        };
        let start = std::time::Instant::now();
        assert_eq!(tracker.poll(Some(42), &resolve, start, 2), None);
        assert_eq!(
            tracker.poll(Some(42), &resolve, start + AGENT_POLL_INTERVAL, 3),
            None
        );
        // Past the attach debounce the observation matches the seed exactly:
        // the first steady match confirms the seed once (the flush treats
        // it as compared-equal), and only then does the tracker go quiet.
        // Without the confirmation the manager cannot tell a healthy
        // steady seed from a resume that failed before any observation.
        assert_eq!(
            tracker.poll(
                Some(42),
                &resolve,
                start + AGENT_ATTACH_AFTER + AGENT_POLL_INTERVAL,
                4
            ),
            Some(Some(seed.clone()))
        );
        assert_eq!(
            tracker.poll(
                Some(42),
                &resolve,
                start + AGENT_ATTACH_AFTER + 2 * AGENT_POLL_INTERVAL,
                5
            ),
            None
        );
    }

    #[test]
    fn seeded_tracker_stays_quiet_until_a_foreground_is_observed() {
        let mut tracker = FgAgentTracker::seeded(Some(seed_attachment()));
        let resolve = |_pid: u32| -> Option<ObservedAgent> { None };
        let start = std::time::Instant::now();
        // A fresh seed has observed nothing: repeated `None` polls (the
        // pre-foreground state, and every poll on non-unix) must not
        // detach the seed they never disproved.
        assert_eq!(tracker.poll(None, &resolve, start, 2), None);
        assert_eq!(
            tracker.poll(None, &resolve, start + AGENT_POLL_INTERVAL, 3),
            None
        );
        assert_eq!(
            tracker.poll(None, &resolve, start + 2 * AGENT_POLL_INTERVAL, 4),
            None
        );
        // ...but a resolved non-agent pid still detaches once observed:
        // the first poll owes the retry, the second detaches.
        assert_eq!(
            tracker.poll(Some(999), &resolve, start + 3 * AGENT_POLL_INTERVAL, 5),
            None
        );
        assert_eq!(
            tracker.poll(Some(999), &resolve, start + 4 * AGENT_POLL_INTERVAL, 6),
            Some(None)
        );
    }

    #[test]
    fn tracker_detaches_when_the_foreground_goes_away() {
        let mut tracker = FgAgentTracker::new();
        let resolve = |pid: u32| Some(observed(AgentKind::Claude, pid, Some("abc")));
        let start = std::time::Instant::now();
        assert_eq!(tracker.poll(Some(42), &resolve, start, 1), None);
        let report = tracker.poll(Some(42), &resolve, start + AGENT_ATTACH_AFTER, 2);
        assert!(attached(&report).is_some());
        // The foreground going away after an observation is proof of
        // change, so this `None` detaches.
        assert_eq!(
            tracker.poll(
                None,
                &resolve,
                start + AGENT_ATTACH_AFTER + AGENT_POLL_INTERVAL,
                3
            ),
            Some(None)
        );
    }

    #[test]
    fn tracker_recovers_when_retry_resolves_after_transient_miss() {
        use std::cell::Cell;
        let missed = Cell::new(false);
        let mut tracker = FgAgentTracker::new();
        let start = std::time::Instant::now();
        let resolve = |pid: u32| {
            if missed.get() {
                Some(observed(AgentKind::Claude, pid, Some("abc")))
            } else {
                missed.set(true);
                None
            }
        };
        // First read misses; the retry owed to this pid recovers.
        assert_eq!(tracker.poll(Some(111), &resolve, start, 1), None);
        assert_eq!(
            tracker.poll(Some(111), &resolve, start + AGENT_POLL_INTERVAL, 2),
            None
        );
        // The recovered candidate still serves the full attach hold.
        let report = tracker.poll(
            Some(111),
            &resolve,
            start + AGENT_POLL_INTERVAL + AGENT_ATTACH_AFTER,
            3,
        );
        assert_eq!(
            attached(&report).unwrap().conversation_id.as_deref(),
            Some("abc")
        );
    }
}
