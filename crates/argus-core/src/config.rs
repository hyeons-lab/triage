//! Typed Argus configuration loaded from TOML.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;

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
    pub keybindings: KeybindingsConfig,
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
        Ok(PathBuf::from(home).join(".config/argus/config.toml"))
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
        self.keybindings.validate()?;
        Ok(())
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

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RemoteConfig {
    pub bind: String,
    pub require_pairing: bool,
    pub tls_cert: Option<String>,
    pub tls_key: Option<String>,
}

impl RemoteConfig {
    pub fn bind_addr(&self) -> Result<SocketAddr> {
        parse_socket_addr("remote.bind", &self.bind)
    }

    fn validate(&self) -> Result<()> {
        self.bind_addr()?;
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
            bind: "127.0.0.1:7777".to_string(),
            require_pairing: true,
            tls_cert: None,
            tls_key: None,
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

#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ApprovalConfig {
    pub patterns: Vec<String>,
}

impl ApprovalConfig {
    fn validate(&self) -> Result<()> {
        ensure_non_empty_items("approval.patterns", &self.patterns)
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
require_pairing = false
tls_cert = "~/.config/argus/certs/dev.crt"
tls_key = "~/.config/argus/certs/dev.key"

[mcp]
tcp_bind = "127.0.0.1:8889"

[grpc]
enabled = true
bind = "127.0.0.1:50051"

[approval]
patterns = ["^rm -rf"]

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
        assert_eq!(config.remote.bind, "127.0.0.1:7777");
        assert!(config.remote.require_pairing);
        assert_eq!(config.mcp.tcp_bind, "127.0.0.1:7778");
        assert!(!config.grpc.enabled);
        assert_eq!(config.keybindings.next_attention, "g w");
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
        assert_eq!(config.mcp.tcp_bind_addr().unwrap().port(), 8889);
        assert_eq!(config.grpc.bind_addr().unwrap().unwrap().port(), 50051);
        assert_eq!(config.approval.patterns, ["^rm -rf"]);
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
            "argus-config-test-{}-{}.toml",
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
}
