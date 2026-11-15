use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};
use triaged::ipc::{REMOTE_RPC_PATH, WireRpcClient, WireRpcTransport};

const DEFAULT_CLIENT_ID: &str = "triage-mcp";
const BASE_RPC_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Deserialize)]
pub struct RemoteHostConfig {
    pub url: String,
    #[serde(default)]
    pub client_id: Option<String>,
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default)]
    pub token_env: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RemoteHostSummary {
    pub name: String,
    pub url: String,
    pub client_id: String,
    pub has_token: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct HostsFile {
    #[serde(default)]
    hosts: BTreeMap<String, RemoteHostConfig>,
}

#[derive(Debug, Clone, Default)]
pub struct HostRegistry {
    hosts: BTreeMap<String, RemoteHostConfig>,
}

pub fn default_hosts_path() -> Option<PathBuf> {
    if let Ok(override_path) = std::env::var("TRIAGE_HOSTS_PATH") {
        let trimmed = override_path.trim();
        if !trimmed.is_empty() {
            return Some(PathBuf::from(trimmed));
        }
    }
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        let trimmed = xdg.trim();
        if !trimmed.is_empty() {
            return Some(PathBuf::from(trimmed).join("triage").join("hosts.toml"));
        }
    }
    let home = std::env::var("HOME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            std::env::var("USERPROFILE")
                .ok()
                .filter(|value| !value.trim().is_empty())
        })?;
    Some(
        PathBuf::from(home)
            .join(".config")
            .join("triage")
            .join("hosts.toml"),
    )
}

impl HostRegistry {
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("reading hosts config {}", path.display()))?;
        Self::parse(&raw).with_context(|| format!("parsing hosts config {}", path.display()))
    }

    pub fn parse(raw: &str) -> Result<Self> {
        let file: HostsFile = toml::from_str(raw)?;
        for (name, host) in &file.hosts {
            if name.trim().is_empty() {
                bail!("host name cannot be blank");
            }
            let url = host.url.trim();
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                bail!("host {name} url must start with http:// or https://");
            }
        }
        Ok(Self { hosts: file.hosts })
    }

    pub fn summaries(&self) -> Vec<RemoteHostSummary> {
        self.hosts
            .iter()
            .map(|(name, config)| RemoteHostSummary {
                name: name.clone(),
                url: config.url.trim_end_matches('/').to_string(),
                client_id: resolved_client_id(config),
                has_token: resolve_token(config).is_some(),
                description: config.description.clone(),
            })
            .collect()
    }

    pub fn get(&self, name: &str) -> Option<&RemoteHostConfig> {
        self.hosts.get(name)
    }

    pub fn connect(&self, name: &str) -> Result<WireRpcClient<HttpRpcTransport>> {
        let config = self
            .get(name)
            .ok_or_else(|| anyhow!("unknown Triage host {name:?}"))?;
        let transport = HttpRpcTransport::new(config)?;
        Ok(WireRpcClient::new(transport))
    }
}

fn resolved_client_id(config: &RemoteHostConfig) -> String {
    config
        .client_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(DEFAULT_CLIENT_ID)
        .to_string()
}

fn resolve_token(config: &RemoteHostConfig) -> Option<String> {
    if let Some(env_name) = config
        .token_env
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        && let Ok(env_val) = std::env::var(env_name)
    {
        let trimmed = env_val.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }
    config
        .token
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

#[derive(Clone)]
pub struct HttpRpcTransport {
    rpc_url: String,
    client_id: String,
    token: Option<String>,
    runtime: Arc<tokio::runtime::Runtime>,
    client: reqwest::Client,
}

impl HttpRpcTransport {
    pub fn new(config: &RemoteHostConfig) -> Result<Self> {
        let base = config.url.trim().trim_end_matches('/');
        if !(base.starts_with("http://") || base.starts_with("https://")) {
            bail!("remote host URL must use http:// or https://");
        }
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .context("creating async HTTP runtime for remote Triage RPC")?;
        let client = reqwest::Client::builder()
            .build()
            .context("initializing HTTP client for remote Triage RPC")?;
        Ok(Self {
            rpc_url: format!("{base}{REMOTE_RPC_PATH}"),
            client_id: resolved_client_id(config),
            token: resolve_token(config),
            runtime: Arc::new(runtime),
            client,
        })
    }
}

impl WireRpcTransport for HttpRpcTransport {
    fn round_trip_json(&self, request_json: &[u8], extra_timeout: Duration) -> Result<Vec<u8>> {
        let timeout = BASE_RPC_TIMEOUT.saturating_add(extra_timeout);
        let url = self.rpc_url.clone();
        let body = request_json.to_vec();
        let client_id = self.client_id.clone();
        let token = self.token.clone();
        let client = self.client.clone();

        self.runtime.block_on(async move {
            let mut req = client
                .post(&url)
                .timeout(timeout)
                .header(CONTENT_TYPE, "application/json")
                .header("x-triage-client-id", client_id);
            if let Some(token) = token {
                req = req.header(AUTHORIZATION, format!("Bearer {token}"));
            }
            let response = req
                .body(body)
                .send()
                .await
                .with_context(|| format!("sending remote RPC request to {url}"))?;
            let status = response.status();
            let bytes = response
                .bytes()
                .await
                .with_context(|| format!("reading remote RPC response from {url}"))?;
            if !status.is_success() {
                if let Ok(err_json) = serde_json::from_slice::<serde_json::Value>(&bytes)
                    && let Some(msg) = err_json
                        .get("error")
                        .and_then(|err| err.get("message"))
                        .and_then(|msg| msg.as_str())
                {
                    bail!("remote host RPC error ({status}): {msg}");
                }
                bail!(
                    "remote host RPC error ({status}): {}",
                    String::from_utf8_lossy(&bytes)
                );
            }
            Ok(bytes.to_vec())
        })
    }
}
