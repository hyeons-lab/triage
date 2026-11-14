use std::collections::{BTreeMap, HashSet};
use std::io::Write;

use super::{ManagedSession, SessionManager, new_session_instance, replace_manifest};
use anyhow::{Context, Result, anyhow, ensure};
use serde::{Deserialize, Serialize};
use triage_core::session::{SessionId, StartSessionRequest};
use triage_core::workers::*;

const MAX_REGISTRY_BYTES: usize = 32 * 1024 * 1024;
const MAX_GROUPS: usize = 256;
const CLEANUP_RESERVE_BYTES: usize = 1024 * 1024;
const CLEANUP_BUDGET: std::time::Duration = std::time::Duration::from_secs(5);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct WorkerRegistry {
    version: u32,
    groups: Vec<WorkerGroup>,
    launches: BTreeMap<String, WorkerProfile>,
}

impl WorkerRegistry {
    pub(super) fn load(log_dir: &std::path::Path) -> Result<Self> {
        let path = log_dir.join("worker-groups.json");
        let file = match std::fs::File::open(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                std::fs::File::open(path.with_extension("json.bak"))
            }
            other => other,
        };
        match file {
            Ok(file) => {
                use std::io::Read;
                let mut bytes = Vec::new();
                file.take(MAX_REGISTRY_BYTES as u64 + 1)
                    .read_to_end(&mut bytes)?;
                ensure!(
                    bytes.len() <= MAX_REGISTRY_BYTES,
                    "worker registry is too large"
                );
                let value: Self =
                    serde_json::from_slice(&bytes).context("decoding worker registry")?;
                ensure!(value.version == 1, "unsupported worker registry version");
                Ok(value)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self {
                version: 1,
                groups: Vec::new(),
                launches: BTreeMap::new(),
            }),
            Err(e) => Err(e).context("opening worker registry"),
        }
    }

    fn group_index(&self, id: &str) -> Result<usize> {
        self.groups
            .iter()
            .position(|g| g.group_id == id)
            .context("worker group not found")
    }
}

