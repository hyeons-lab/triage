//! Typed Triage configuration loaded from TOML.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub general: GeneralConfig,
    pub ui: UiConfig,
    pub attention: AttentionConfig,
    pub agents: AgentsConfig,
    pub remote: RemoteConfig,
    pub mcp: McpConfig,
    pub grpc: GrpcConfig,
    pub approval: ApprovalConfig,
    pub judge: JudgeConfig,
    pub keybindings: KeybindingsConfig,
    pub summarizer: SummarizerConfig,
    pub update: UpdateConfig,
    pub workers: crate::workers::WorkersConfig,
}

impl Config {
    pub fn from_toml_str(input: &str) -> Result<Self> {
        let config: Self = toml::from_str(input).context("parsing config TOML")?;
        config.validate()?;
        Ok(config)
    }

    pub fn load_from_path(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let input =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        Self::from_toml_str(&input)
    }

    pub fn default_path() -> Result<PathBuf> {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .context("neither HOME nor USERPROFILE environment variable is set")?;
        Ok(PathBuf::from(home).join(".config/triage/config.toml"))
    }

    pub fn validate(&self) -> Result<()> {
        self.general.validate()?;
        self.ui.validate()?;
        self.attention.validate()?;
        self.agents.validate()?;
        self.remote.validate()?;
        self.mcp.validate()?;
        self.grpc.validate()?;
        self.approval.validate()?;
        self.judge.validate()?;
        self.keybindings.validate()?;
        self.summarizer.validate()?;
        self.update.validate()?;
        self.workers.validate()?;
        Ok(())
    }
}

/// Settings for the background update check (Phase 1 of self-update). The daemon
/// periodically asks the release host for the latest published tag and surfaces
/// an "update available" banner; nothing is ever downloaded or installed
/// automatically. Set `check = false` to disable the check entirely.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct UpdateConfig {
    /// Whether the daemon polls for newer releases at all.
    pub check: bool,
    /// How often to poll, in hours. Must be greater than zero.
    pub interval_hours: u64,
    /// Release channel to track. Only `stable` is recognized today.
    pub channel: String,
}

impl UpdateConfig {
    fn validate(&self) -> Result<()> {
        ensure!(
            self.interval_hours > 0,
            "update.interval_hours must be greater than zero"
        );
        ensure_non_empty("update.channel", &self.channel)?;
        // Only `stable` is wired up today; reject anything else loudly rather
        // than silently accepting a channel that has no effect. Relax this to an
        // enum once more channels exist.
        ensure!(
            self.channel == "stable",
            "update.channel must be \"stable\" (the only channel supported today)"
        );
        Ok(())
    }
}

