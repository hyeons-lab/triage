use crate::config::JudgeConfig;
use crate::judge::{JudgeDecision, JudgeRequest, JudgeSource, JudgeVerdict};

/// Strips server / namespace prefixes (e.g. `default_api:view_file` -> `view_file`,
/// `mcp__code_review_graph__query_graph` -> `query_graph`, `cortex:read` -> `read`).
pub fn normalize_tool_name(tool_name: &str) -> &str {
    let mut s = tool_name.trim();
    if let Some(rest) = s.strip_prefix("cortex_step_type_") {
        s = rest;
    }
    if let Some(rest) = s.strip_prefix("cortex:") {
        s = rest;
    }
    if let Some(idx) = s.rfind(':') {
        s = &s[idx + 1..];
    }
    if let Some(idx) = s.rfind('/') {
        s = &s[idx + 1..];
    }
    if let Some(idx) = s.rfind("__") {
        s = &s[idx + 2..];
    }
    s.trim()
}

/// True if `tool_name` is a read-only inspection, search, web, or agent coordination tool.
pub fn is_read_only_tool(raw: &str) -> bool {
    let lower_str = normalize_tool_name(raw).to_ascii_lowercase();
    let lower = lower_str.as_str();
    matches!(
        lower,
        "read"
            | "view_file"
            | "read_file"
            | "viewfile"
            | "readfile"
            | "view_file_outline"
            | "get_file_info"
            | "read_symbol"
            | "inspect_file"
            | "list_dir"
            | "listdir"
            | "ls"
            | "list_directory"
            | "find_by_name"
            | "findbyname"
            | "list_permissions"
            | "listpermissions"
            | "grep_search"
            | "grep"
            | "grepsearch"
            | "search_files"
            | "search_web"
            | "web_search"
            | "websearch"
            | "read_url_content"
            | "read_url"
            | "read_browser_page"
            | "web_fetch"
            | "webfetch"
            | "ask_question"
            | "ask_user_question"
            | "askuserquestion"
            | "invoke_subagent"
            | "send_message"
            | "manage_subagents"
            | "define_subagent"
            | "task_status"
            | "taskstatus"
            | "get_task_status"
            | "gettaskstatus"
            | "list_tasks"
            | "listtasks"
            | "task_list"
            | "tasklist"
            | "tool_search"
            | "toolsearch"
            | "skill"
            | "artifact"
            | "generate_image"
            | "detect_changes"
            | "get_review_context"
            | "get_impact_radius"
            | "get_affected_flows"
            | "query_graph"
            | "semantic_search_nodes"
            | "get_architecture_overview"
            | "list_communities"
            | "refactor_tool"
            | "refactortool"
    )
}

/// True if `tool_name` is an editing or writing tool.
pub fn is_edit_tool(raw: &str) -> bool {
    let lower_str = normalize_tool_name(raw).to_ascii_lowercase();
    let lower = lower_str.as_str();
    matches!(
        lower,
        "write_to_file"
            | "replace_file_content"
            | "edit_file"
            | "write_file"
            | "patch_file"
            | "create_file"
    )
}

/// True if `tool_name` is a shell command execution tool.
pub fn is_command_tool(raw: &str) -> bool {
    let lower_str = normalize_tool_name(raw).to_ascii_lowercase();
    let lower = lower_str.as_str();
    matches!(
        lower,
        "run_command"
            | "runcommand"
            | "bash"
            | "execute"
            | "execute_command"
            | "executecommand"
            | "sh"
            | "terminal"
            | "shell"
            | "cmd"
            | "command"
            | "exec"
    )
}

pub const MAX_COMMAND_CHARS: usize = 8192;

pub const BUILTIN_ALLOW_COMMANDS: &[&str] = &[
    // Read-only filesystem and content inspection.
    "ls",
    "cat",
    "head",
    "tail",
    "wc",
    "file",
    "stat",
    "du",
    "df",
    "tree",
    "realpath",
    "dirname",
    "basename",
    "diff",
    "colordiff",
    "sort",
    "uniq",
    "awk",
    "sed",
    "cut",
    "tr",
    "jq",
    "column",
    "md5",
    "shasum",
    "sha256sum",
    // Safe filesystem mutation.
    "mkdir",
    "cp",
    "touch",
    "chmod +x",
    // Search.
    "rg",
    "grep",
    "egrep",
    "fgrep",
    "fd",
    "find",
    // Environment, machine, and process inspection.
    "which",
    "type",
    "date",
    "uname",
    "whoami",
    "hostname",
    "echo",
    "printf",
    "true",
    "false",
    "read",
    "pwd",
    "cd",
    "pushd",
    "popd",
    "id",
    "ps",
    "pgrep",
    "lsof",
    "sw_vers",
    "export",
    "codesign -v",
    "codesign --verify",
    "codesign -d",
    "codesign --display",
    "codesign -s",
    "codesign --sign",
    "pbpaste",
    "pbcopy",
    "xclip",
    "wl-paste",
    "wl-copy",
    "triaged reload",
    "triaged --handover",
    // Read-only and routine git operations.
    "git status",
    "git diff",
    "git log",
    "git show",
    "git add",
    "git commit",
    "git checkout",
    "git switch",
    "git restore",
    "git branch",
    "git tag",
    "git stash",
    "git rebase --continue",
    "git rebase --abort",
    "git rebase --skip",
    "git rebase --quit",
    "git cherry-pick --continue",
    "git cherry-pick --abort",
    "git cherry-pick --skip",
    "git merge --continue",
    "git merge --abort",
    "git remote -v",
    "git rev-parse",
    "git rev-list",
    "git merge-base",
    "git blame",
    "git ls-files",
    "git worktree list",
    "git check-ignore",
    "git describe",
    "git --version",
    // Rust build, check, test, lint, and formatting.
    "cargo check",
    "cargo build",
    "cargo fmt",
    "cargo clippy",
    "cargo test",
    "cargo doc",
    "cargo tree",
    "cargo metadata",
    "cargo install",
    "cargo init",
    "cargo new",
    "cargo --version",
    "rustc --version",
    // Flutter and Dart build, test, lint, and formatting.
    "flutter analyze",
    "flutter test",
    "flutter doctor",
    "flutter build",
    "flutter pub get",
    "flutter devices",
    "flutter --version",
    "dart analyze",
    "dart test",
    "dart format",
    "dart --version",
    // Read-only GitHub CLI queries.
    "gh pr view",
    "gh pr list",
    "gh pr checks",
    "gh pr diff",
    "gh pr status",
    "gh pr ready",
    "gh run view",
    "gh run list",
    "gh run watch",
    "gh status",
    "gh issue view",
    "gh issue list",
    "gh issue status",
    "gh repo view",
    "gh repo list",
    "gh release view",
    "gh release list",
    "gh workflow view",
    "gh workflow list",
    "gh secret list",
    "gh auth status",
    "gh stack view",
    "gh --version",
    // Utilities & Task runners.
    "sleep",
    "just",
    "make",
    "./scripts/*",
    "scripts/*",
    "./scripts/install.sh",
    "scripts/install.sh",
    "./scripts/bump-version.sh",
    "scripts/bump-version.sh",
    "./gradlew",
    "gradlew",
    "gradle",
    "dart pub get",
    "dart pub",
    "dart run",
    "pnpm test",
    "pnpm run",
    "pnpm build",
    "pnpm check",
    "yarn test",
    "yarn run",
    "yarn build",
    "yarn check",
    "bun test",
    "bun run",
    "bun build",
    "bun check",
    "npm test",
    "npm run",
    "npm build",
    "npm ci",
    // Python and test runners.
    "python",
    "python3",
    "pytest",
    "python -m pytest",
    "python3 -m pytest",
    "python -m unittest",
    "python3 -m unittest",
    "python --version",
    "python3 --version",
    "uv run",
    "uv test",
    "uv pip list",
    "pip list",
    "pip show",
    "pip check",
    // Node ecosystem.
    "node",
    // Go ecosystem.
    "go test",
    "go vet",
    "go fmt",
    "go version",
    // Android debug bridge and fastboot.
    "adb",
    "adb devices",
    "adb logcat",
    "adb shell",
    "adb exec-out",
    "adb exec-out",
    "adb push",
    "adb pull",
    "adb install",
    "adb uninstall",
    "adb forward",
    "adb reverse",
    "adb emu",
    "adb bugreport",
    "adb wait-for-device",
    "adb connect",
    "adb disconnect",
    "adb start-server",
    "adb kill-server",
    "adb version",
    "fastboot",
    "fastboot devices",
    // Docker & Container tools.
    "docker",
    "docker build",
    "docker run",
    "docker compose",
    "docker ps",
    "docker images",
    "docker logs",
    "docker exec",
    "docker version",
    "docker info",
    "docker inspect",
    "podman",
    "podman build",
    "podman run",
    // Archive & Compression utilities.
    "unzip",
    "zip",
    "zipinfo",
    "tar",
    "gzip",
    "gunzip",
    // Triage workspace binaries & hooks.
    "triage",
    "triaged",
    "triage-hook",
    "triage-mcp",
];

pub const BUILTIN_SENSITIVE_SUBSTRINGS: &[&str] = &[
    // Privilege escalation.
    "sudo ",
    "doas ",
    "pkexec ",
    "antigravity-oauth-token",
    "security find-generic-password",
    "security find-internet-password",
    "/etc/shadow",
    // Disk and device writes.
    "diskutil erase",
    "of=/dev/",
    // Machine state.
    "launchctl bootout",
    // Outward-facing publishing / releases.
    "cargo publish",
    "npm publish",
    "gradle publish",
    "gradlew publish",
    "gh release",
    "gh pr create",
    // Permission blanket-opening.
    "chmod 777",
    "chmod -r 777",
];

pub const CREDENTIAL_PATHS: &[&str] = &[
    ".ssh",
    ".gnupg",
    ".netrc",
    ".aws/credentials",
    ".aws/config",
    ".git-credentials",
    ".cargo/credentials.toml",
    ".cargo/credentials",
    ".dockercfg",
    ".docker/config.json",
    ".npmrc",
    ".pypirc",
    ".kube/config",
    ".vault-token",
    ".config/op",
    ".config/gh/hosts.yml",
    ".config/gcloud",
    ".claude.json",
    ".claude/settings.json",
    ".env",
    ".envrc",
    ".bashrc",
    ".zshrc",
    ".bash_profile",
    ".zprofile",
    ".profile",
    "etc/passwd",
    "/etc/passwd",
    "etc/shadow",
    "/etc/shadow",
    "etc/sudoers",
    "/etc/sudoers",
    "etc/hosts",
    "/etc/hosts",
];

pub const DESTRUCTIVE_PROGRAMS: &[&str] = &[
    "shutdown", "reboot", "halt", "poweroff", "mkfs", "fdisk", "dd",
];

pub const PIPE_TARGETS: &[&str] = &[
    "sh", "bash", "zsh", "fish", "python", "python3", "ruby", "perl",
];

pub const NETWORK_FETCHERS: &[&str] = &["curl", "wget", "http ", "https://"];

#[derive(Debug, Clone)]
pub struct JudgeRules {
    custom_deny_substrings: Vec<String>,
    custom_allow_commands: Vec<(String, Vec<String>)>,
    builtin_allow_commands: &'static [(String, Vec<String>)],
}