impl SessionManager {
    fn save_workers(&self, current: &mut WorkerRegistry, next: WorkerRegistry) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(&next)?;
        ensure!(
            bytes.len() <= MAX_REGISTRY_BYTES,
            "worker registry capacity exceeded"
        );
        let path = self.config.log_dir.join("worker-groups.json");
        let temp = self
            .config
            .log_dir
            .join(format!(".workers-{}.tmp", new_session_instance()));
        let result = (|| -> Result<()> {
            std::fs::create_dir_all(&self.config.log_dir)?;
            super::set_private_dir_permissions(&self.config.log_dir);
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            if let Err(error) = replace_manifest(&temp, &path) {
                // Windows can commit the replacement and then fail removing its backup.
                // Once the desired bytes are authoritative, memory must advance with disk.
                if std::fs::read(&path).ok().as_deref() != Some(bytes.as_slice()) {
                    return Err(error);
                }
                tracing::warn!(%error, "worker registry committed; backup cleanup remains pending");
                let _ = std::fs::remove_file(&temp);
            }
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temp);
        }
        result.with_context(|| format!("persisting worker registry {}", path.display()))?;
        *current = next;
        Ok(())
    }

    #[cfg(unix)]
    pub(super) fn reload_workers(&self) {
        let mut guard = self
            .worker_registry
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        *guard = WorkerRegistry::load(&self.config.log_dir).map_err(|e| format!("{e:#}"));
    }

    fn reserve_worker_capacity(&self, next: &WorkerRegistry) -> Result<()> {
        ensure!(
            serde_json::to_vec_pretty(next)?.len() <= MAX_REGISTRY_BYTES - CLEANUP_RESERVE_BYTES,
            "worker registry admission capacity exceeded; cleanup headroom is reserved"
        );
        Ok(())
    }

    fn worker_profiles(&self) -> Result<BTreeMap<String, WorkerProfile>> {
        let profiles = if let Some(profiles) = &self.config.worker_profiles {
            profiles.clone()
        } else {
            let path = triage_core::config::Config::default_path()?;
            if path.exists() {
                triage_core::config::Config::load_from_path(path)?
                    .workers
                    .profiles
            } else {
                BTreeMap::new()
            }
        };
        WorkersConfig {
            profiles: profiles.clone(),
        }
        .validate()?;
        Ok(profiles)
    }

    fn current_identity(&self, id: &SessionId, require_live: bool) -> Result<SessionIdentity> {
        ensure!(
            !self.session_awaits_adoption(id),
            "parent session is awaiting adoption"
        );
        let sessions = self.sessions()?;
        let session = sessions.get(id).context("parent session not found")?;
        if require_live {
            ensure!(
                matches!(session, ManagedSession::Live { .. }),
                "parent session is not live"
            );
        }
        let identity = SessionIdentity {
            session_id: id.clone(),
            instance_id: session.instance_id().to_owned(),
        };
        // Upgrade old manifests before a group starts depending on a generated identity.
        self.persist_manifest(&sessions)?;
        drop(sessions);
        if require_live {
            ensure!(
                self.worker_liveness(&identity)? == Some(false),
                "parent session is exited, absent, or temporarily unavailable"
            );
        }
        Ok(identity)
    }

    fn identity_exists(&self, identity: &SessionIdentity) -> Result<bool> {
        Ok(self
            .sessions()?
            .get(&identity.session_id)
            .is_some_and(|s| s.instance_id() == identity.instance_id))
    }

    fn worker_liveness(&self, identity: &SessionIdentity) -> Result<Option<bool>> {
        if self.session_awaits_adoption(&identity.session_id) {
            return Ok(None);
        }
        let sessions = self.sessions()?;
        Ok(match sessions.get(&identity.session_id) {
            Some(s) if s.instance_id() == identity.instance_id => match s {
                ManagedSession::Live { actor, .. } => {
                    if actor
                        .child_exited
                        .load(std::sync::atomic::Ordering::Relaxed)
                    {
                        Some(true)
                    } else if actor
                        .worker
                        .as_ref()
                        .is_some_and(std::thread::JoinHandle::is_finished)
                    {
                        None
                    } else {
                        Some(false)
                    }
                }
                ManagedSession::Historical { .. } => Some(true),
                ManagedSession::Restoring { .. } => None,
            },
            _ => None,
        })
    }

    fn observed_groups(&self, groups: &[WorkerGroup]) -> Result<Vec<WorkerGroup>> {
        let mut observed = groups.to_vec();
        for group in &mut observed {
            for worker in &mut group.workers {
                worker.session_exited = self.worker_liveness(&worker.session)?;
            }
        }
        Ok(observed)
    }

    fn observed_group(&self, group: &WorkerGroup) -> Result<WorkerGroup> {
        self.observed_groups(std::slice::from_ref(group))?
            .pop()
            .context("group observation missing")
    }

    pub(super) fn manage_workers(&self, request: WorkerRequest) -> Result<WorkerResponse> {
        request.validate()?;
        let mut guard = self
            .worker_registry
            .lock()
            .map_err(|_| anyhow!("worker registry lock poisoned"))?;
        ensure!(
            !self.handover_in_flight(),
            "a handover is in progress; retry after the daemon swap"
        );
        let registry = guard
            .as_mut()
            .map_err(|e| anyhow!("worker registry unavailable: {e}"))?;
        match request {
            WorkerRequest::Profiles => Ok(WorkerResponse::Profiles(self.worker_profiles()?)),
            WorkerRequest::List => Ok(WorkerResponse::Groups(
                self.observed_groups(&registry.groups)?,
            )),
            WorkerRequest::Get { group_id } => {
                let i = registry.group_index(&group_id)?;
                Ok(WorkerResponse::Group(
                    self.observed_group(&registry.groups[i])?,
                ))
            }
            WorkerRequest::Create(request) => {
                let parent = self.current_identity(&request.parent_session_id, true)?;
                // A helper's children inherit its group, regardless of the topic it proposes.
                if let Some(group) = registry
                    .groups
                    .iter()
                    .find(|g| g.workers.iter().any(|w| w.session == parent))
                {
                    ensure!(
                        group.phase == WorkerGroupPhase::Open,
                        "worker group is closing or closed"
                    );
                    return Ok(WorkerResponse::Group(self.observed_group(group)?));
                }
                if let Some(group) = registry
                    .groups
                    .iter()
                    .find(|g| g.root == parent && g.key == request.key)
                {
                    ensure!(
                        group.topic == request.topic,
                        "group key already used for a different topic"
                    );
                    return Ok(WorkerResponse::Group(self.observed_group(group)?));
                }
                ensure!(
                    registry.groups.len() < MAX_GROUPS,
                    "worker group capacity exceeded"
                );
                let group = WorkerGroup {
                    group_id: format!("group-{}", new_session_instance()),
                    key: request.key,
                    root: parent,
                    topic: request.topic,
                    phase: WorkerGroupPhase::Open,
                    created_at_ms: std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)?
                        .as_millis()
                        .try_into()?,
                    workers: Vec::new(),
                };
                let mut next = registry.clone();
                next.groups.push(group.clone());
                self.reserve_worker_capacity(&next)?;
                self.save_workers(registry, next)?;
                Ok(WorkerResponse::Group(group))
            }
            WorkerRequest::Spawn(request) => self.spawn_group_worker(registry, request),
            WorkerRequest::Update(request) => {
                let i = registry.group_index(&request.group_id)?;
                let j = registry.groups[i]
                    .workers
                    .iter()
                    .position(|w| w.task_id == request.task_id)
                    .context("worker task not found")?;
                let worker = &registry.groups[i].workers[j];
                ensure!(
                    worker.session.session_id == request.session_id,
                    "update session does not own this task"
                );
                if worker.phase == request.phase && worker.result == request.result {
                    return Ok(WorkerResponse::Worker(worker.clone()));
                }
                ensure!(
                    self.identity_exists(&worker.session)?,
                    "worker session ownership is no longer present"
                );
                ensure!(
                    !worker.phase.is_terminal() && !worker.session_closed,
                    "worker task is already terminal"
                );
                ensure!(
                    registry.groups[i].phase == WorkerGroupPhase::Open,
                    "worker group is closing or closed"
                );
                let valid = matches!(
                    (worker.phase, request.phase),
                    (
                        WorkerPhase::Launched | WorkerPhase::Launching,
                        WorkerPhase::Ready | WorkerPhase::Failed
                    ) | (
                        WorkerPhase::Ready,
                        WorkerPhase::Running | WorkerPhase::Failed
                    ) | (
                        WorkerPhase::Running,
                        WorkerPhase::Succeeded | WorkerPhase::Failed
                    )
                );
                ensure!(
                    valid,
                    "invalid worker phase transition; report ready, then running, then a terminal result"
                );
                let mut next = registry.clone();
                let worker = &mut next.groups[i].workers[j];
                worker.phase = request.phase;
                worker.result = request.result;
                worker.launch_error = None;
                let response = worker.clone();
                next.launches.remove(&request.task_id);
                self.reserve_worker_capacity(&next)?;
                self.save_workers(registry, next)?;
                Ok(WorkerResponse::Worker(response))
            }
            WorkerRequest::Cleanup(request) => self.cleanup_worker_group(registry, request),
        }
    }

    fn spawn_group_worker(
        &self,
        registry: &mut WorkerRegistry,
        request: SpawnWorker,
    ) -> Result<WorkerResponse> {
        let i = registry.group_index(&request.group_id)?;
        let existing = registry.groups[i]
            .workers
            .iter()
            .position(|w| w.key == request.key);
        let j = if let Some(j) = existing {
            let w = &registry.groups[i].workers[j];
            ensure!(
                w.parent.session_id == request.parent_session_id
                    && w.profile == request.profile
                    && w.cwd == request.cwd
                    && w.task == request.task,
                "worker key already used for a different request"
            );
            if w.phase != WorkerPhase::Launching || w.session_closed {
                return Ok(WorkerResponse::Worker(w.clone()));
            }
            j
        } else {
            ensure!(
                registry.groups[i].phase == WorkerGroupPhase::Open,
                "worker group is closing or closed"
            );
            ensure!(
                registry.groups[i].workers.len() < MAX_WORKERS_PER_GROUP,
                "worker group capacity exceeded"
            );
            let parent = self.current_identity(&request.parent_session_id, true)?;
            let group = &registry.groups[i];
            ensure!(
                group.root == parent
                    || group.workers.iter().any(|w| w.session == parent
                        && !w.session_closed
                        && !w.phase.is_terminal()),
                "parent does not belong to this open group"
            );
            let profile = self.worker_profiles()?.remove(&request.profile).context(
                "worker profile not configured; list_worker_profiles shows available profiles",
            )?;
            let task_id = format!("task-{}", new_session_instance());
            let worker = WorkerTask {
                task_id: task_id.clone(),
                key: request.key,
                session: SessionIdentity {
                    session_id: SessionId::new(format!("worker-{}", new_session_instance()))?,
                    instance_id: new_session_instance(),
                },
                parent,
                profile: request.profile,
                cwd: request.cwd,
                task: request.task,
                phase: WorkerPhase::Launching,
                result: None,
                launch_error: None,
                session_closed: false,
                session_exited: None,
            };
            let mut next = registry.clone();
            next.launches.insert(task_id, profile);
            next.groups[i].workers.push(worker);
            self.reserve_worker_capacity(&next)?;
            let j = next.groups[i].workers.len() - 1;
            self.save_workers(registry, next)?;
            j
        };
        let worker = registry.groups[i].workers[j].clone();
        if !self.identity_exists(&worker.session)? {
            ensure!(
                !self.session_awaits_adoption(&worker.session.session_id),
                "worker is awaiting inherited PTY adoption; retry launch later"
            );
            ensure!(
                !self.sessions()?.contains_key(&worker.session.session_id),
                "reserved worker session ID belongs to another incarnation; refusing launch"
            );
            ensure!(
                registry.groups[i].phase == WorkerGroupPhase::Open,
                "worker group is closing or closed"
            );
            let current_parent = self.current_identity(&worker.parent.session_id, true)?;
            ensure!(
                current_parent == worker.parent,
                "parent ownership changed; refusing worker launch"
            );
            let profile = registry
                .launches
                .get(&worker.task_id)
                .context("worker launch intention is missing")?;
            let group = &registry.groups[i];
            let bootstrap = format!(
                "You are a helper in a managed Triage worker group.\nGroup: {}\nTopic: {}\nTask ID: {}\nYour session: {}\nImmediate parent: {}\nRoot session: {}\n\nUse Triage MCP update_worker (or run triage-mcp worker-update <group-id> <task-id> <phase> [--result-file <path>] inside this session; add --socket for a custom daemon) to report ready after reading this task, running before work, and succeeded or failed with a durable result when finished. Include group_id, task_id, and session_id from above. Do not treat terminal output as a result. Keep the session available for follow-up mail. Nested helpers must use this group and your session as parent. Poll and acknowledge direct messages. Do not remove working directories.\n\nTask:\n{}",
                group.group_id,
                group.topic,
                worker.task_id,
                worker.session.session_id,
                worker.parent.session_id,
                group.root.session_id,
                worker.task
            );
            let mut start = StartSessionRequest::new(&profile.command);
            start.args = profile
                .args
                .iter()
                .map(|arg| arg.replace("{prompt}", &bootstrap))
                .collect();
            start.cwd = Some(worker.cwd.clone());
            if let Err(error) = self.start_session_inner(start, Some(worker.session.clone())) {
                let mut next = registry.clone();
                next.groups[i].workers[j].launch_error = Some(format!("{error:#}"));
                self.reserve_worker_capacity(&next)?;
                self.save_workers(registry, next)?;
                return Err(error)
                    .context("launch failed; retry the identical worker key to reconcile");
            }
        }
        let mut next = registry.clone();
        next.groups[i].workers[j].phase = WorkerPhase::Launched;
        next.groups[i].workers[j].launch_error = None;
        next.launches.remove(&worker.task_id);
        let response = next.groups[i].workers[j].clone();
        self.save_workers(registry, next)
            .context("worker may be running; retry the identical key to reconcile")?;
        Ok(WorkerResponse::Worker(response))
    }

    fn cleanup_worker_group(
        &self,
        registry: &mut WorkerRegistry,
        request: CleanupWorkerGroup,
    ) -> Result<WorkerResponse> {
        let i = registry.group_index(&request.group_id)?;
        let group = &registry.groups[i];
        let mut selected = HashSet::new();
        if let Some(id) = &request.subtree_session_id {
            ensure!(
                group.workers.iter().any(|w| w.session.session_id == *id),
                "subtree must be a worker in this group; root cleanup is forbidden"
            );
            selected.insert(id.clone());
            loop {
                let previous = selected.len();
                for worker in &group.workers {
                    if selected.contains(&worker.parent.session_id) {
                        selected.insert(worker.session.session_id.clone());
                    }
                }
                if previous == selected.len() {
                    break;
                }
            }
        } else {
            selected.extend(group.workers.iter().map(|w| w.session.session_id.clone()));
        }
        let mut next = registry.clone();
        if request.subtree_session_id.is_none() {
            next.groups[i].phase = WorkerGroupPhase::Closing;
        }
        for worker in &mut next.groups[i].workers {
            if selected.contains(&worker.session.session_id) && !worker.phase.is_terminal() {
                worker.phase = WorkerPhase::Cancelled;
            }
        }
        for worker in &next.groups[i].workers {
            if selected.contains(&worker.session.session_id) {
                next.launches.remove(&worker.task_id);
            }
        }
        // Commit cancellation before terminating processes so failed cleanup is safely retryable.
        self.save_workers(registry, next)?;
        let mut closed = Vec::new();
        let mut errors = BTreeMap::new();
        let deadline = std::time::Instant::now() + CLEANUP_BUDGET;
        let mut next = registry.clone();
        for j in (0..registry.groups[i].workers.len()).rev() {
            let worker = &registry.groups[i].workers[j];
            if !selected.contains(&worker.session.session_id) || worker.session_closed {
                continue;
            }
            let identity = worker.session.clone();
            if self.session_awaits_adoption(&identity.session_id) {
                errors.insert(
                    identity.session_id.to_string(),
                    "worker is awaiting inherited PTY adoption; retry cleanup later".into(),
                );
                continue;
            }
            if std::time::Instant::now() >= deadline {
                errors.insert(
                    identity.session_id.to_string(),
                    "cleanup time budget exhausted; retry cleanup".into(),
                );
                continue;
            }
            if self.identity_exists(&identity)? {
                if let Err(e) = self.shutdown_session_inner(
                    identity.session_id.clone(),
                    Some(&identity.instance_id),
                    Some(deadline),
                ) {
                    errors.insert(identity.session_id.to_string(), format!("{e:#}"));
                    continue;
                }
                closed.push(identity.session_id.clone());
            }
            next.groups[i].workers[j].session_closed = true;
        }
        if request.subtree_session_id.is_none()
            && next.groups[i].workers.iter().all(|w| w.session_closed)
        {
            next.groups[i].phase = WorkerGroupPhase::Closed;
        }
        self.save_workers(registry, next)?;
        let group = self.observed_group(&registry.groups[i])?;
        let retained_directories = group
            .workers
            .iter()
            .map(|w| w.cwd.clone())
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        Ok(WorkerResponse::Cleanup(WorkerCleanupReport {
            group,
            closed,
            errors,
            retained_directories,
        }))
    }
}

#[cfg(all(test, unix))]
mod tests;
