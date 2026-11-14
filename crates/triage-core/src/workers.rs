//! Managed cross-runtime worker sessions and durable task results.

use std::collections::BTreeMap;
use std::path::PathBuf;

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

use crate::session::SessionId;

pub const MAX_WORKERS_PER_GROUP: usize = 128;
pub const MAX_WORKER_TEXT_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkerProfile {
    pub command: String,
    pub args: Vec<String>,
}

impl WorkerProfile {
    pub fn validate(&self) -> Result<()> {
        text(&self.command, 4096, "profile command")?;
        ensure!(self.args.len() <= 128, "profile has too many arguments");
        ensure!(
            self.args.iter().map(String::len).sum::<usize>() <= 64 * 1024,
            "profile arguments are too large"
        );
        let mut prompts = 0;
        for arg in &self.args {
            ensure!(
                arg.len() <= 8192 && !arg.contains('\0'),
                "invalid profile argument"
            );
            prompts += arg.matches("{prompt}").count();
        }
        ensure!(
            prompts == 1,
            "profile args must contain exactly one {{prompt}} placeholder"
        );
        Ok(())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct WorkersConfig {
    pub profiles: BTreeMap<String, WorkerProfile>,
}

impl WorkersConfig {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.profiles.len() <= 32, "too many worker profiles");
        for (name, profile) in &self.profiles {
            key(name)?;
            profile.validate()?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionIdentity {
    pub session_id: SessionId,
    pub instance_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerPhase {
    Launching,
    Launched,
    Ready,
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

impl WorkerPhase {
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerGroupPhase {
    Open,
    Closing,
    Closed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerTask {
    pub task_id: String,
    pub key: String,
    pub session: SessionIdentity,
    pub parent: SessionIdentity,
    pub profile: String,
    pub cwd: PathBuf,
    pub task: String,
    pub phase: WorkerPhase,
    pub result: Option<String>,
    pub launch_error: Option<String>,
    pub session_closed: bool,
    /// Observed when status is read; `None` means absent or temporarily unavailable.
    #[serde(default)]
    pub session_exited: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerGroup {
    pub group_id: String,
    pub key: String,
    pub root: SessionIdentity,
    pub topic: String,
    pub phase: WorkerGroupPhase,
    pub created_at_ms: u64,
    pub workers: Vec<WorkerTask>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateWorkerGroup {
    pub parent_session_id: SessionId,
    pub key: String,
    pub topic: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SpawnWorker {
    pub group_id: String,
    pub parent_session_id: SessionId,
    pub key: String,
    pub profile: String,
    pub cwd: PathBuf,
    pub task: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateWorker {
    pub group_id: String,
    pub task_id: String,
    pub session_id: SessionId,
    pub phase: WorkerPhase,
    #[serde(
        default,
        deserialize_with = "present_option",
        skip_serializing_if = "Option::is_none"
    )]
    pub result: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CleanupWorkerGroup {
    pub group_id: String,
    /// When set, close this worker and its descendants, preserving the root and siblings.
    #[serde(
        default,
        deserialize_with = "present_option",
        skip_serializing_if = "Option::is_none"
    )]
    pub subtree_session_id: Option<SessionId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerCleanupReport {
    pub group: WorkerGroup,
    pub closed: Vec<SessionId>,
    pub errors: BTreeMap<String, String>,
    /// Working directories are always retained, including modified or unintegrated worktrees.
    pub retained_directories: Vec<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkerRequest {
    Profiles,
    Create(CreateWorkerGroup),
    List,
    Get { group_id: String },
    Spawn(SpawnWorker),
    Update(UpdateWorker),
    Cleanup(CleanupWorkerGroup),
}

impl WorkerRequest {
    pub fn validate(&self) -> Result<()> {
        match self {
            Self::Profiles | Self::List => {}
            Self::Get { group_id } => key(group_id)?,
            Self::Create(r) => {
                SessionId::new(r.parent_session_id.as_str())?;
                key(&r.key)?;
                text(&r.topic, 1024, "topic")?;
            }
            Self::Spawn(r) => {
                key(&r.group_id)?;
                key(&r.key)?;
                key(&r.profile)?;
                SessionId::new(r.parent_session_id.as_str())?;
                ensure!(r.cwd.is_absolute(), "cwd must be absolute");
                text(&r.cwd.to_string_lossy(), 4096, "cwd")?;
                text(&r.task, MAX_WORKER_TEXT_BYTES, "task")?;
            }
            Self::Update(r) => {
                key(&r.group_id)?;
                key(&r.task_id)?;
                SessionId::new(r.session_id.as_str())?;
                ensure!(
                    matches!(
                        r.phase,
                        WorkerPhase::Ready
                            | WorkerPhase::Running
                            | WorkerPhase::Succeeded
                            | WorkerPhase::Failed
                    ),
                    "workers may report ready, running, succeeded, or failed"
                );
                if let Some(result) = &r.result {
                    text(result, MAX_WORKER_TEXT_BYTES, "result")?;
                }
                ensure!(
                    !r.phase.is_terminal() || r.result.is_some(),
                    "terminal updates require a result"
                );
            }
            Self::Cleanup(r) => {
                key(&r.group_id)?;
                if let Some(id) = &r.subtree_session_id {
                    SessionId::new(id.as_str())?;
                }
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkerResponse {
    Profiles(BTreeMap<String, WorkerProfile>),
    Group(WorkerGroup),
    Groups(Vec<WorkerGroup>),
    Worker(WorkerTask),
    Cleanup(WorkerCleanupReport),
}

fn present_option<'de, D, T>(deserializer: D) -> std::result::Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}

pub fn key(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.')),
        "keys must be 1..128 ASCII letters, digits, dots, hyphens, or underscores"
    );
    Ok(())
}

fn text(value: &str, max: usize, name: &str) -> Result<()> {
    ensure!(
        !value.trim().is_empty() && value.len() <= max && !value.contains('\0'),
        "{name} must be nonblank, at most {max} bytes, and contain no NUL"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cleanup_omission_round_trips_without_accepting_explicit_null() {
        let request = CleanupWorkerGroup {
            group_id: "group-a".into(),
            subtree_session_id: None,
        };
        let json = serde_json::to_value(&request).unwrap();
        assert!(json.get("subtree_session_id").is_none());
        assert_eq!(
            serde_json::from_value::<CleanupWorkerGroup>(json).unwrap(),
            request
        );
        assert!(
            serde_json::from_str::<CleanupWorkerGroup>(
                r#"{"group_id":"group-a","subtree_session_id":null}"#
            )
            .is_err()
        );
    }
    #[test]
    fn worker_profiles_require_one_prompt_and_bounded_literal_arguments() {
        let mut profile = WorkerProfile {
            command: "helper".into(),
            args: vec!["{prompt}".into()],
        };
        profile.validate().unwrap();
        profile.args.push("{prompt}".into());
        assert!(profile.validate().is_err());
        profile.args = vec!["no bootstrap".into()];
        assert!(profile.validate().is_err());
        profile.args = vec!["{prompt}\0".into()];
        assert!(profile.validate().is_err());
        profile.args = vec!["{prompt}".into(), "x".repeat(8193)];
        assert!(profile.validate().is_err());
    }
}