impl Default for UpdateConfig {
    fn default() -> Self {
        Self {
            check: true,
            interval_hours: 6,
            channel: "stable".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct GeneralConfig {
    pub default_shell: String,
}

impl GeneralConfig {
    fn validate(&self) -> Result<()> {
        ensure_non_empty("general.default_shell", &self.default_shell)
    }
}

impl Default for GeneralConfig {
    fn default() -> Self {
        Self {
            default_shell: "/bin/zsh".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct UiConfig {
    pub theme: String,
    pub sidebar_width_percent: u8,
    pub group_by: GroupBy,
}

impl UiConfig {
    fn validate(&self) -> Result<()> {
        ensure!(
            (1..=80).contains(&self.sidebar_width_percent),
            "ui.sidebar_width_percent must be between 1 and 80"
        );
        ensure_non_empty("ui.theme", &self.theme)
    }
}

impl Default for UiConfig {
    fn default() -> Self {
        Self {
            theme: "catppuccin-mocha".to_string(),
            sidebar_width_percent: 22,
            group_by: GroupBy::Worktree,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum GroupBy {
    Repo,
    Worktree,
    Flat,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AttentionConfig {
    pub idle_threshold_ms: u64,
    pub notify_on_awaiting: bool,
    pub notify_sound: bool,
}

impl AttentionConfig {
    fn validate(&self) -> Result<()> {
        ensure!(
            self.idle_threshold_ms > 0,
            "attention.idle_threshold_ms must be greater than zero"
        );
        Ok(())
    }
}

impl Default for AttentionConfig {
    fn default() -> Self {
        Self {
            idle_threshold_ms: 1500,
            notify_on_awaiting: true,
            notify_sound: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AgentsConfig {
    pub known: Vec<String>,
    pub custom_pack: AgentPatternPack,
}

impl AgentsConfig {
    fn validate(&self) -> Result<()> {
        ensure_non_empty_items("agents.known", &self.known)?;
        self.custom_pack.validate("agents.custom_pack")
    }
}

impl Default for AgentsConfig {
    fn default() -> Self {
        Self {
            known: vec![
                "claude".to_string(),
                "aider".to_string(),
                "codex".to_string(),
                "cline".to_string(),
                "continue".to_string(),
            ],
            custom_pack: AgentPatternPack::default(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AgentPatternPack {
    pub process_names: Vec<String>,
    pub prompt_patterns: Vec<String>,
}

impl AgentPatternPack {
    fn validate(&self, prefix: &str) -> Result<()> {
        ensure_non_empty_items(&format!("{prefix}.process_names"), &self.process_names)?;
        ensure_non_empty_items(&format!("{prefix}.prompt_patterns"), &self.prompt_patterns)
    }
}

/// Tailscale reports tag-owned (non-user) nodes with this synthetic login. It
/// is shared by *every* tagged node on a tailnet, so it must never be treated
/// as an identity: rejected in config validation and never matched by the
/// pairing gate (defense in depth).
pub const TAGGED_DEVICES_LOGIN: &str = "tagged-devices";

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RemoteConfig {
    pub bind: String,
    pub require_pairing: bool,
    pub tls_cert: Option<String>,
    pub tls_key: Option<String>,
    pub web_assets_path: Option<String>,
    /// Deprecated: legacy allowlist for the removed web `/pair` approval route.
    /// Pairing approval is handled exclusively via `triage pair` now. Kept for
    /// config-file compatibility; the value is ignored (never validated).
    pub pair_approval_tailnet_users: Vec<String>,
    /// Tailnet users allowed to pair via Tailscale identity, matched against
    /// `UserProfile.LoginName` from `tailscale whois`. Empty (default) keeps
    /// the device-code + `triage pair` flow; non-empty replaces it: code
    /// challenges are refused and pairing mints a token only for allowlisted
    /// peers. Entries must be non-empty.
    pub tailscale_pair_users: Vec<String>,
    /// Deprecated: legacy toggle for the removed web `/pair` approval route.
    /// Kept for config-file compatibility; the value is ignored (never validated).
    pub pair_approval_trust_local_peers: bool,
}

impl RemoteConfig {
    pub fn bind_addr(&self) -> Result<SocketAddr> {
        parse_socket_addr("remote.bind", &self.bind)
    }

    fn validate(&self) -> Result<()> {
        self.bind_addr()?;
        if let Some(ref path) = self.web_assets_path {
            ensure_non_empty("remote.web_assets_path", path)?;
        }
        ensure_non_empty_items("remote.tailscale_pair_users", &self.tailscale_pair_users)?;
        for (index, user) in self.tailscale_pair_users.iter().enumerate() {
            ensure!(
                user.trim().to_lowercase() != TAGGED_DEVICES_LOGIN,
                "remote.tailscale_pair_users[{index}] must not be the shared \
                 tagged-devices pseudo-login"
            );
        }
        // `pair_approval_*` keys are deprecated no-ops (the web `/pair` route no
        // longer exists), so they are parsed for compatibility but never
        // validated — a stale value must not fail daemon startup.
        match (&self.tls_cert, &self.tls_key) {
            (Some(cert), Some(key)) => {
                ensure_non_empty("remote.tls_cert", cert)?;
                ensure_non_empty("remote.tls_key", key)
            }
            (None, None) => Ok(()),
            _ => bail!("remote.tls_cert and remote.tls_key must be set together"),
        }
    }
}

impl Default for RemoteConfig {
    fn default() -> Self {
        Self {
            // Bind to all interfaces by default so the client can connect from
            // another device (LAN/tailnet). Access is gated by pairing
            // (`require_pairing`, default true); `triaged` logs a warning at
            // startup when bound to an unspecified address.
            bind: "0.0.0.0:7777".to_string(),
            require_pairing: true,
            tls_cert: None,
            tls_key: None,
            web_assets_path: None,
            // Deprecated no-op; kept at the default for config compatibility.
            pair_approval_tailnet_users: Vec::new(),
            tailscale_pair_users: Vec::new(),
            // Deprecated no-op; kept at the default for config compatibility.
            pair_approval_trust_local_peers: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct McpConfig {
    pub tcp_bind: String,
}

impl McpConfig {
    pub fn tcp_bind_addr(&self) -> Result<SocketAddr> {
        parse_socket_addr("mcp.tcp_bind", &self.tcp_bind)
    }

    fn validate(&self) -> Result<()> {
        self.tcp_bind_addr()?;
        Ok(())
    }
}

impl Default for McpConfig {
    fn default() -> Self {
        Self {
            tcp_bind: "127.0.0.1:7778".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct GrpcConfig {
    pub enabled: bool,
    pub bind: Option<String>,
}

impl GrpcConfig {
    pub fn bind_addr(&self) -> Result<Option<SocketAddr>> {
        self.bind
            .as_deref()
            .map(|bind| parse_socket_addr("grpc.bind", bind))
            .transpose()
    }

    fn validate(&self) -> Result<()> {
        match (self.enabled, &self.bind) {
            (true, None) => bail!("grpc.bind must be set when grpc.enabled is true"),
            (_, Some(bind)) => {
                ensure_non_empty("grpc.bind", bind)?;
                self.bind_addr()?;
            }
            (false, None) => {}
        }
        Ok(())
    }
}

/// Legacy, unconsumed approval-pattern list.
///
/// This key has never had a consumer anywhere in the workspace. It is kept so
/// that configs already carrying it still load (the top-level table uses
/// `deny_unknown_fields`, so removing it would turn an inert key into a hard
/// startup error), but it does not gate anything. The tool-call approval path is
/// [`JudgeConfig`]; see `judge.deny_substrings` / `judge.allow_commands` for the
/// rules that actually run.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ApprovalConfig {
    pub patterns: Vec<String>,
}

impl ApprovalConfig {
    fn validate(&self) -> Result<()> {
        ensure_non_empty_items("approval.patterns", &self.patterns)?;
        if !self.patterns.is_empty() {
            tracing::warn!(
                count = self.patterns.len(),
                "[approval] patterns is not implemented and gates nothing; \
                 use [judge] deny_substrings / allow_commands instead"
            );
        }
        Ok(())
    }
}

/// Settings for the local-model tool-call approval judge.
///
/// The judge answers `PreToolUse` hook queries from agent CLIs running inside
/// Triage sessions. Its layering is deliberate and is documented in full on
/// `triaged::judge`; the parts that are configurable are here.
///
/// `deny_substrings` is additive to the built-in deny rules and cannot weaken
/// them. `allow_commands` is additive to the built-in allowlist, and entries
/// only ever match a command with no shell metacharacters, so an allowlisted
/// prefix cannot be used to smuggle a second command past the judge.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct JudgeConfig {
    /// Master switch. When false the daemon answers every query `ask`, which is
    /// the same behavior as having no hook installed.
    pub enabled: bool,
    /// Whether a session judges tool calls unless told otherwise. Sessions carry
    /// a per-session override on top of this; see the settings screen.
    ///
    /// Defaults to `true`: auto-approval is enabled out-of-the-box for all sessions.
    /// Set to `false` to make judging opt-in per session.
    pub default_enabled_per_session: bool,
    /// How long the daemon may spend on one decision before falling back to
    /// `ask`. Must stay comfortably under the hook's own timeout, since the hook
    /// blocks the agent's loop for this entire window.
    pub timeout_ms: u64,
    /// Extra deny substrings, matched against the whitespace-normalized command.
    /// Additive to the built-in deny rules.
    pub deny_substrings: Vec<String>,
    /// Extra always-safe commands, matched as a leading token sequence (e.g.
    /// `"npm test"`). Additive to the built-in allowlist.
    pub allow_commands: Vec<String>,
    /// Liquid `d1` decision model repository (`"LiquidAI/d1-2B-GGUF"`), direct
    /// Hugging Face `.gguf` URL, or local `.gguf` file path used by Layer 3.
    pub model: String,
    /// Quantization tag when `model` names a Hugging Face repository without an
    /// explicit `.gguf` artifact or inline `:quant` suffix (e.g. `"Q4_K_M"` or
    /// `"Q8_0"`). May be empty when `enabled` is `false` or `model` already
    /// carries a `.gguf` path/URL or `:quant` tag.
    pub quant: String,
    /// Minimum calibrated `allow` probability percentage (`1..=100`) required for
    /// Layer 3 to auto-approve a command. Below this threshold (or whenever `ask`
    /// wins), the judge returns `ask`.
    pub min_allow_confidence_pct: u8,
    /// Optional model cache directory override. `None` uses `~/.cache/triage/models`.
    pub cache_dir: Option<String>,
}

impl JudgeConfig {
    pub fn validate(&self) -> Result<()> {
        ensure_non_empty_items("judge.deny_substrings", &self.deny_substrings)?;
        ensure_non_empty_items("judge.allow_commands", &self.allow_commands)?;
        for cmd in &self.allow_commands {
            ensure!(
                !cmd.chars().any(|c| matches!(
                    c,
                    ';' | '&' | '|' | '\n' | '\r' | '$' | '`' | '>' | '<' | '(' | ')'
                )),
                "judge.allow_commands entry cannot contain shell control characters: '{cmd}'"
            );
        }
        ensure!(
            self.timeout_ms > 0,
            "judge.timeout_ms must be greater than zero"
        );
        if !self.quant.trim().is_empty() {
            validate_quant_tag("judge.quant", &self.quant)?;
        }
        if self.enabled {
            ensure_non_empty("judge.model", &self.model)?;
            let optional_quant = model_carries_explicit_gguf_or_quant(&self.model)?;
            if self.quant.trim().is_empty() && !optional_quant {
                validate_quant_tag("judge.quant", &self.quant)?;
            }
        }
        ensure!(
            (1..=100).contains(&self.min_allow_confidence_pct),
            "judge.min_allow_confidence_pct must be between 1 and 100"
        );
        if let Some(ref dir) = self.cache_dir {
            ensure_non_empty("judge.cache_dir", dir)?;
        }
        Ok(())
    }
}

impl Default for JudgeConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            default_enabled_per_session: true,
            timeout_ms: 8_000,
            deny_substrings: Vec::new(),
            allow_commands: Vec::new(),
            model: "LiquidAI/d1-2B-GGUF".to_string(),
            quant: "Q4_K_M".to_string(),
            min_allow_confidence_pct: 65,
            cache_dir: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct KeybindingsConfig {
    pub overview: String,
    pub search: String,
    pub next_attention: String,
    pub cycle_agents: String,
    pub cycle_current_repo: String,
    pub pause_all: String,
}

impl KeybindingsConfig {
    fn validate(&self) -> Result<()> {
        ensure_non_empty("keybindings.overview", &self.overview)?;
        ensure_non_empty("keybindings.search", &self.search)?;
        ensure_non_empty("keybindings.next_attention", &self.next_attention)?;
        ensure_non_empty("keybindings.cycle_agents", &self.cycle_agents)?;
        ensure_non_empty("keybindings.cycle_current_repo", &self.cycle_current_repo)?;
        ensure_non_empty("keybindings.pause_all", &self.pause_all)
    }
}

impl Default for KeybindingsConfig {
    fn default() -> Self {
        Self {
            overview: "ctrl+e".to_string(),
            search: "ctrl+f".to_string(),
            next_attention: "g w".to_string(),
            cycle_agents: "g a".to_string(),
            cycle_current_repo: "g r".to_string(),
            pause_all: "ctrl+shift+p".to_string(),
        }
    }
}

/// Local-LLM session summarizer: generates a short one-line description of what
/// each session is doing, shown in the client's side rail.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct SummarizerConfig {
    /// Master switch. When false, no model is loaded and no snippets are produced.
    pub enabled: bool,
    /// LeapBundles bundle id, e.g. `LFM2.5-1.2B-Instruct-GGUF`.
    pub bundle_id: String,
    /// Quantization tag, e.g. `Q4_0`.
    pub quant: String,
    /// Inference context window (tokens). Kept small — we only summarize one screen.
    pub context_size: u32,
    /// Upper bound on generated tokens per snippet.
    pub max_tokens: u32,
    /// Upper bound on generated tokens for the longer-form detail summary
    /// (hover popover / search). Larger than `max_tokens`.
    pub detail_max_tokens: u32,
    /// How long a session's output must be quiet before we (re)summarize it.
    pub settle_ms: u64,
    /// Minimum interval between regenerations for a single session.
    pub min_regen_ms: u64,
    /// Where to cache downloaded model files. `None` → `~/.cache/triage/models`.
    pub cache_dir: Option<String>,
}

impl SummarizerConfig {
    fn validate(&self) -> Result<()> {
        if !self.enabled {
            return Ok(());
        }
        ensure_non_empty("summarizer.bundle_id", &self.bundle_id)?;
        ensure_non_empty("summarizer.quant", &self.quant)?;
        ensure!(
            self.context_size > 0,
            "summarizer.context_size must be greater than zero"
        );
        ensure!(
            self.max_tokens > 0,
            "summarizer.max_tokens must be greater than zero"
        );
        ensure!(
            self.detail_max_tokens > 0,
            "summarizer.detail_max_tokens must be greater than zero"
        );
        if let Some(ref dir) = self.cache_dir {
            ensure_non_empty("summarizer.cache_dir", dir)?;
        }
        Ok(())
    }
}

impl Default for SummarizerConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            // Tool-call judging runs on its own dedicated `d1` decision model
            // (`JudgeConfig`), so session summarization uses the compact
            // 1.2B instruct bundle (664 MB at Q4_0).
            bundle_id: "LFM2.5-1.2B-Instruct-GGUF".to_string(),
            quant: "Q4_0".to_string(),
            context_size: 1024,
            max_tokens: 24,
            detail_max_tokens: 180,
            settle_ms: 1500,
            min_regen_ms: 5000,
            cache_dir: None,
        }
    }
}

fn parse_socket_addr(field: &str, value: &str) -> Result<SocketAddr> {
    ensure_non_empty(field, value)?;
    value
        .parse()
        .with_context(|| format!("{field} must be a socket address"))
}

fn ensure_non_empty(field: &str, value: &str) -> Result<()> {
    ensure!(!value.trim().is_empty(), "{field} must not be empty");
    Ok(())
}

/// Validates a model quantization tag (such as `"Q4_K_M"` or `"Q8_0"`) before
/// it is interpolated into a Hugging Face filename or cache key segment.
pub fn validate_quant_tag(field: &str, value: &str) -> Result<()> {
    let trimmed = value.trim();
    ensure!(!trimmed.is_empty(), "{field} must not be empty");
    ensure!(
        !trimmed.starts_with('.') && !trimmed.ends_with('.') && !trimmed.contains(".."),
        "{field} `{trimmed}` is not a valid quantization tag"
    );
    ensure!(
        !trimmed.to_ascii_lowercase().ends_with(".gguf"),
        "{field} `{trimmed}` must be a quantization tag (e.g. `Q4_K_M`), not a `.gguf` filename"
    );
    for ch in trimmed.chars() {
        ensure!(
            ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.'),
            "{field} `{trimmed}` contains invalid character {ch:?}"
        );
    }
    Ok(())
}

fn has_gguf_filename_suffix(s: &str) -> bool {
    let name = s.rsplit(['/', '\\']).next().unwrap_or(s);
    let bytes = name.as_bytes();
    bytes.len() > 5 && bytes[bytes.len() - 5..].eq_ignore_ascii_case(b".gguf")
}

/// Returns `Ok(true)` when `judge.model` already identifies a concrete `.gguf`
/// file/URL, explicit local filesystem path, or inline `:quant` tag (making a
/// separate `judge.quant` optional), `Ok(false)` when `judge.quant` is still
/// required, and `Err` when an inline `:quant` suffix is malformed.
fn model_carries_explicit_gguf_or_quant(model: &str) -> Result<bool> {
    let trimmed = model.trim();
    let bytes = trimmed.as_bytes();
    let is_http = (bytes.len() >= 7 && bytes[..7].eq_ignore_ascii_case(b"http://"))
        || (bytes.len() >= 8 && bytes[..8].eq_ignore_ascii_case(b"https://"));
    if is_http {
        let Some((_, after_scheme)) = trimmed.split_once("://") else {
            return Ok(false);
        };
        let Some((host, path)) = after_scheme.split_once('/') else {
            return Ok(false);
        };
        if host.is_empty() {
            return Ok(false);
        }
        let path_no_qs = path
            .split(['?', '#'])
            .next()
            .unwrap_or("")
            .trim_end_matches('/');
        return Ok(!path_no_qs.is_empty() && has_gguf_filename_suffix(path_no_qs));
    }

    let is_explicit_local = matches!(trimmed, "." | ".." | "~")
        || trimmed.starts_with('/')
        || trimmed.starts_with("./")
        || trimmed.starts_with("../")
        || trimmed.starts_with("~/")
        || trimmed.starts_with("~\\")
        || trimmed.contains('\\')
        || (bytes.len() >= 2
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && (bytes.len() == 2
                || bytes[2] == b'/'
                || bytes[2] == b'\\'
                || has_gguf_filename_suffix(trimmed)));
    if is_explicit_local || (has_gguf_filename_suffix(trimmed) && !trimmed.contains(':')) {
        return Ok(true);
    }

    // Mirror `cera::bundle::hf::HfSpec::parse_repo_id` extraction (`owner/repo:quant@rev`
    // or `owner/repo@rev:quant` or `repo:quant`).
    let mut inline_quant: Option<&str> = None;
    let mut base = trimmed;
    if let Some((b, r)) = base.split_once('@') {
        base = b;
        if let Some((_rev_part, q)) = r.split_once(':') {
            inline_quant = Some(q);
        }
    }
    if inline_quant.is_none()
        && let Some((b, q)) = base.split_once(':')
    {
        base = b;
        inline_quant = Some(q.split_once('@').map_or(q, |(q_part, _)| q_part));
    }
    ensure!(
        !base.trim().is_empty(),
        "judge.model must include a repository name before `:quant` or `@revision`"
    );
    if let Some(q) = inline_quant {
        validate_quant_tag("judge.model", q)?;
        return Ok(true);
    }
    Ok(false)
}

fn ensure_non_empty_items(field: &str, values: &[String]) -> Result<()> {
    for (index, value) in values.iter().enumerate() {
        ensure!(
            !value.trim().is_empty(),
            "{field}[{index}] must not be empty"
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::*;

    const FULL_CONFIG: &str = r#"
[general]
default_shell = "/bin/fish"

[ui]
theme = "catppuccin-latte"
sidebar_width_percent = 30
group_by = "repo"

[attention]
idle_threshold_ms = 2500
notify_on_awaiting = false
notify_sound = false

[agents]
known = ["claude", "codex"]

[agents.custom_pack]
process_names = ["my-agent"]
prompt_patterns = ['\? for shortcuts', '\[y/n\]']

[remote]
bind = "127.0.0.1:8888"
require_pairing = true
tls_cert = "~/.config/triage/certs/dev.crt"
tls_key = "~/.config/triage/certs/dev.key"
pair_approval_tailnet_users = ["alice@example.com", "bob@example.com"]
pair_approval_trust_local_peers = false
tailscale_pair_users = ["david@hyeons-lab.com"]

[mcp]
tcp_bind = "127.0.0.1:8889"

[grpc]
enabled = true
bind = "127.0.0.1:50051"

[approval]
patterns = ["^rm -rf"]

[judge]
enabled = true
default_enabled_per_session = true
timeout_ms = 5000
deny_substrings = ["terraform apply"]
allow_commands = ["npm test"]
model = "LiquidAI/d1-2B-GGUF"
quant = "Q8_0"
min_allow_confidence_pct = 75
cache_dir = "~/.cache/triage/judge-models"

[keybindings]
overview = "ctrl+o"
search = "ctrl+s"
next_attention = "g n"
cycle_agents = "g c"
cycle_current_repo = "g p"
pause_all = "ctrl+p"
"#;

    #[test]
    fn defaults_match_documented_config() {
        let config = Config::default();

        assert_eq!(config.general.default_shell, "/bin/zsh");
        assert_eq!(config.ui.theme, "catppuccin-mocha");
        assert_eq!(config.ui.sidebar_width_percent, 22);
        assert_eq!(config.ui.group_by, GroupBy::Worktree);
        assert_eq!(config.attention.idle_threshold_ms, 1500);
        assert!(config.attention.notify_on_awaiting);
        assert!(config.attention.notify_sound);
        assert_eq!(
            config.agents.known,
            ["claude", "aider", "codex", "cline", "continue"]
        );
        assert_eq!(config.remote.bind, "0.0.0.0:7777");
        assert!(config.remote.require_pairing);
        assert!(config.remote.pair_approval_tailnet_users.is_empty());
        assert!(config.remote.pair_approval_trust_local_peers);
        assert!(config.remote.tailscale_pair_users.is_empty());
        assert_eq!(config.mcp.tcp_bind, "127.0.0.1:7778");
        assert!(!config.grpc.enabled);
        assert_eq!(config.keybindings.next_attention, "g w");
        assert!(config.judge.enabled);
        assert_eq!(config.judge.model, "LiquidAI/d1-2B-GGUF");
        assert_eq!(config.judge.quant, "Q4_K_M");
        assert_eq!(config.judge.min_allow_confidence_pct, 65);
        assert_eq!(config.judge.cache_dir, None);
        assert!(config.summarizer.enabled);
        assert_eq!(config.summarizer.bundle_id, "LFM2.5-1.2B-Instruct-GGUF");
        assert_eq!(config.summarizer.quant, "Q4_0");
        assert_eq!(config.summarizer.context_size, 1024);
    }

    #[test]
    fn sparse_toml_uses_defaults() {
        let config = Config::from_toml_str(
            r#"
[ui]
theme = "plain"

[attention]
notify_sound = false
"#,
        )
        .expect("sparse config should parse");

        assert_eq!(config.ui.theme, "plain");
        assert_eq!(config.ui.sidebar_width_percent, 22);
        assert_eq!(config.ui.group_by, GroupBy::Worktree);
        assert_eq!(config.attention.idle_threshold_ms, 1500);
        assert!(!config.attention.notify_sound);
    }

    #[test]
    fn full_documented_toml_parses() {
        let config = Config::from_toml_str(FULL_CONFIG).expect("full config should parse");

        assert_eq!(config.general.default_shell, "/bin/fish");
        assert_eq!(config.ui.group_by, GroupBy::Repo);
        assert_eq!(config.remote.bind_addr().unwrap().port(), 8888);
        // The allowlist assertion below is only reachable because the fixture
        // also sets require_pairing = true (validation rejects the pair-approval
        // allowlist otherwise) — assert that coupling explicitly so it can't
        // regress silently.
        assert!(config.remote.require_pairing);
        assert_eq!(
            config.remote.pair_approval_tailnet_users,
            ["alice@example.com", "bob@example.com"]
        );
        assert!(!config.remote.pair_approval_trust_local_peers);
        assert_eq!(config.remote.tailscale_pair_users, ["david@hyeons-lab.com"]);
        assert_eq!(config.mcp.tcp_bind_addr().unwrap().port(), 8889);
        assert_eq!(config.grpc.bind_addr().unwrap().unwrap().port(), 50051);
        assert_eq!(config.approval.patterns, ["^rm -rf"]);
        // The exact `[judge]` key names are published in docs/approval-judge.md,
        // and the table uses `deny_unknown_fields`, so a rename would otherwise
        // surface as a user's startup error rather than a failing test.
        assert!(config.judge.enabled);
        assert!(config.judge.default_enabled_per_session);
        assert_eq!(config.judge.timeout_ms, 5_000);
        assert_eq!(config.judge.deny_substrings, ["terraform apply"]);
        assert_eq!(config.judge.allow_commands, ["npm test"]);
        assert_eq!(config.judge.model, "LiquidAI/d1-2B-GGUF");
        assert_eq!(config.judge.quant, "Q8_0");
        assert_eq!(config.judge.min_allow_confidence_pct, 75);
        assert_eq!(
            config.judge.cache_dir.as_deref(),
            Some("~/.cache/triage/judge-models")
        );
        assert_eq!(config.keybindings.overview, "ctrl+o");
    }

    #[test]
    fn invalid_group_by_fails() {
        let error = Config::from_toml_str(
            r#"
[ui]
group_by = "workspace"
"#,
        )
        .expect_err("invalid group_by should fail");

        assert!(error.to_string().contains("parsing config TOML"));
    }

    #[test]
    fn blank_tailscale_pair_user_fails() {
        let error = Config::from_toml_str(
            r#"
[remote]
tailscale_pair_users = ["david@hyeons-lab.com", " "]
"#,
        )
        .expect_err("blank allowlist entry should fail");

        assert!(
            error
                .to_string()
                .contains("remote.tailscale_pair_users[1] must not be empty")
        );
    }

    #[test]
    fn tagged_devices_pair_user_fails() {
        let error = Config::from_toml_str(
            r#"
[remote]
tailscale_pair_users = [" Tagged-Devices "]
"#,
        )
        .expect_err("tagged-devices pseudo-login should fail");

        assert!(
            error
                .to_string()
                .contains("must not be the shared tagged-devices pseudo-login")
        );
    }

    #[test]
    fn invalid_bind_address_fails() {
        let error = Config::from_toml_str(
            r#"
[remote]
bind = "localhost"
"#,
        )
        .expect_err("invalid bind should fail");

        assert!(
            error
                .to_string()
                .contains("remote.bind must be a socket address")
        );
    }

    #[test]
    fn invalid_sidebar_width_fails() {
        let error = Config::from_toml_str(
            r#"
[ui]
sidebar_width_percent = 0
"#,
        )
        .expect_err("invalid sidebar width should fail");

        assert!(
            error
                .to_string()
                .contains("ui.sidebar_width_percent must be between 1 and 80")
        );
    }

    #[test]
    fn tls_cert_and_key_must_be_paired() {
        let error = Config::from_toml_str(
            r#"
[remote]
tls_cert = "server.crt"
"#,
        )
        .expect_err("unpaired TLS cert should fail");

        assert!(
            error
                .to_string()
                .contains("remote.tls_cert and remote.tls_key must be set together")
        );
    }

    #[test]
    fn deprecated_pair_approval_keys_are_parsed_but_ignored() {
        // Stale values that validation used to reject must not fail startup now
        // that the web `/pair` route (their only consumer) is gone.
        let config = Config::from_toml_str(
            r#"
[remote]
require_pairing = false
pair_approval_tailnet_users = ["alice@example.com", " ", " Tagged-Devices "]
pair_approval_trust_local_peers = false
"#,
        )
        .expect("deprecated pair_approval keys should load without validation");

        assert_eq!(
            config.remote.pair_approval_tailnet_users,
            ["alice@example.com", " ", " Tagged-Devices "]
        );
        assert!(!config.remote.pair_approval_trust_local_peers);
    }

    #[test]
    fn empty_values_fail_validation() {
        let error = Config::from_toml_str(
            r#"
[keybindings]
search = " "
"#,
        )
        .expect_err("empty keybinding should fail");

        assert!(
            error
                .to_string()
                .contains("keybindings.search must not be empty")
        );
    }

    #[test]
    fn empty_default_shell_fails_validation() {
        let error = Config::from_toml_str(
            r#"
[general]
default_shell = " "
"#,
        )
        .expect_err("empty default shell should fail");

        assert!(
            error
                .to_string()
                .contains("general.default_shell must not be empty")
        );
    }

    #[test]
    fn enabled_grpc_requires_bind() {
        let error = Config::from_toml_str(
            r#"
[grpc]
enabled = true
"#,
        )
        .expect_err("enabled grpc without bind should fail");

        assert!(
            error
                .to_string()
                .contains("grpc.bind must be set when grpc.enabled is true")
        );
    }

    #[test]
    fn loads_from_path() {
        let unique = format!(
            "triage-config-test-{}-{}.toml",
            std::process::id(),
            std::time::UNIX_EPOCH
                .elapsed()
                .expect("system clock should be after Unix epoch")
                .as_nanos()
        );
        let path = std::env::temp_dir().join(unique);
        let mut file = std::fs::File::create(&path).expect("test config file should be created");
        file.write_all(
            br#"
[general]
default_shell = "/bin/bash"
"#,
        )
        .expect("test config should be written");
        file.flush().expect("test config should be flushed");
        drop(file);

        let config = Config::load_from_path(&path).expect("config should load from path");
        std::fs::remove_file(&path).expect("test config file should be removed");

        assert_eq!(config.general.default_shell, "/bin/bash");
    }

    #[test]
    fn update_defaults_are_valid() {
        let config = Config::default();
        assert!(config.update.check);
        assert_eq!(config.update.interval_hours, 6);
        assert_eq!(config.update.channel, "stable");
        config
            .validate()
            .expect("default update config should validate");
    }

    #[test]
    fn unknown_update_channel_is_rejected() {
        let error = Config::from_toml_str(
            r#"
[update]
channel = "beta"
"#,
        )
        .expect_err("an unrecognized update channel should fail");

        assert!(
            error
                .to_string()
                .contains("update.channel must be \"stable\""),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn zero_update_interval_is_rejected() {
        let error = Config::from_toml_str(
            r#"
[update]
interval_hours = 0
"#,
        )
        .expect_err("a zero update interval should fail");

        assert!(
            error
                .to_string()
                .contains("update.interval_hours must be greater than zero"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn judge_config_rejects_allow_commands_with_control_characters() {
        let error = Config::from_toml_str(
            r#"
[judge]
allow_commands = ["git status; rm -rf /"]
"#,
        )
        .expect_err("control characters in allow_commands should fail");

        assert!(
            error
                .to_string()
                .contains("cannot contain shell control characters"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn judge_config_validates_model_and_confidence_bounds() {
        for (toml_body, expected_substr) in [
            (
                "[judge]\nmodel = \"   \"\n",
                "judge.model must not be empty",
            ),
            ("[judge]\nquant = \"\"\n", "judge.quant must not be empty"),
            (
                "[judge]\nquant = \"../evil\"\n",
                "is not a valid quantization tag",
            ),
            (
                "[judge]\nquant = \"sub/Q4_K_M\"\n",
                "contains invalid character '/'",
            ),
            (
                "[judge]\nquant = \"Q4_K_M.gguf\"\n",
                "not a `.gguf` filename",
            ),
            (
                "[judge]\nquant = \"Q4_K_M?foo=bar\"\n",
                "contains invalid character '?'",
            ),
            (
                "[judge]\nmin_allow_confidence_pct = 0\n",
                "judge.min_allow_confidence_pct must be between 1 and 100",
            ),
            (
                "[judge]\nmin_allow_confidence_pct = 101\n",
                "judge.min_allow_confidence_pct must be between 1 and 100",
            ),
            (
                "[judge]\ncache_dir = \"  \"\n",
                "judge.cache_dir must not be empty",
            ),
            (
                "[judge]\nmodel = \"https://huggingface.co/LiquidAI/d1-2B-GGUF\"\nquant = \"\"\n",
                "judge.quant must not be empty",
            ),
            (
                "[judge]\nmodel = \"LiquidAI/d1-2B-GGUF@v1.0\"\nquant = \"\"\n",
                "judge.quant must not be empty",
            ),
            (
                "[judge]\nmodel = \"LiquidAI/d1-2B-GGUF:../evil\"\nquant = \"\"\n",
                "is not a valid quantization tag",
            ),
            (
                "[judge]\nmodel = \"LiquidAI/d1-2B-GGUF:Q4_K_M.gguf\"\nquant = \"\"\n",
                "not a `.gguf` filename",
            ),
            (
                "[judge]\nmodel = \"/tmp/local-d1.gguf\"\nquant = \"../evil\"\n",
                "is not a valid quantization tag",
            ),
            (
                "[judge]\nenabled = false\nquant = \"../evil\"\n",
                "is not a valid quantization tag",
            ),
        ] {
            let error = Config::from_toml_str(toml_body)
                .expect_err("invalid judge model config should fail");
            assert!(
                error.to_string().contains(expected_substr),
                "expected {expected_substr:?} in {error}"
            );
        }

        // Disabled judge or self-contained `.gguf` / local-path / inline `:quant`
        // specs may omit `judge.quant` (`quant = ""`) while keeping other `[judge]`
        // and `[remote]` settings intact.
        for valid_toml in [
            "[remote]\nbind = \"127.0.0.1:7777\"\n[judge]\nenabled = false\nmodel = \"\"\nquant = \"\"\ndeny_substrings = [\"terraform apply\"]\n",
            "[judge]\nmodel = \"/models/local-d1.gguf\"\nquant = \"\"\n",
            "[judge]\nmodel = \"./models/local-d1\"\nquant = \"\"\n",
            "[judge]\nmodel = \"https://example.com/models/custom-d1.gguf?sig=1\"\nquant = \"\"\n",
            "[judge]\nmodel = \"LiquidAI/d1-2B-GGUF/d1-2B-Q8_0.gguf\"\nquant = \"\"\n",
            "[judge]\nmodel = \"LiquidAI/d1-2B-GGUF:Q8_0\"\nquant = \"\"\n",
            "[judge]\nmodel = \"LiquidAI/d1-2B-GGUF@v1.0:Q8_0\"\nquant = \"\"\n",
            "[judge]\nmodel = \"d1-2B-GGUF:Q4_K_M@v1.0\"\nquant = \"\"\n",
        ] {
            Config::from_toml_str(valid_toml)
                .unwrap_or_else(|e| panic!("expected valid config for {valid_toml:?}, got: {e}"));
        }
    }
}