fn builtin_parsed_allow_commands() -> &'static [(String, Vec<String>)] {
    static BUILTIN: std::sync::OnceLock<Vec<(String, Vec<String>)>> = std::sync::OnceLock::new();
    BUILTIN.get_or_init(|| {
        BUILTIN_ALLOW_COMMANDS
            .iter()
            .map(|entry| {
                let clean_entry = entry.trim_end_matches('*').trim();
                let tokens = tokenize_words(clean_entry);
                ((*entry).to_string(), tokens)
            })
            .filter(|(_, tokens)| !tokens.is_empty())
            .collect()
    })
}

fn is_dangerous_git_network_arg(arg: &str) -> bool {
    arg.contains("ext::")
        || arg.contains("fd::")
        || arg.starts_with("--upload-pack")
        || arg.starts_with("--exec")
}

impl JudgeRules {
    pub fn new(config: &JudgeConfig) -> Self {
        let custom_deny_substrings: Vec<String> = config
            .deny_substrings
            .iter()
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty())
            .collect();
        let parse_entries = |entries: &[String]| -> Vec<(String, Vec<String>)> {
            entries
                .iter()
                .map(|entry| {
                    let clean_entry = entry.trim_end_matches('*').trim();
                    let tokens = tokenize_words(clean_entry);
                    (entry.clone(), tokens)
                })
                .filter(|(_, tokens)| !tokens.is_empty())
                .collect()
        };
        let custom_allow_commands = parse_entries(&config.allow_commands);
        let builtin_allow_commands = builtin_parsed_allow_commands();
        Self {
            custom_deny_substrings,
            custom_allow_commands,
            builtin_allow_commands,
        }
    }

    pub fn evaluate(&self, request: &JudgeRequest) -> Option<JudgeVerdict> {
        let tool_name = request.tool_name.trim();
        let lower_tool_name = tool_name.to_ascii_lowercase();

        // 1. Read-only inspection tools.
        if is_read_only_tool(&lower_tool_name) {
            if let Some(secret) = check_target_credential_path(request) {
                return Some(JudgeVerdict::fallback(format!(
                    "requires manual approval for credential path: {secret}"
                )));
            }
            return Some(JudgeVerdict {
                decision: JudgeDecision::Allow,
                source: JudgeSource::AllowRule,
                reason: format!("read-only tool call: {tool_name}"),
            });
        }

        // 2. File editing / writing tools.
        if is_edit_tool(&lower_tool_name) {
            if let Some(secret) = check_target_credential_path(request) {
                return Some(JudgeVerdict::fallback(format!(
                    "requires manual approval for credential path: {secret}"
                )));
            }
            return Some(JudgeVerdict {
                decision: JudgeDecision::Allow,
                source: JudgeSource::AllowRule,
                reason: format!("edit tool call: {tool_name}"),
            });
        }

        // 3. Command execution tools.
        if !is_command_tool(&lower_tool_name) {
            return Some(JudgeVerdict::fallback(format!(
                "tool {tool_name} is not judged"
            )));
        }

        let command = request.command_line.as_deref().unwrap_or("").trim();
        if command.is_empty() {
            return Some(JudgeVerdict::fallback("tool call carried no command"));
        }
        if command.chars().take(MAX_COMMAND_CHARS + 1).count() > MAX_COMMAND_CHARS {
            return Some(JudgeVerdict::fallback("command is too long to judge"));
        }
        let unquoted = unquote_segment(command);
        let lowered = normalize_lowered(&unquoted);

        // 3a. Custom hard deny rules explicitly configured by the user.
        if let Some(rule) = self.matching_custom_deny_rule(&lowered) {
            return Some(JudgeVerdict::deny_rule(rule));
        }

        // 3b. Built-in sensitive patterns.
        if let Some(rule) = matching_builtin_sensitive_substring(&lowered) {
            return Some(JudgeVerdict::fallback(format!(
                "requires manual approval: {rule}"
            )));
        }
        if let Some(rule) = command_segments(&unquoted).find_map(|segment| {
            let tokens = segment.split_whitespace().collect::<Vec<_>>();
            let stripped = strip_leading_assignments_and_keywords(&tokens);
            denied_segment_rule(stripped)
        }) {
            return Some(JudgeVerdict::fallback(format!(
                "requires manual approval: {rule}"
            )));
        }
        if let Some(path) = matching_credential_path(&lowered) {
            return Some(JudgeVerdict::fallback(format!(
                "requires manual approval for credential path: {path}"
            )));
        }
        if is_network_pipe_to_interpreter(&lowered) {
            return Some(JudgeVerdict::fallback(
                "requires manual approval: downloaded script piped to an interpreter",
            ));
        }

        let cleaned_cmd = strip_null_redirections(command);
        if !has_complex_shell_metacharacters(&cleaned_cmd) {
            let segments = pipeline_and_chain_segments(&cleaned_cmd);
            if !segments.is_empty() {
                let mut all_allowed = true;
                let mut matched_rules = Vec::new();

                for segment in &segments {
                    let trimmed_seg = segment.trim();
                    if trimmed_seg.is_empty() {
                        continue;
                    }
                    let word_strings = tokenize_words(trimmed_seg);
                    let word_slices: Vec<&str> = word_strings.iter().map(String::as_str).collect();
                    let tokens = effective_tokens(&word_slices);
                    if tokens.is_empty() {
                        continue;
                    }
                    if is_shell_syntax_segment(tokens) {
                        continue;
                    }
                    if has_disqualifying_argument(tokens) {
                        all_allowed = false;
                        break;
                    }
                    if let Some(rule) = self.matching_allow_rule(tokens) {
                        matched_rules.push(rule);
                    } else {
                        all_allowed = false;
                        break;
                    }
                }

                if all_allowed && !matched_rules.is_empty() {
                    let summary = if matched_rules.len() == 1 {
                        format!("matched allow rule: {}", matched_rules[0])
                    } else {
                        format!("matched allow rules: {}", matched_rules.join(" && "))
                    };
                    return Some(JudgeVerdict {
                        decision: JudgeDecision::Allow,
                        source: JudgeSource::AllowRule,
                        reason: summary,
                    });
                }
            }
        }

        None
    }

    fn matching_custom_deny_rule(&self, lowered_command: &str) -> Option<&str> {
        self.custom_deny_substrings
            .iter()
            .find(|needle| lowered_command.contains(needle.as_str()))
            .map(String::as_str)
    }

    fn matching_allow_rule(&self, tokens: &[&str]) -> Option<&str> {
        let first = tokens.first()?;
        let prog = program_name(first);
        match prog {
            "git" => {
                if let Some(rule) = self.matching_git_allow_rule(tokens) {
                    return Some(rule);
                }
                return self.matching_token_allow_rule(&self.custom_allow_commands, tokens);
            }
            "gh" => {
                if let Some(rule) = self.matching_gh_allow_rule(tokens) {
                    return Some(rule);
                }
                return self.matching_token_allow_rule(&self.custom_allow_commands, tokens);
            }
            "cargo" => {
                if let Some(rule) = self.matching_cargo_allow_rule(tokens) {
                    return Some(rule);
                }
                return self.matching_token_allow_rule(&self.custom_allow_commands, tokens);
            }
            "flutter" | "dart" => {
                if let Some(rule) = self.matching_flutter_allow_rule(tokens) {
                    return Some(rule);
                }
                return self.matching_token_allow_rule(&self.custom_allow_commands, tokens);
            }
            "npm" | "pnpm" | "yarn" | "bun" => {
                if let Some(rule) = self.matching_js_pm_allow_rule(tokens) {
                    return Some(rule);
                }
                return self.matching_token_allow_rule(&self.custom_allow_commands, tokens);
            }
            _ => {}
        }
        self.matching_token_allow_rule(&self.custom_allow_commands, tokens)
            .or_else(|| self.matching_token_allow_rule(self.builtin_allow_commands, tokens))
    }

    fn matching_token_allow_rule<'a>(
        &'a self,
        rules: &'a [(String, Vec<String>)],
        tokens: &[&str],
    ) -> Option<&'a str> {
        let positional_tokens = extract_positional_tokens(tokens);
        rules
            .iter()
            .find(|(text, rule)| {
                // Wildcard matching (e.g. "./scripts/*", "pytest *", "adb logcat*", "make *")
                if text.ends_with('*') {
                    let prefix = text.trim_end_matches('*');
                    if (prefix.contains('/') || prefix.contains('\\'))
                        && let Some(&first_token) = tokens.first()
                    {
                        let norm_prefix = prefix.replace('\\', "/");
                        let norm_first = first_token.replace('\\', "/");
                        let clean_prefix = norm_prefix.strip_prefix("./").unwrap_or(&norm_prefix);
                        let clean_first = norm_first.strip_prefix("./").unwrap_or(&norm_first);
                        if clean_first.starts_with(clean_prefix) {
                            return true;
                        }
                    }
                    if !rule.is_empty() && rule.len() <= positional_tokens.len() {
                        let matches_prefix = rule.iter().enumerate().all(|(i, expected)| {
                            if i == 0 {
                                expected == positional_tokens[0]
                                    || expected == program_name(positional_tokens[0])
                            } else {
                                expected == positional_tokens[i]
                            }
                        });
                        if matches_prefix {
                            return true;
                        }
                    }
                }

                // 1. Direct token prefix match (allowing full path on first token)
                if rule.len() <= tokens.len()
                    && rule.iter().enumerate().all(|(i, expected)| {
                        if i == 0 {
                            expected == tokens[0] || expected == program_name(tokens[0])
                        } else {
                            expected == tokens[i]
                        }
                    })
                {
                    return true;
                }
                // 2. Positional CLI subcommand match (ignoring intermediate global flags)
                if rule.len() <= positional_tokens.len()
                    && rule.iter().enumerate().all(|(i, expected)| {
                        if i == 0 {
                            expected == positional_tokens[0]
                                || expected == program_name(positional_tokens[0])
                        } else {
                            expected == positional_tokens[i]
                        }
                    })
                {
                    return true;
                }
                false
            })
            .map(|(text, _)| text.as_str())
    }

    fn matching_gh_allow_rule(&self, tokens: &[&str]) -> Option<&str> {
        let first = tokens.first()?;
        if program_name(first) != "gh" {
            return None;
        }
        let positional = extract_positional_tokens(tokens);
        if positional.len() < 2 {
            if tokens
                .iter()
                .any(|t| *t == "--version" || *t == "-v" || *t == "--help" || *t == "-h")
            {
                return Some("gh --version");
            }
            return None;
        }
        let subcommand = positional[1];
        let sub_action = positional.get(2).copied();
        match subcommand {
            "pr" => match sub_action {
                Some("view") => Some("gh pr view"),
                Some("list") => Some("gh pr list"),
                Some("checks") => Some("gh pr checks"),
                Some("diff") => Some("gh pr diff"),
                Some("status") => Some("gh pr status"),
                Some("ready") => Some("gh pr ready"),
                Some("create") => Some("gh pr create"),
                Some("edit") => Some("gh pr edit"),
                Some("comment") => Some("gh pr comment"),
                Some("review") => Some("gh pr review"),
                Some("checkout") => Some("gh pr checkout"),
                _ => None,
            },
            "issue" => match sub_action {
                Some("view") => Some("gh issue view"),
                Some("list") => Some("gh issue list"),
                Some("status") => Some("gh issue status"),
                Some("create") => Some("gh issue create"),
                Some("edit") => Some("gh issue edit"),
                Some("comment") => Some("gh issue comment"),
                _ => None,
            },
            "run" => match sub_action {
                Some("view") => Some("gh run view"),
                Some("list") => Some("gh run list"),
                Some("watch") => Some("gh run watch"),
                _ => None,
            },
            "repo" => match sub_action {
                Some("view") => Some("gh repo view"),
                Some("list") => Some("gh repo list"),
                _ => None,
            },
            "release" => match sub_action {
                Some("view") => Some("gh release view"),
                Some("list") => Some("gh release list"),
                _ => None,
            },
            "workflow" => match sub_action {
                Some("view") => Some("gh workflow view"),
                Some("list") => Some("gh workflow list"),
                _ => None,
            },
            "secret" => match sub_action {
                Some("list") => Some("gh secret list"),
                _ => None,
            },
            "stack" => match sub_action {
                Some("view") => Some("gh stack view"),
                _ => None,
            },
            "status" => Some("gh status"),
            "search" => Some("gh search"),
            "browse" => Some("gh browse"),
            "api" => {
                let sub_args = &tokens[1..];
                // Disallow `gh api graphql` since GraphQL requests default to HTTP POST mutations
                if positional
                    .get(2..)
                    .map(|eps| {
                        eps.iter()
                            .any(|arg| arg.to_ascii_lowercase().contains("graphql"))
                    })
                    .unwrap_or(false)
                {
                    return None;
                }
                const GH_MUTATING_FLAGS: &[&str] = &[
                    "-x",
                    "--method",
                    "-f",
                    "--field",
                    "-F",
                    "--raw-field",
                    "--input",
                    "-p",
                    "--preview",
                ];
                if sub_args.iter().any(|arg| {
                    let lower = arg.to_ascii_lowercase();
                    GH_MUTATING_FLAGS.iter().any(|flag| {
                        lower == *flag
                            || lower.starts_with(&format!("{flag}="))
                            || (flag.starts_with('-')
                                && !flag.starts_with("--")
                                && !lower.starts_with("--")
                                && lower.starts_with(flag))
                    })
                }) {
                    None
                } else {
                    Some("gh api")
                }
            }
            "auth" => {
                if sub_action == Some("status") {
                    Some("gh auth status")
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn matching_git_allow_rule(&self, tokens: &[&str]) -> Option<&str> {
        let first = tokens.first()?;
        if program_name(first) != "git" {
            return None;
        }
        let (subcommand, sub_args) = parse_git_subcommand(&tokens[1..])?;
        let sub_positionals = extract_positional_tokens(sub_args);

        match subcommand {
            "diff" => Some("git diff"),
            "status" => Some("git status"),
            "log" => Some("git log"),
            "show" => Some("git show"),
            "add" => Some("git add"),
            "commit" => Some("git commit"),
            "checkout" => Some("git checkout"),
            "switch" => Some("git switch"),
            "restore" => Some("git restore"),
            "rev-parse" => Some("git rev-parse"),
            "rev-list" => Some("git rev-list"),
            "merge-base" => Some("git merge-base"),
            "describe" => Some("git describe"),
            "check-ignore" => Some("git check-ignore"),
            "blame" => Some("git blame"),
            "ls-files" => Some("git ls-files"),
            "fetch" => {
                if sub_args
                    .iter()
                    .any(|&arg| is_dangerous_git_network_arg(arg))
                {
                    None
                } else {
                    Some("git fetch")
                }
            }
            "pull" => {
                if sub_args
                    .iter()
                    .any(|&arg| is_dangerous_git_network_arg(arg))
                {
                    None
                } else {
                    Some("git pull")
                }
            }
            "worktree" if sub_positionals.first() == Some(&"list") => Some("git worktree list"),
            "worktree" if sub_positionals.first() == Some(&"add") => Some("git worktree add"),
            "stash" => Some("git stash"),
            "rebase"
                if sub_args.contains(&"--continue")
                    || sub_args.contains(&"--abort")
                    || sub_args.contains(&"--skip")
                    || sub_args.contains(&"--quit")
                    || sub_args.contains(&"--show-current-patch") =>
            {
                Some("git rebase")
            }
            "cherry-pick"
                if sub_args.contains(&"--continue")
                    || sub_args.contains(&"--abort")
                    || sub_args.contains(&"--skip")
                    || sub_args.contains(&"--quit") =>
            {
                Some("git cherry-pick")
            }
            "merge"
                if sub_args.contains(&"--continue")
                    || sub_args.contains(&"--abort")
                    || sub_args.contains(&"--quit") =>
            {
                Some("git merge")
            }
            "tag" => {
                const GIT_TAG_MUTATING_FLAGS: &[&str] = &[
                    "-d",
                    "-D",
                    "--delete",
                    "-a",
                    "--annotate",
                    "-s",
                    "--sign",
                    "-u",
                    "--local-user",
                    "-f",
                    "--force",
                    "-m",
                    "--message",
                    "-F",
                    "--file",
                ];
                const GIT_TAG_READ_ONLY_FLAGS: &[&str] = &[
                    "-l",
                    "--list",
                    "-n",
                    "--sort",
                    "--points-at",
                    "--merged",
                    "--no-merged",
                    "--contains",
                    "--no-contains",
                    "--column",
                    "--no-column",
                    "--color",
                    "--no-color",
                ];
                let has_mutating_flag = sub_args.iter().any(|arg| {
                    GIT_TAG_MUTATING_FLAGS.contains(arg)
                        || arg.starts_with("-d")
                        || arg.starts_with("-D")
                        || arg.starts_with("-f")
                        || arg.starts_with("-a")
                        || arg.starts_with("-s")
                        || arg.starts_with("-u")
                        || arg.starts_with("-m")
                        || arg.starts_with("--message=")
                        || arg.starts_with("-F")
                        || arg.starts_with("--file=")
                });
                if has_mutating_flag {
                    None
                } else if sub_args.is_empty()
                    || (sub_args.iter().all(|a| {
                        !a.starts_with('-')
                            || GIT_TAG_READ_ONLY_FLAGS.contains(a)
                            || a.starts_with("--sort=")
                            || a.starts_with("--points-at=")
                            || a.starts_with("--merged=")
                            || a.starts_with("--no-merged=")
                            || a.starts_with("--contains=")
                            || a.starts_with("--no-contains=")
                            || a.contains('*')
                    }) && (sub_args.contains(&"--list")
                        || sub_args.contains(&"-l")
                        || sub_args.contains(&"--contains")
                        || sub_args.contains(&"--no-contains")
                        || sub_args.contains(&"--merged")
                        || sub_args.contains(&"--no-merged")
                        || sub_args.contains(&"--points-at")
                        || sub_args.iter().any(|a| {
                            a.contains('*')
                                || a.starts_with("--contains=")
                                || a.starts_with("--no-contains=")
                                || a.starts_with("--merged=")
                                || a.starts_with("--no-merged=")
                                || a.starts_with("--points-at=")
                        })))
                {
                    Some("git tag")
                } else {
                    None
                }
            }
            "branch" => {
                const GIT_BRANCH_MUTATING_FLAGS: &[&str] = &[
                    "-d",
                    "-D",
                    "--delete",
                    "-m",
                    "-M",
                    "--move",
                    "-c",
                    "-C",
                    "--copy",
                    "-u",
                    "--set-upstream-to",
                    "--unset-upstream",
                    "--edit-description",
                ];
                let has_mutating_flag = sub_args.iter().any(|arg| {
                    GIT_BRANCH_MUTATING_FLAGS.contains(arg)
                        || arg.starts_with("-d")
                        || arg.starts_with("-D")
                        || arg.starts_with("-m")
                        || arg.starts_with("-M")
                        || arg.starts_with("-c")
                        || arg.starts_with("-C")
                        || arg.starts_with("--set-upstream-to=")
                        || (arg.starts_with("-u") && *arg != "-u")
                });
                const GIT_BRANCH_READ_ONLY_FLAGS: &[&str] = &[
                    "-r",
                    "--remotes",
                    "-a",
                    "--all",
                    "-v",
                    "-vv",
                    "--verbose",
                    "--show-current",
                    "--list",
                    "-l",
                    "--merged",
                    "--no-merged",
                    "--contains",
                    "--no-contains",
                    "--points-at",
                    "--sort",
                    "--column",
                    "--no-column",
                    "--color",
                    "--no-color",
                ];
                if has_mutating_flag {
                    None
                } else if sub_args.is_empty()
                    || sub_args.contains(&"--show-current")
                    || (sub_args.iter().all(|a| {
                        !a.starts_with('-')
                            || GIT_BRANCH_READ_ONLY_FLAGS.contains(a)
                            || a.starts_with("--sort=")
                            || a.starts_with("--points-at=")
                            || a.starts_with("--merged=")
                            || a.starts_with("--no-merged=")
                            || a.starts_with("--contains=")
                            || a.starts_with("--no-contains=")
                            || a.contains('*')
                    }) && (sub_args.contains(&"-r")
                        || sub_args.contains(&"--remotes")
                        || sub_args.contains(&"-a")
                        || sub_args.contains(&"--all")
                        || sub_args.contains(&"-v")
                        || sub_args.contains(&"-vv")
                        || sub_args.contains(&"--verbose")
                        || sub_args.contains(&"--list")
                        || sub_args.contains(&"-l")
                        || sub_args.contains(&"--contains")
                        || sub_args.contains(&"--no-contains")
                        || sub_args.contains(&"--merged")
                        || sub_args.contains(&"--no-merged")
                        || sub_args.contains(&"--points-at")
                        || sub_args.iter().any(|a| {
                            a.starts_with("--contains=")
                                || a.starts_with("--no-contains=")
                                || a.starts_with("--merged=")
                                || a.starts_with("--no-merged=")
                                || a.starts_with("--points-at=")
                        })))
                {
                    Some("git branch")
                } else {
                    None
                }
            }
            "remote"
                if (sub_args.contains(&"-v")
                    || sub_args.contains(&"--verbose")
                    || sub_args.is_empty())
                    && sub_args.iter().all(|a| a.starts_with('-')) =>
            {
                Some("git remote -v")
            }
            "push" => {
                const GIT_PUSH_DANGEROUS_FLAGS: &[&str] = &[
                    "-f",
                    "--force",
                    "--force-with-lease",
                    "--force-if-includes",
                    "-d",
                    "--delete",
                    "--mirror",
                    "--prune",
                    "--receive-pack",
                    "--exec",
                ];
                let is_dangerous = sub_args.iter().any(|arg| {
                    GIT_PUSH_DANGEROUS_FLAGS.contains(arg)
                        || arg.starts_with("-f")
                        || arg.starts_with("--force")
                        || arg.starts_with("--receive-pack")
                        || arg.starts_with("--exec")
                        || arg.starts_with('+')
                        || arg.starts_with(':')
                });
                if is_dangerous { None } else { Some("git push") }
            }
            _ => None,
        }
    }

    fn matching_cargo_allow_rule(&self, tokens: &[&str]) -> Option<&str> {
        let first = tokens.first()?;
        if program_name(first) != "cargo" {
            return None;
        }
        let positional = extract_positional_tokens(tokens);
        if positional.len() < 2 {
            if tokens.iter().any(|t| {
                *t == "--version"
                    || *t == "-V"
                    || *t == "--help"
                    || *t == "-h"
                    || *t == "version"
                    || *t == "help"
            }) {
                return Some("cargo --version");
            }
            return None;
        }
        let subcommand = positional[1];
        match subcommand {
            "check" => Some("cargo check"),
            "build" => Some("cargo build"),
            "test" => Some("cargo test"),
            "clippy" => Some("cargo clippy"),
            "fmt" => Some("cargo fmt"),
            "doc" => Some("cargo doc"),
            "tree" => Some("cargo tree"),
            "metadata" => Some("cargo metadata"),
            "install" => Some("cargo install"),
            "init" => Some("cargo init"),
            "new" => Some("cargo new"),
            "clean" => Some("cargo clean"),
            "bench" => Some("cargo bench"),
            "locate-project" => Some("cargo locate-project"),
            "verify-project" => Some("cargo verify-project"),
            "report" => Some("cargo report"),
            "help" => Some("cargo help"),
            _ => None,
        }
    }

    fn matching_flutter_allow_rule(&self, tokens: &[&str]) -> Option<&str> {
        let first = tokens.first()?;
        let prog = program_name(first);
        if prog != "flutter" && prog != "dart" {
            return None;
        }
        let positional = extract_positional_tokens(tokens);
        if positional.len() < 2 {
            if tokens
                .iter()
                .any(|t| *t == "--version" || *t == "-v" || *t == "--help" || *t == "-h")
            {
                return Some("flutter --version");
            }
            return None;
        }
        let subcommand = positional[1];
        if prog == "flutter" {
            match subcommand {
                "test" => Some("flutter test"),
                "analyze" => Some("flutter analyze"),
                "doctor" => Some("flutter doctor"),
                "build" => Some("flutter build"),
                "devices" => Some("flutter devices"),
                "emulators" => Some("flutter emulators"),
                "logs" => Some("flutter logs"),
                "format" => Some("flutter format"),
                "clean" => Some("flutter clean"),
                "gen-l10n" => Some("flutter gen-l10n"),
                "pub" => {
                    if let Some(&action) = positional.get(2) {
                        match action {
                            "get" => Some("flutter pub get"),
                            "deps" | "outdated" | "upgrade" | "downgrade" | "cache" | "test" => {
                                Some("flutter pub")
                            }
                            _ => None,
                        }
                    } else {
                        Some("flutter pub")
                    }
                }
                _ => None,
            }
        } else {
            // dart
            match subcommand {
                "analyze" => Some("dart analyze"),
                "test" => Some("dart test"),
                "format" => Some("dart format"),
                "doctor" => Some("dart doctor"),
                "run" => Some("dart run"),
                "compile" => Some("dart compile"),
                "pub" => {
                    if let Some(&action) = positional.get(2) {
                        match action {
                            "get" => Some("dart pub get"),
                            "deps" | "outdated" | "upgrade" | "downgrade" | "cache" | "test" => {
                                Some("dart pub")
                            }
                            _ => None,
                        }
                    } else {
                        Some("dart pub")
                    }
                }
                _ => None,
            }
        }
    }

    fn matching_js_pm_allow_rule(&self, tokens: &[&str]) -> Option<&str> {
        let first = tokens.first()?;
        let prog = program_name(first);
        if !matches!(prog, "pnpm" | "npm" | "yarn" | "bun") {
            return None;
        }
        let positional = extract_positional_tokens(tokens);
        if positional.len() < 2 {
            if tokens
                .iter()
                .any(|t| *t == "--version" || *t == "-v" || *t == "--help" || *t == "-h")
            {
                return Some(match prog {
                    "pnpm" => "pnpm --version",
                    "yarn" => "yarn --version",
                    "bun" => "bun --version",
                    _ => "npm --version",
                });
            }
            return None;
        }
        let subcommand = positional[1];
        match subcommand {
            "test" | "t" => Some(match prog {
                "pnpm" => "pnpm test",
                "yarn" => "yarn test",
                "bun" => "bun test",
                _ => "npm test",
            }),
            "run" => Some(match prog {
                "pnpm" => "pnpm run",
                "yarn" => "yarn run",
                "bun" => "bun run",
                _ => "npm run",
            }),
            "build" => Some(match prog {
                "pnpm" => "pnpm build",
                "yarn" => "yarn build",
                "bun" => "bun build",
                _ => "npm build",
            }),
            "check" | "lint" | "format" | "typecheck" | "tsc" | "ci" | "list" | "ls" | "audit"
            | "outdated" | "why" | "info" => Some(match prog {
                "pnpm" => "pnpm check",
                "yarn" => "yarn check",
                "bun" => "bun check",
                _ => "npm ci",
            }),
            _ => None,
        }
    }
}

pub fn builtin_allow_commands() -> Vec<String> {
    static BUILTIN_ALLOW: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    BUILTIN_ALLOW
        .get_or_init(|| {
            BUILTIN_ALLOW_COMMANDS
                .iter()
                .map(|s| (*s).to_string())
                .collect()
        })
        .clone()
}

pub fn builtin_deny_substrings() -> Vec<String> {
    static BUILTIN_DENY: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    BUILTIN_DENY
        .get_or_init(|| {
            BUILTIN_SENSITIVE_SUBSTRINGS
                .iter()
                .map(|s| (*s).to_string())
                .collect()
        })
        .clone()
}

pub fn persist_judge_config(config: &crate::config::JudgeConfig) -> anyhow::Result<()> {
    let target_path = crate::config::Config::default_path()?;
    if let Some(parent) = target_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let path = std::fs::canonicalize(&target_path).unwrap_or(target_path);
    let mut table: toml::Table = if path.exists() {
        let content = std::fs::read_to_string(&path)?;
        toml::from_str(&content)
            .map_err(|err| anyhow::anyhow!("failed to parse existing {}: {err}", path.display()))?
    } else {
        toml::Table::new()
    };

    let mut judge_table = table
        .get("judge")
        .and_then(|v| v.as_table())
        .cloned()
        .unwrap_or_default();
    judge_table.insert("enabled".into(), toml::Value::Boolean(config.enabled));
    judge_table.insert(
        "default_enabled_per_session".into(),
        toml::Value::Boolean(config.default_enabled_per_session),
    );
    judge_table.insert(
        "timeout_ms".into(),
        toml::Value::Integer(config.timeout_ms as i64),
    );

    let allow_arr = config
        .allow_commands
        .iter()
        .map(|s| toml::Value::String(s.clone()))
        .collect();
    judge_table.insert("allow_commands".into(), toml::Value::Array(allow_arr));

    let deny_arr = config
        .deny_substrings
        .iter()
        .map(|s| toml::Value::String(s.clone()))
        .collect();
    judge_table.insert("deny_substrings".into(), toml::Value::Array(deny_arr));

    table.insert("judge".into(), toml::Value::Table(judge_table));
    let toml_str = toml::to_string_pretty(&table)?;
    let tmp_path = path.with_extension(format!(
        "tmp.{}.{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    use std::io::Write as _;
    let mut file = std::fs::File::create(&tmp_path)?;
    file.write_all(toml_str.as_bytes())?;
    file.sync_all()?;
    drop(file);
    if let Err(err) = std::fs::rename(&tmp_path, &path) {
        if std::fs::copy(&tmp_path, &path).is_ok() {
            let _ = std::fs::remove_file(&tmp_path);
        } else {
            let _ = std::fs::remove_file(&tmp_path);
            return Err(err.into());
        }
    }
    Ok(())
}

pub fn normalize_lowered(command: &str) -> String {
    let mut result = String::with_capacity(command.len());
    let mut first = true;
    for word in command.split_whitespace() {
        if !first {
            result.push(' ');
        }
        first = false;
        for c in word.chars().flat_map(char::to_lowercase) {
            result.push(c);
        }
    }
    result
}

pub fn check_target_credential_path(request: &JudgeRequest) -> Option<String> {
    if let Some(target_path) = request.path.as_deref().or(request.command_line.as_deref()) {
        let unquoted = unquote_segment(target_path);
        let lowered_path = normalize_lowered(&unquoted);
        if let Some(matched) = matching_credential_path(&lowered_path) {
            return Some(matched.to_string());
        }
        let mut normalized = lowered_path.replace('\\', "/");
        if normalized.starts_with("//?/") || normalized.starts_with("//./") {
            normalized = normalized[4..].to_string();
        }
        if normalized.len() >= 2
            && normalized.as_bytes()[1] == b':'
            && normalized.as_bytes()[0].is_ascii_alphabetic()
        {
            normalized = normalized[2..].to_string();
        }
        let mut stack: Vec<&str> = Vec::with_capacity(8);
        for comp in std::path::Path::new(&normalized).components() {
            match comp {
                std::path::Component::ParentDir => {
                    stack.pop();
                }
                std::path::Component::Normal(c) => {
                    if let Some(s) = c.to_str() {
                        stack.push(s);
                    }
                }
                _ => {}
            }
        }
        let clean_str = stack.join("/");
        if let Some(matched) = matching_credential_path(&clean_str) {
            return Some(matched.to_string());
        }
        if !clean_str.is_empty() {
            let root_prefixed = format!("/{clean_str}");
            if let Some(matched) = matching_credential_path(&root_prefixed) {
                return Some(matched.to_string());
            }
        }
    }
    None
}

pub fn strip_null_redirections(command: &str) -> std::borrow::Cow<'_, str> {
    if !command.contains('>') && !command.contains("2>&1") && !command.contains("nul") {
        return std::borrow::Cow::Borrowed(command);
    }

    let patterns = [
        "2>/dev/null",
        "1>/dev/null",
        ">/dev/null",
        "&>/dev/null",
        "2> /dev/null",
        "1> /dev/null",
        "> /dev/null",
        "&> /dev/null",
        "2>&1",
        ">nul",
        "> nul",
        "2>nul",
        "2> nul",
    ];

    let mut in_single = false;
    let mut in_double = false;
    let mut escaped = false;
    let mut result = String::with_capacity(command.len());
    let mut rest = command;

    'outer: while !rest.is_empty() {
        let first_byte = rest.as_bytes()[0];
        if escaped {
            escaped = false;
            let ch = rest.chars().next().unwrap();
            result.push(ch);
            rest = &rest[ch.len_utf8()..];
            continue;
        }
        if first_byte == b'\\' && !in_single {
            escaped = true;
            result.push('\\');
            rest = &rest[1..];
            continue;
        }
        if first_byte == b'\'' && !in_double {
            in_single = !in_single;
            result.push('\'');
            rest = &rest[1..];
            continue;
        }
        if first_byte == b'"' && !in_single {
            in_double = !in_double;
            result.push('"');
            rest = &rest[1..];
            continue;
        }

        if !in_single && !in_double {
            for pattern in &patterns {
                if let Some(after) = rest.strip_prefix(pattern) {
                    let is_bounded = after.is_empty()
                        || after.starts_with(|c: char| {
                            c.is_whitespace() || c == ';' || c == '&' || c == '|' || c == '\n'
                        });
                    if is_bounded {
                        result.push(' ');
                        rest = after;
                        continue 'outer;
                    }
                }
            }
        }
        let ch = rest.chars().next().unwrap();
        result.push(ch);
        rest = &rest[ch.len_utf8()..];
    }

    std::borrow::Cow::Owned(result)
}

pub fn has_complex_shell_metacharacters(command: &str) -> bool {
    if command.contains('`')
        || command.contains("$(")
        || command.contains("<(")
        || command.contains(">(")
    {
        return true;
    }
    let mut in_single = false;
    let mut in_double = false;
    let mut escaped = false;
    let bytes = command.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if escaped {
            escaped = false;
            i += 1;
            continue;
        }
        if b == b'\\' && !in_single {
            escaped = true;
            i += 1;
            continue;
        }
        if b == b'\'' && !in_double {
            in_single = !in_single;
            i += 1;
            continue;
        }
        if b == b'"' && !in_single {
            in_double = !in_double;
            i += 1;
            continue;
        }
        i += 1;
    }
    in_single || in_double || escaped
}

pub fn is_shell_syntax_segment(tokens: &[&str]) -> bool {
    if tokens.is_empty() {
        return true;
    }
    match tokens[0] {
        "do" | "done" | "then" | "else" | "elif" | "fi" | "{" | "}" | "(" | ")" => {
            tokens.len() == 1
        }
        "for" => {
            tokens.len() >= 3 && tokens[2] == "in"
                || tokens.len() >= 2 && (tokens[1] == "in" || tokens[1].starts_with("(("))
        }
        _ => false,
    }
}

pub fn command_segments(command: &str) -> impl Iterator<Item = &str> {
    command
        .split(|character: char| {
            matches!(
                character,
                ';' | '|' | '&' | '\n' | '\r' | '`' | '(' | ')' | '{' | '}'
            )
        })
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
}

pub fn pipeline_and_chain_segments(command: &str) -> Vec<&str> {
    let mut segments = Vec::with_capacity(4);
    let mut start = 0;
    let mut in_single_quote = false;
    let mut in_double_quote = false;
    let mut escaped = false;
    let mut heredoc_delimiter: Option<String> = None;
    let mut in_heredoc_body = false;

    let bytes = command.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if escaped {
            escaped = false;
            i += 1;
            continue;
        }
        if b == b'\\' && !in_single_quote {
            escaped = true;
            i += 1;
            continue;
        }
        if b == b'\'' && !in_double_quote {
            in_single_quote = !in_single_quote;
            i += 1;
            continue;
        }
        if b == b'"' && !in_single_quote {
            in_double_quote = !in_double_quote;
            i += 1;
            continue;
        }

        if !in_single_quote && !in_double_quote {
            // Check for heredoc start `<<` outside of heredoc body
            if !in_heredoc_body
                && heredoc_delimiter.is_none()
                && b == b'<'
                && i + 1 < bytes.len()
                && bytes[i + 1] == b'<'
                && (i + 2 >= bytes.len() || bytes[i + 2] != b'<')
            {
                let mut d_start = i + 2;
                if d_start < bytes.len() && bytes[d_start] == b'-' {
                    d_start += 1;
                }
                while d_start < bytes.len() && (bytes[d_start] == b' ' || bytes[d_start] == b'\t') {
                    d_start += 1;
                }
                let mut d_end = d_start;
                if d_start < bytes.len() {
                    let first_char = bytes[d_start];
                    if first_char == b'\'' || first_char == b'"' {
                        d_start += 1;
                        d_end = d_start;
                        while d_end < bytes.len() && bytes[d_end] != first_char {
                            d_end += 1;
                        }
                        if d_end < bytes.len() {
                            let delim = &command[d_start..d_end];
                            if !delim.is_empty() {
                                heredoc_delimiter = Some(delim.to_string());
                            }
                            i = d_end + 1;
                            continue;
                        }
                    } else {
                        while d_end < bytes.len()
                            && (bytes[d_end].is_ascii_alphanumeric() || bytes[d_end] == b'_')
                        {
                            d_end += 1;
                        }
                        if d_end > d_start {
                            let delim = &command[d_start..d_end];
                            heredoc_delimiter = Some(delim.to_string());
                            i = d_end;
                            continue;
                        }
                    }
                }
            }

            // Check if upcoming line ends the heredoc
            if let Some(ref delim) = heredoc_delimiter
                && (b == b'\n' || b == b'\r')
            {
                in_heredoc_body = true;
                let next_line_start = if b == b'\r' && i + 1 < bytes.len() && bytes[i + 1] == b'\n'
                {
                    i + 2
                } else {
                    i + 1
                };
                let line_rest = &command[next_line_start..];
                let line_end = line_rest.find(['\n', '\r']).unwrap_or(line_rest.len());
                let line = line_rest[..line_end].trim();
                if line == delim.as_str() {
                    heredoc_delimiter = None;
                    in_heredoc_body = false;
                    i = next_line_start + line_end;
                    continue;
                }
                i += 1;
                continue;
            }

            if !in_heredoc_body
                && matches!(
                    b,
                    b';' | b'|' | b'&' | b'\n' | b'\r' | b'(' | b')' | b'{' | b'}'
                )
            {
                let segment = command[start..i].trim();
                if !segment.is_empty() {
                    segments.push(segment);
                }
                start = i + 1;
            }
        }

        i += 1;
    }
    let tail = command[start..].trim();
    if !tail.is_empty() {
        segments.push(tail);
    }
    segments
}

pub fn tokenize_words(segment: &str) -> Vec<String> {
    if let Some(words) = shlex::split(segment)
        && !words.is_empty()
    {
        return words;
    }
    fallback_tokenize_words(segment)
}

fn fallback_tokenize_words(segment: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut in_single = false;
    let mut in_double = false;
    let mut escaped = false;

    for ch in segment.chars() {
        if escaped {
            current.push(ch);
            escaped = false;
            continue;
        }
        if ch == '\\' && !in_single {
            escaped = true;
            continue;
        }
        if ch == '\'' && !in_double {
            in_single = !in_single;
            continue;
        }
        if ch == '"' && !in_single {
            in_double = !in_double;
            continue;
        }
        if ch.is_whitespace() && !in_single && !in_double {
            if !current.is_empty() {
                words.push(std::mem::take(&mut current));
            }
        } else {
            current.push(ch);
        }
    }
    if !current.is_empty() {
        words.push(current);
    }
    words
}

pub fn is_recursive_force_remove(tokens: &[&str]) -> bool {
    let removes = names_program(tokens, "rm");
    if !removes {
        return false;
    }
    let has = |long: &str, shorts: &[char]| {
        tokens
            .iter()
            .filter(|token| token.starts_with('-'))
            .any(|flag| {
                if let Some(name) = flag.strip_prefix("--") {
                    name == long
                } else {
                    flag.strip_prefix('-')
                        .is_some_and(|bundle| bundle.chars().any(|c| shorts.contains(&c)))
                }
            })
    };
    has("recursive", &['r', 'R']) && has("force", &['f'])
}

pub const WRAPPER_PROGRAMS: &[&str] = &[
    "env", "nice", "nohup", "timeout", "time", "command", "builtin", "stdbuf", "ionice", "xargs",
    "sudo", "doas", "sh", "bash", "zsh", "fish", "dash", "ksh",
];

pub fn strip_leading_assignments_and_keywords<'a>(tokens: &'a [&'a str]) -> &'a [&'a str] {
    let mut rest = tokens;
    while let Some((first, tail)) = rest.split_first() {
        if matches!(
            first,
            &"do" | &"then" | &"else" | &"elif" | &"&&" | &"||" | &";" | &"|" | &"&"
        ) && !tail.is_empty()
        {
            rest = tail;
            continue;
        }
        if first.contains('=') && !first.starts_with('-') {
            rest = tail;
            continue;
        }
        break;
    }
    rest
}

pub fn effective_program<'a>(tokens: &'a [&'a str]) -> Option<&'a str> {
    let mut rest = strip_leading_assignments_and_keywords(tokens);
    loop {
        let (first, tail) = rest.split_first()?;
        let program = program_name(first);
        if !WRAPPER_PROGRAMS.contains(&program) {
            return Some(program);
        }
        rest = tail;
        while let Some((next, remainder)) = rest.split_first() {
            let takes_arg = matches!(
                *next,
                "-u" | "--unset" | "-C" | "--chdir" | "-s" | "--signal"
            );
            let is_wrapper_argument =
                next.starts_with('-') || next.contains('=') || is_duration_or_numeric(next);
            if takes_arg {
                rest = remainder.get(1..).unwrap_or(&[]);
                continue;
            }
            if !is_wrapper_argument {
                break;
            }
            rest = remainder;
        }
    }
}

pub fn is_duration_or_numeric(token: &str) -> bool {
    if token.is_empty() {
        return false;
    }
    let trimmed = token
        .strip_suffix(|c| matches!(c, 's' | 'm' | 'h' | 'd'))
        .unwrap_or(token);
    !trimmed.is_empty() && trimmed.chars().all(|c| c.is_ascii_digit() || c == '.')
}

pub fn effective_tokens<'a>(tokens: &'a [&'a str]) -> &'a [&'a str] {
    let mut rest = strip_leading_assignments_and_keywords(tokens);
    while let Some((first, tail)) = rest.split_first() {
        let prog = program_name(first);
        if WRAPPER_PROGRAMS.contains(&prog)
            && !matches!(
                prog,
                "sudo" | "doas" | "sh" | "bash" | "zsh" | "fish" | "dash" | "ksh"
            )
        {
            rest = tail;
            while let Some((next, remainder)) = rest.split_first() {
                let takes_arg = matches!(
                    *next,
                    "-u" | "--unset" | "-C" | "--chdir" | "-s" | "--signal"
                );
                let is_wrapper_arg =
                    next.starts_with('-') || next.contains('=') || is_duration_or_numeric(next);
                if takes_arg {
                    rest = remainder.get(1..).unwrap_or(&[]);
                    continue;
                }
                if !is_wrapper_arg {
                    break;
                }
                rest = remainder;
            }
            continue;
        }
        break;
    }
    rest
}

pub fn names_program(tokens: &[&str], program: &str) -> bool {
    if effective_program(tokens) == Some(program) {
        return true;
    }
    let leads_with_wrapper = tokens
        .first()
        .is_some_and(|token| WRAPPER_PROGRAMS.contains(&program_name(token)));
    leads_with_wrapper
        && tokens
            .iter()
            .filter(|token| !token.starts_with('-'))
            .any(|token| program_name(token) == program)
}

pub fn denied_segment_rule(tokens: &[&str]) -> Option<&'static str> {
    if is_recursive_force_remove(tokens) {
        return Some("recursive forced delete");
    }
    let effective = effective_program(tokens);
    let leads_with_wrapper = tokens
        .first()
        .is_some_and(|token| WRAPPER_PROGRAMS.contains(&program_name(token)));

    if let Some(destructive) = effective.and_then(|prog| {
        DESTRUCTIVE_PROGRAMS
            .iter()
            .copied()
            .find(|&candidate| candidate == prog)
    }) {
        return Some(destructive);
    }
    if leads_with_wrapper {
        for token in tokens.iter().filter(|t| !t.starts_with('-')) {
            let prog = program_name(token);
            if let Some(&destructive) = DESTRUCTIVE_PROGRAMS.iter().find(|&&c| c == prog) {
                return Some(destructive);
            }
        }
    }
    git_denied_operation(tokens)
}

pub fn extract_positional_tokens<'a>(tokens: &'a [&'a str]) -> Vec<&'a str> {
    let mut positionals = Vec::new();
    let mut i = 0;
    let prog = tokens.first().map(|&t| program_name(t)).unwrap_or("");

    while i < tokens.len() {
        let token = tokens[i];
        if token == "--" {
            for &rest in &tokens[i + 1..] {
                positionals.push(rest);
            }
            break;
        }
        if token != "-" && token.starts_with('-') {
            if (token.starts_with("-C") && token != "-C")
                || (token.starts_with("-c") && token != "-c")
                || (token.starts_with("-R") && token != "-R")
                || (token.starts_with("-H") && token != "-H")
                || (token.starts_with("-f") && token != "-f")
                || (token.starts_with("-F") && token != "-F")
                || (token.starts_with("-t") && token != "-t")
                || (token.starts_with("-s") && token != "-s")
                || (token.starts_with("-Z") && token != "-Z")
                || (token.starts_with("-p") && token != "-p" && prog == "cargo")
                || (token.starts_with("-d") && token != "-d" && prog == "flutter")
                || token.contains('=')
            {
                i += 1;
                continue;
            }

            let is_value_taking = match prog {
                "cargo" => matches!(
                    token,
                    "-p" | "--package"
                        | "--manifest-path"
                        | "--target-dir"
                        | "--bin"
                        | "--example"
                        | "--test"
                        | "--bench"
                        | "--profile"
                        | "--target"
                        | "-Z"
                ),
                "flutter" | "dart" => {
                    matches!(token, "-d" | "--device-id" | "-t" | "--target")
                }
                "adb" | "fastboot" => {
                    matches!(token, "-s" | "--serial" | "-t" | "--device")
                }
                "gh" => matches!(
                    token,
                    "-R" | "--repo"
                        | "--hostname"
                        | "-H"
                        | "--header"
                        | "-X"
                        | "--method"
                        | "-f"
                        | "--field"
                        | "-F"
                        | "--raw-field"
                        | "--input"
                        | "--preview"
                        | "-q"
                        | "--jq"
                        | "-t"
                        | "--template"
                ),
                "pnpm" | "npm" | "yarn" | "bun" => {
                    matches!(token, "--dir" | "--prefix" | "--filter")
                }
                _ => GIT_VALUE_TAKING_GLOBALS.contains(&token),
            };

            if is_value_taking {
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        positionals.push(token);
        i += 1;
    }

    positionals
}

pub const GIT_VALUE_TAKING_GLOBALS: &[&str] = &[
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--exec-path",
    "--config-env",
];

pub fn parse_git_subcommand<'a>(after: &'a [&'a str]) -> Option<(&'a str, &'a [&'a str])> {
    let mut index = 0;
    while let Some(token) = after.get(index) {
        if !token.starts_with('-') {
            break;
        }
        let is_attached = (token.starts_with("-C") && *token != "-C")
            || (token.starts_with("-c") && *token != "-c")
            || token.starts_with("--git-dir=")
            || token.starts_with("--work-tree=")
            || token.starts_with("--namespace=")
            || token.starts_with("--exec-path=")
            || token.starts_with("--config-env=");
        index += if is_attached {
            1
        } else if GIT_VALUE_TAKING_GLOBALS.contains(token) {
            2
        } else {
            1
        };
    }
    let subcommand = *after.get(index)?;
    let sub_args = &after[index + 1..];
    Some((subcommand, sub_args))
}

pub fn git_denied_operation(tokens: &[&str]) -> Option<&'static str> {
    if !names_program(tokens, "git") {
        return None;
    }
    let git_index = tokens
        .iter()
        .position(|token| program_name(token) == "git")?;
    let (subcommand, sub_args) = parse_git_subcommand(&tokens[git_index + 1..])?;

    let has = |long: &[&str], short: &[char]| {
        sub_args
            .iter()
            .filter(|token| token.starts_with('-'))
            .any(|flag| long.contains(flag) || is_short_flag_bundle_containing(flag, short))
    };

    match subcommand {
        "push"
            if has(
                &[
                    "--force",
                    "--force-with-lease",
                    "--force-if-includes",
                    "--delete",
                    "--mirror",
                    "--prune",
                    "--receive-pack",
                    "--exec",
                ],
                &['f', 'd'],
            ) || sub_args.iter().any(|arg| {
                arg.starts_with('+')
                    || arg.starts_with(':')
                    || arg.starts_with("--force")
                    || arg.starts_with("--receive-pack")
                    || arg.starts_with("--exec")
            }) =>
        {
            Some("destructive git push operation")
        }
        "filter-branch" => Some("git filter-branch"),
        "reset" if has(&["--hard"], &[]) => Some("git reset --hard"),
        "clean" if has(&["--force"], &['f']) => Some("git clean --force"),
        "branch"
            if has(
                &["--delete", "--force", "--move"],
                &['d', 'D', 'f', 'm', 'M'],
            ) =>
        {
            Some("destructive git branch operation")
        }
        "stash" if sub_args.iter().any(|&arg| arg == "drop" || arg == "clear") => {
            Some("destructive git stash operation")
        }
        _ => None,
    }
}

pub fn matching_credential_path(cleaned: &str) -> Option<&'static str> {
    const TEMPLATE_SUFFIXES: &[&str] = &["example", "sample", "template", "dist", "defaults"];

    let normalized: std::borrow::Cow<'_, str> = if cleaned.contains('\\') {
        std::borrow::Cow::Owned(cleaned.replace('\\', "/"))
    } else {
        std::borrow::Cow::Borrowed(cleaned)
    };

    CREDENTIAL_PATHS.iter().copied().find(|path| {
        normalized.match_indices(path).any(|(index, matched)| {
            let opens = match normalized[..index].chars().next_back() {
                None => true,
                Some(previous) => {
                    previous == '/'
                        || previous == '='
                        || previous == ':'
                        || previous == '<'
                        || previous == '>'
                        || previous == '|'
                        || previous == '&'
                        || previous == ';'
                        || previous.is_whitespace()
                }
            };
            if !opens {
                return false;
            }
            let rest = &normalized[index + matched.len()..];
            match rest.chars().next() {
                None => true,
                Some(c) if (matched == ".env" || matched == ".envrc") && (c == '_' || c == '-') => {
                    let suffix = rest[1..]
                        .split(|c: char| !(c.is_alphanumeric() || c == '-' || c == '_'))
                        .next()
                        .unwrap_or("");
                    !TEMPLATE_SUFFIXES.contains(&suffix)
                }
                Some(c) if c.is_alphanumeric() || c == '-' || c == '_' => false,
                Some('.') => {
                    let suffix = rest[1..]
                        .split(|c: char| !(c.is_alphanumeric() || c == '-' || c == '_'))
                        .next()
                        .unwrap_or("");
                    !TEMPLATE_SUFFIXES.contains(&suffix)
                }
                Some(_) => true,
            }
        })
    })
}

pub fn matching_builtin_sensitive_substring(lowered_command: &str) -> Option<&'static str> {
    BUILTIN_SENSITIVE_SUBSTRINGS
        .iter()
        .find(|needle| lowered_command.contains(**needle))
        .copied()
}

pub fn has_disqualifying_argument(tokens: &[&str]) -> bool {
    const PER_PROGRAM: &[(&str, &[&str])] = &[
        (
            "git",
            &[
                "-c",
                "-o",
                "-p",
                "--paginate",
                "--config",
                "--output",
                "--upload-pack",
                "--receive-pack",
                "--exec-path",
                "--config-env",
                "--work-tree",
            ],
        ),
        ("cargo", &["--config", "--manifest-path"]),
        ("fd", &["--exec", "--exec-batch"]),
        (
            "find",
            &[
                "-exec", "-execdir", "-delete", "-ok", "-okdir", "-fprint", "-fls", "-fprint0",
                "-fprintf",
            ],
        ),
        ("rg", &["--pre", "--hostname-bin"]),
        ("tree", &["-o", "-H", "--output"]),
        ("tail", &["-f", "-F", "--follow"]),
        (
            "export",
            &[
                "LD_PRELOAD",
                "LD_LIBRARY_PATH",
                "DYLD_INSERT_LIBRARIES",
                "DYLD_LIBRARY_PATH",
                "BASH_ENV",
                "ENV",
                "PS4",
                "PYTHONPATH",
                "RUBYOPT",
                "PERL5OPT",
                "NODE_OPTIONS",
            ],
        ),
    ];
    const SHORT_FLAG_BUNDLE_PROGRAMS: &[(&str, &[char])] = &[
        ("fd", &['x', 'X']),
        ("tail", &['f', 'F']),
        ("git", &['o', 'c', 'p']),
        ("tree", &['o', 'H']),
    ];

    let Some(program) = tokens.first().map(|token| program_name(token)) else {
        return false;
    };
    let arguments = &tokens[1..];
    let has_flag = || {
        PER_PROGRAM
            .iter()
            .find(|(name, _)| *name == program)
            .is_some_and(|(_, flags)| {
                flags.iter().any(|&flag| {
                    arguments.iter().any(|argument| {
                        if flag.starts_with("--") {
                            argument == &flag
                                || argument
                                    .strip_prefix(flag)
                                    .is_some_and(|rest| rest.starts_with('='))
                        } else {
                            !argument.starts_with("--") && argument.starts_with(flag)
                        }
                    })
                })
            })
    };
    let has_bundled = || {
        SHORT_FLAG_BUNDLE_PROGRAMS
            .iter()
            .find(|(name, _)| *name == program)
            .is_some_and(|(_, flags)| {
                arguments
                    .iter()
                    .any(|argument| is_short_flag_bundle_containing(argument, flags))
            })
    };
    let has_remote_helper =
        || program == "git" && arguments.iter().any(|token| token.contains("::"));

    has_flag()
        || has_bundled()
        || has_remote_helper()
        || has_write_git_subcommand(program, arguments)
}

pub fn has_write_git_subcommand(program: &str, arguments: &[&str]) -> bool {
    const WRITE_FLAGS: &[&str] = &[
        "--delete",
        "--move",
        "--copy",
        "--force",
        "--set-upstream-to",
        "--unset-upstream",
        "--edit-description",
    ];
    const WRITE_SHORT_FLAGS: &[char] = &['d', 'D', 'm', 'M', 'c', 'C', 'f'];

    if program != "git" {
        return false;
    }
    let Some((subcommand, sub_args)) = parse_git_subcommand(arguments) else {
        return false;
    };
    let is_listing_branch = sub_args.is_empty()
        || sub_args.contains(&"--show-current")
        || sub_args.contains(&"--list")
        || sub_args.contains(&"-l")
        || sub_args.contains(&"-a")
        || sub_args.contains(&"--all")
        || sub_args.contains(&"-r")
        || sub_args.contains(&"--remotes")
        || sub_args.contains(&"--contains")
        || sub_args.contains(&"--no-contains")
        || sub_args.contains(&"--merged")
        || sub_args.contains(&"--no-merged")
        || sub_args.contains(&"--points-at")
        || sub_args.iter().any(|a| {
            a.starts_with("--contains=")
                || a.starts_with("--no-contains=")
                || a.starts_with("--merged=")
                || a.starts_with("--no-merged=")
                || a.starts_with("--points-at=")
        });
    match subcommand {
        "branch" if is_listing_branch => sub_args.iter().any(|token| {
            WRITE_FLAGS.contains(token) || is_short_flag_bundle_containing(token, WRITE_SHORT_FLAGS)
        }),
        "remote"
            if sub_args.iter().all(|a| a.starts_with('-'))
                && (sub_args.contains(&"-v")
                    || sub_args.contains(&"--verbose")
                    || sub_args.is_empty()) =>
        {
            false
        }
        "remote" => true,
        "branch" if sub_args.iter().any(|token| !token.starts_with('-')) => true,
        "branch" => sub_args.iter().any(|token| {
            WRITE_FLAGS.contains(token) || is_short_flag_bundle_containing(token, WRITE_SHORT_FLAGS)
        }),
        _ => false,
    }
}

pub fn is_short_flag_bundle_containing(token: &str, flags: &[char]) -> bool {
    match token.strip_prefix('-') {
        Some(bundle)
            if !bundle.starts_with('-') && bundle.chars().all(|c| c.is_ascii_alphabetic()) =>
        {
            bundle.chars().any(|c| flags.contains(&c))
        }
        _ => false,
    }
}

pub fn unquote_segment(segment: &str) -> std::borrow::Cow<'_, str> {
    if !segment.contains(['"', '\'']) {
        return std::borrow::Cow::Borrowed(segment);
    }
    std::borrow::Cow::Owned(
        segment
            .chars()
            .filter(|c| !matches!(c, '"' | '\''))
            .collect(),
    )
}

pub fn program_name(token: &str) -> &str {
    let unescaped = token.strip_prefix('\\').unwrap_or(token);
    let base = unescaped.rsplit(['/', '\\']).next().unwrap_or(unescaped);
    if let Some(stripped) = base.strip_suffix(".exe") {
        stripped
    } else {
        base
    }
}

pub fn is_network_pipe_to_interpreter(lowered_command: &str) -> bool {
    if !lowered_command.contains('|') {
        return false;
    }
    let fetches = NETWORK_FETCHERS
        .iter()
        .any(|fetcher| lowered_command.contains(fetcher));
    if !fetches {
        return false;
    }
    lowered_command.split('|').skip(1).any(|stage| {
        stage
            .split_whitespace()
            .any(|token| PIPE_TARGETS.contains(&program_name(token)))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::JudgeConfig;
    use crate::judge::{JudgeDecision, JudgeRequest};
    use crate::session::SessionId;

    fn evaluate_cmd(cmd: &str) -> Option<JudgeVerdict> {
        let config = JudgeConfig::default();
        let rules = JudgeRules::new(&config);
        let req = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "run_command".to_string(),
            command_line: Some(cmd.to_string()),
            path: None,
            cwd: None,
        };
        rules.evaluate(&req)
    }

    #[test]
    fn git_branch_mutating_flags_and_creation_are_not_allowed() {
        assert_ne!(
            evaluate_cmd("git branch -d feat").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -D -r origin/feat").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -M old new").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -m old new").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -c old copy").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -C old copy").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -u upstream/main").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch --set-upstream-to=upstream/main").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch --unset-upstream").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch --edit-description").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch new_branch").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn git_branch_read_only_flags_are_allowed() {
        assert_eq!(
            evaluate_cmd("git branch").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch --show-current").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch -r").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch --remotes").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch -a").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch --all").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch --list feat/*").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn git_tag_mutating_flags_are_not_allowed() {
        assert_eq!(evaluate_cmd("git tag -d v1.0.0"), None);
        assert_eq!(evaluate_cmd("git tag -D v1.0.0"), None);
        assert_eq!(evaluate_cmd("git tag -a v1.0.0 -m release"), None);
        assert_eq!(evaluate_cmd("git tag -s v1.0.0"), None);
        assert_eq!(evaluate_cmd("git tag v1.0.0"), None);
    }

    #[test]
    fn git_tag_read_only_flags_are_allowed() {
        assert_eq!(
            evaluate_cmd("git tag").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git tag -l").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git tag --list v*").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn credential_path_relative_traversal_blocked() {
        let req_env = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "view_file".to_string(),
            command_line: None,
            path: Some("./src/../../.env".to_string()),
            cwd: None,
        };
        let req_aws = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "view_file".to_string(),
            command_line: None,
            path: Some("foo/../.aws/credentials".to_string()),
            cwd: None,
        };
        let req_ssh = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "run_command".to_string(),
            command_line: Some("cat ./src/../../.ssh/id_rsa".to_string()),
            path: None,
            cwd: None,
        };

        assert_eq!(
            check_target_credential_path(&req_env),
            Some(".env".to_string())
        );
        assert_eq!(
            check_target_credential_path(&req_aws),
            Some(".aws/credentials".to_string())
        );
        assert_eq!(
            check_target_credential_path(&req_ssh),
            Some(".ssh".to_string())
        );
    }

    #[test]
    fn template_files_are_not_blocked_as_credentials() {
        let req_example = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "view_file".to_string(),
            command_line: None,
            path: Some(".env.example".to_string()),
            cwd: None,
        };
        let req_sample = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "view_file".to_string(),
            command_line: None,
            path: Some(".env.sample".to_string()),
            cwd: None,
        };

        assert_eq!(check_target_credential_path(&req_example), None);
        assert_eq!(check_target_credential_path(&req_sample), None);
    }

    #[test]
    fn timeout_with_duration_suffixes_parses_effective_command() {
        assert_eq!(
            evaluate_cmd("timeout 5s cargo check").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("timeout 1.5s git status").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("timeout 2m cargo test").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    #[cfg(unix)]
    fn canonicalize_path_resolves_symlinks() {
        let temp_dir = std::env::temp_dir().join(format!(
            "triage-test-symlink-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&temp_dir).expect("create_dir_all");
        let target_file = temp_dir.join("real_config.toml");
        std::fs::write(&target_file, "[judge]\nenabled = true\n").expect("write");
        let symlink_path = temp_dir.join("symlink_config.toml");
        std::os::unix::fs::symlink(&target_file, &symlink_path).expect("symlink");

        let resolved = std::fs::canonicalize(&symlink_path).expect("canonicalize");
        assert_eq!(
            resolved,
            std::fs::canonicalize(&target_file).expect("canonicalize target")
        );
        let _ = std::fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn shell_profile_and_traversal_paths_blocked() {
        let req_bashrc = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "write_to_file".to_string(),
            command_line: None,
            path: Some("~/.bashrc".to_string()),
            cwd: None,
        };
        assert_eq!(
            check_target_credential_path(&req_bashrc),
            Some(".bashrc".to_string())
        );

        let req_traversal = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "view_file".to_string(),
            command_line: None,
            path: Some("foo/bar/../../.ssh/id_ed25519".to_string()),
            cwd: None,
        };
        assert_eq!(
            check_target_credential_path(&req_traversal),
            Some(".ssh".to_string())
        );
    }

    #[test]
    fn env_variants_blocked_while_templates_allowed() {
        let req_env_local = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "write_to_file".to_string(),
            command_line: None,
            path: Some("/project/.env.local".to_string()),
            cwd: None,
        };
        assert_eq!(
            check_target_credential_path(&req_env_local),
            Some(".env".to_string())
        );

        let req_env_underscore = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "view_file".to_string(),
            command_line: None,
            path: Some("/project/.env_production".to_string()),
            cwd: None,
        };
        assert_eq!(
            check_target_credential_path(&req_env_underscore),
            Some(".env".to_string())
        );

        let req_env_example = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "write_to_file".to_string(),
            command_line: None,
            path: Some("/project/.env.example".to_string()),
            cwd: None,
        };
        assert_eq!(check_target_credential_path(&req_env_example), None);
    }

    #[test]
    fn git_subcommands_with_global_flags_evaluate_accurately() {
        assert_eq!(
            evaluate_cmd("git -C /tmp --no-pager diff").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git -c user.name=\"x\" push origin main").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git --no-pager reset --hard HEAD~1").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn chained_and_piped_commands_with_empty_segments_or_sensitive_needles() {
        assert_eq!(
            evaluate_cmd("git -C /tmp/repo --no-pager diff HEAD~1").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("VAR=\"value with spaces\" git status").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("env -u FOO cargo check").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("echo \"security find-generic-password\"").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn unicode_words_are_preserved_without_byte_mangling() {
        let words = tokenize_words("git commit -m \"feat: 🚀 こんにちは世界\"");
        assert_eq!(
            words,
            vec!["git", "commit", "-m", "feat: 🚀 こんにちは世界"]
        );
    }

    #[test]
    fn relative_traversal_to_system_and_shadow_files_blocked() {
        for path in &[
            "./src/../../etc/passwd",
            "foo/../../etc/shadow",
            "bar/../etc/sudoers",
            "a/b/../../etc/hosts",
            "etc/passwd",
            "etc/shadow",
        ] {
            let req = JudgeRequest {
                session_id: SessionId::default(),
                tool_name: "view_file".to_string(),
                command_line: None,
                path: Some(path.to_string()),
                cwd: None,
            };
            assert!(
                check_target_credential_path(&req).is_some(),
                "Path {path} should be detected as a credential path"
            );
        }
    }

    #[test]
    fn global_flags_with_write_subcommands_are_disqualified() {
        assert!(has_disqualifying_argument(&[
            "git",
            "-C",
            "/tmp/repo",
            "branch",
            "new_branch"
        ]));
        assert!(has_disqualifying_argument(&[
            "git",
            "-C",
            "/tmp/repo",
            "remote",
            "add",
            "origin",
            "git@github.com:foo/bar.git"
        ]));
        assert!(!has_disqualifying_argument(&[
            "git",
            "-C",
            "/tmp/repo",
            "branch",
            "--list"
        ]));
        assert!(has_disqualifying_argument(&[
            "git",
            "-C/tmp/repo",
            "branch",
            "new_branch"
        ]));
        assert!(!has_disqualifying_argument(&[
            "git",
            "-C/tmp/repo",
            "branch",
            "--list"
        ]));
        assert_eq!(
            evaluate_cmd("git -C/tmp/repo status").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn builtin_deny_substrings_returns_sensitive_needles() {
        let substrings = builtin_deny_substrings();
        assert!(!substrings.is_empty());
        assert!(substrings.contains(&"cargo publish".to_string()));
        assert!(substrings.contains(&"security find-generic-password".to_string()));
    }

    #[test]
    fn compound_commands_with_null_redirections_and_unicode_semicolons() {
        assert_eq!(
            evaluate_cmd("cargo test > /dev/null 2>&1 && git status").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("(git status && cargo check)").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("ls \"unclosed quote; echo safe").map(|v| v.decision),
            None
        );
        assert_eq!(
            evaluate_cmd("git status 'unclosed quote; echo safe").map(|v| v.decision),
            None
        );
        assert_eq!(
            strip_null_redirections("echo \">/dev/null in quotes\" 2>/dev/null"),
            "echo \">/dev/null in quotes\"  "
        );
        let words = tokenize_words("git commit -m \"feat: handle ; in string literals 🚀\"");
        assert_eq!(
            words,
            vec![
                "git",
                "commit",
                "-m",
                "feat: handle ; in string literals 🚀"
            ]
        );
    }

    #[test]
    fn developer_and_cli_secrets_blocked() {
        for path in &[
            "~/.cargo/credentials.toml",
            "~/.cargo/credentials",
            "~/.aws/config",
            "~/.aws/credentials",
            "~/.dockercfg",
            "~/.vault-token",
            "~/.config/op/config",
            "C:\\Users\\admin\\.aws\\credentials",
            "\\\\?\\C:\\Users\\admin\\.aws\\credentials",
            "\\\\.\\C:\\.env",
        ] {
            let req = JudgeRequest {
                session_id: SessionId::default(),
                tool_name: "view_file".to_string(),
                command_line: None,
                path: Some(path.to_string()),
                cwd: None,
            };
            assert!(
                check_target_credential_path(&req).is_some(),
                "Path {path} should be detected as a credential path"
            );
        }
    }

    #[test]
    fn gh_api_graphql_is_disqualified() {
        assert_eq!(
            evaluate_cmd("gh api graphql -f query='query { viewer { login } }'")
                .map(|v| v.decision),
            None
        );
        assert_eq!(evaluate_cmd("gh api graphql").map(|v| v.decision), None);
        assert_eq!(evaluate_cmd("gh api /graphql").map(|v| v.decision), None);
        assert_eq!(
            evaluate_cmd("gh api user").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("gh api /repos/owner/repo/pulls").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn git_execution_modifying_flags_disqualified() {
        assert_eq!(
            evaluate_cmd("git -c core.pager=rm status").map(|v| v.decision),
            None
        );
        assert_eq!(
            evaluate_cmd("git -c core.askPass=/tmp/script diff").map(|v| v.decision),
            None
        );
        assert_eq!(
            evaluate_cmd("git --exec-path=/tmp/malicious log").map(|v| v.decision),
            None
        );
        assert_eq!(
            evaluate_cmd("git --config-env=VAR=VAL status").map(|v| v.decision),
            None
        );
        assert_eq!(evaluate_cmd("git -p status").map(|v| v.decision), None);
        assert_eq!(
            evaluate_cmd("git --paginate status").map(|v| v.decision),
            None
        );
        assert_eq!(
            evaluate_cmd("git status").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git diff HEAD").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn export_disqualifies_sensitive_environment_variables() {
        assert_eq!(
            evaluate_cmd("export LD_PRELOAD=/tmp/evil.so").map(|v| v.decision),
            None
        );
        assert_eq!(
            evaluate_cmd("export DYLD_INSERT_LIBRARIES=/tmp/evil.dylib").map(|v| v.decision),
            None
        );
        assert_eq!(
            evaluate_cmd("export BASH_ENV=/tmp/evil.sh").map(|v| v.decision),
            None
        );
        assert_eq!(
            evaluate_cmd("export PATH=/usr/bin:$PATH").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("export RUST_BACKTRACE=1").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn git_tag_and_branch_attached_flags_disqualified() {
        assert_ne!(
            evaluate_cmd("git tag -d1.0.0").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git tag -D1.0.0").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git tag -f1.0.0").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git tag -a1.0.0").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git tag -s1.0.0").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git tag -u1.0.0").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git tag -l").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git tag --list").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git tag").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git tag 'v*'").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );

        assert_ne!(
            evaluate_cmd("git branch -d feat").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -D feat").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -d123").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -r -d123").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -a -D123").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git branch -r -m123").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch -a").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch -r").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch --show-current").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_agent_coordination_and_task_tools_are_read_only() {
        assert!(!is_read_only_tool("manage_task"));
        assert!(!is_read_only_tool("manage_tasks"));
        assert!(!is_read_only_tool("managetask"));
        assert!(!is_read_only_tool("managetasks"));
        assert!(!is_read_only_tool("task_stop"));
        assert!(!is_read_only_tool("stop_task"));
        assert!(!is_read_only_tool("taskstop"));
        assert!(!is_read_only_tool("stoptask"));
        assert!(!is_read_only_tool("schedule"));
        assert!(is_read_only_tool("task_status"));
        assert!(is_read_only_tool("get_task_status"));
        assert!(is_read_only_tool("list_tasks"));
        assert!(is_read_only_tool("task_list"));
        assert!(is_read_only_tool("tasklist"));
        assert!(is_read_only_tool("websearch"));
        assert!(is_read_only_tool("web_fetch"));
        assert!(is_read_only_tool("webfetch"));
        assert!(is_read_only_tool("read_url"));
        assert!(is_read_only_tool("tool_search"));
        assert!(is_read_only_tool("toolsearch"));
        assert!(is_read_only_tool("skill"));
        assert!(is_read_only_tool("artifact"));
        assert!(is_read_only_tool("ask_user_question"));
        assert!(is_read_only_tool("askuserquestion"));
    }

    #[test]
    fn test_gradle_build_commands_are_allowed() {
        assert_eq!(
            evaluate_cmd("./gradlew test").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("gradlew build").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("gradle check").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd(
                "ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew ktfmtFormat testDebugUnitTest"
            )
            .map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd(
                "cd worktrees/demo/android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew test"
            )
            .map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_robust_cli_positional_flag_matching() {
        assert_eq!(
            evaluate_cmd("gh --repo hyeons-lab/triage pr view 149").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("gh -R hyeons-lab/triage issue list").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("cargo --locked test --all").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("cargo -p triage-core check").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("cargo --offline test").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("flutter -d macos test").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("flutter --no-pub test").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("pnpm --silent test").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git -C crates/triaged status").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git log --oneline -5").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git diff --cached").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git status --porcelain").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git diff --color").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git branch -a").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("pbpaste").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("pbcopy").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("env GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true git rebase --continue")
                .map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git rebase --abort").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git cherry-pick --continue").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git merge --abort").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git stash pop").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git fetch origin").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git -C worktrees/foo fetch --all").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git pull origin main").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git pull --rebase").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git worktree add worktrees/feat -b feat/x origin/main")
                .map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git fetch ext::sh -c id").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("cargo test --all-targets -- --nocapture").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("cargo clippy --workspace -- -D warnings").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("flutter test test/widget_test.dart").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("flutter pub get").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("dart format --fix .").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("pnpm run test:unit --filter @app/core").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("npm run build").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("bun test").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("yarn check").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );

        // Wildcard custom rule test
        let custom_cfg = JudgeConfig {
            allow_commands: vec!["adb logcat*".into(), "pytest *".into()],
            ..JudgeConfig::default()
        };
        let custom_rules = JudgeRules::new(&custom_cfg);
        let req1 = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "run_command".into(),
            command_line: Some("adb logcat -d -v time".into()),
            path: None,
            cwd: None,
        };
        assert_eq!(
            custom_rules.evaluate(&req1).map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        let req2 = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "run_command".into(),
            command_line: Some("pytest tests/test_api.py -v".into()),
            path: None,
            cwd: None,
        };
        assert_eq!(
            custom_rules.evaluate(&req2).map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_namespaced_and_prefixed_tool_calls() {
        let rules = JudgeRules::new(&JudgeConfig::default());
        let view_req = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "default_api:view_file".into(),
            command_line: None,
            path: Some("/Users/dev/project/src/main.rs".into()),
            cwd: None,
        };
        assert_eq!(
            rules.evaluate(&view_req).map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );

        let cmd_req = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "default_api:run_command".into(),
            command_line: Some("cargo test".into()),
            path: None,
            cwd: None,
        };
        assert_eq!(
            rules.evaluate(&cmd_req).map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );

        let mcp_req = JudgeRequest {
            session_id: SessionId::default(),
            tool_name: "code-review-graph:query_graph".into(),
            command_line: None,
            path: None,
            cwd: None,
        };
        assert_eq!(
            rules.evaluate(&mcp_req).map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_git_worktree_and_stash_mutations_not_allowed() {
        assert_ne!(
            evaluate_cmd("git worktree remove list").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git stash drop show").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git stash clear").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git worktree list").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git worktree list --porcelain").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git stash list").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git stash show 'stash@{0}'").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git stash show").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git stash pop").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_extract_positional_tokens_preserves_bare_hyphen() {
        let tokens = vec!["git", "switch", "-"];
        let positionals = extract_positional_tokens(&tokens);
        assert_eq!(positionals, vec!["git", "switch", "-"]);

        let tokens = vec!["git", "diff", "--", "-"];
        let positionals = extract_positional_tokens(&tokens);
        assert_eq!(positionals, vec!["git", "diff", "-"]);
    }

    #[test]
    fn test_gh_api_headers_and_graphql() {
        assert_eq!(
            evaluate_cmd("gh api -H 'X-Custom: graphql' repos/hyeons-lab/triage")
                .map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("gh api graphql -f query='{ viewer { login } }'").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_gradle_publish_denied() {
        assert_eq!(
            evaluate_cmd("./gradlew publish").map(|v| v.decision),
            Some(JudgeDecision::Ask)
        );
        assert_eq!(
            evaluate_cmd("gradlew publish").map(|v| v.decision),
            Some(JudgeDecision::Ask)
        );
        assert_eq!(
            evaluate_cmd("gradle publish").map(|v| v.decision),
            Some(JudgeDecision::Ask)
        );
        assert_eq!(
            evaluate_cmd("./gradlew test").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("./gradlew build").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_task_tools_classification() {
        assert!(is_read_only_tool("task_status"));
        assert!(is_read_only_tool("get_task_status"));
        assert!(is_read_only_tool("list_tasks"));
        assert!(is_read_only_tool("task_list"));
        assert!(!is_read_only_tool("manage_task"));
        assert!(!is_read_only_tool("manage_tasks"));
        assert!(!is_read_only_tool("task_stop"));
        assert!(!is_read_only_tool("stop_task"));
        assert!(!is_read_only_tool("schedule"));
    }

    #[test]
    fn test_git_push_receive_pack_and_exec_blocked() {
        assert_ne!(
            evaluate_cmd("git push --receive-pack='sh -c evil' origin main").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_ne!(
            evaluate_cmd("git push --exec=calc.exe origin main").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git push origin main").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git push -u origin HEAD:refs/heads/feature").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_python_adb_go_node_allow_rules() {
        assert_eq!(
            evaluate_cmd("python3 --version").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("python3 -m pytest tests/").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("pytest tests/").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("adb logcat -d").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("adb devices").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("$HOME/Library/Android/sdk/platform-tools/adb -s R5CXC3C2LNT logcat -t 100 -s AssistantSvc BriefOverlay GlowOverlay").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("adb -s MOCK_SERIAL_123 shell \"am broadcast -n com.example.app/.service.DebugReceiver\"").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd(
                "sleep 1.5 && adb -s MOCK_SERIAL_123 exec-out screencap -p > /tmp/popup.png"
            )
            .map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("git -C /work/repo/worktrees/feature diff main...HEAD > /work/repo/scratch/diff.patch").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("go test ./...").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_heredoc_multiline_scripts_allowed() {
        let script = "cd /some/dir && python3 - <<'PYEOF'\nimport io\ns = 'hello'\nprint(s)\nPYEOF\ngrep -c 'pattern' file.txt";
        assert_eq!(
            evaluate_cmd(script).map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        let script2 = "python3 - <<'PY'\nimport re\np = 'review112.md'\nPY";
        assert_eq!(
            evaluate_cmd(script2).map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_docker_podman_and_archive_allow_rules() {
        assert_eq!(
            evaluate_cmd("docker build --platform linux/amd64 -t my-img:latest .")
                .map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("docker run --rm -it my-img:latest").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("docker ps -a").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("docker images").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("unzip -l archive.zip").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("tar -xzf archive.tar.gz").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
    }

    #[test]
    fn test_scripts_path_wildcard_and_pm_version_rules() {
        assert_eq!(
            evaluate_cmd("./scripts/install.sh").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("./scripts/custom_build.sh").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        assert_eq!(
            evaluate_cmd("scripts/bump-version.sh 0.4.0").map(|v| v.decision),
            Some(JudgeDecision::Allow)
        );
        let npm_ver = evaluate_cmd("npm --version").unwrap();
        assert_eq!(npm_ver.decision, JudgeDecision::Allow);
        assert_eq!(npm_ver.reason, "matched allow rule: npm --version");
        let pnpm_ver = evaluate_cmd("pnpm -v").unwrap();
        assert_eq!(pnpm_ver.decision, JudgeDecision::Allow);
        assert_eq!(pnpm_ver.reason, "matched allow rule: pnpm --version");
    }
}
