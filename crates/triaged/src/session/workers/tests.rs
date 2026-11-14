use super::super::SessionManagerConfig;
use super::*;
use std::path::PathBuf;
use std::sync::Arc;
use triage_core::session::SessionApi;

struct Harness {
    manager: Arc<SessionManager>,
    dir: PathBuf,
    root: SessionId,
}

impl Harness {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("triage-workers-{}", new_session_instance()));
        std::fs::create_dir_all(&dir).unwrap();
        let dir = std::fs::canonicalize(&dir).unwrap();
        let mut config = SessionManagerConfig::new(&dir);
        config.worker_profiles = Some(BTreeMap::from([(
            "test".into(),
            WorkerProfile {
                command: "/bin/sh".into(),
                args: vec![
                    "-c".into(),
                    "printf '%s\\n' \"$1\"; exec /bin/cat".into(),
                    "worker".into(),
                    "{prompt}".into(),
                ],
            },
        )]));
        let manager = Arc::new(SessionManager::new(config));
        let mut start = StartSessionRequest::new("/bin/cat");
        start.cwd = Some(dir.clone());
        let root = manager.start_session(start).unwrap();
        Self { manager, dir, root }
    }
    fn group(&self) -> WorkerGroup {
        match self
            .manager
            .worker_operation(WorkerRequest::Create(CreateWorkerGroup {
                parent_session_id: self.root.clone(),
                key: "review".into(),
                topic: "Review a change".into(),
            }))
            .unwrap()
        {
            WorkerResponse::Group(g) => g,
            _ => panic!("expected group"),
        }
    }
    fn request(&self, group: &WorkerGroup, key: &str, parent: &SessionId) -> SpawnWorker {
        SpawnWorker {
            group_id: group.group_id.clone(),
            parent_session_id: parent.clone(),
            key: key.into(),
            profile: "test".into(),
            cwd: self.dir.clone(),
            task: "Inspect the implementation and report findings.".into(),
        }
    }
    fn spawn(&self, request: SpawnWorker) -> WorkerTask {
        match self
            .manager
            .worker_operation(WorkerRequest::Spawn(request))
            .unwrap()
        {
            WorkerResponse::Worker(w) => w,
            _ => panic!("expected worker"),
        }
    }
    fn update(
        &self,
        group: &WorkerGroup,
        worker: &WorkerTask,
        phase: WorkerPhase,
        result: Option<&str>,
    ) -> Result<WorkerResponse> {
        self.manager
            .worker_operation(WorkerRequest::Update(UpdateWorker {
                group_id: group.group_id.clone(),
                task_id: worker.task_id.clone(),
                session_id: worker.session.session_id.clone(),
                phase,
                result: result.map(str::to_owned),
            }))
    }
    fn cleanup(&self, group: &WorkerGroup, subtree: Option<SessionId>) -> WorkerCleanupReport {
        match self
            .manager
            .worker_operation(WorkerRequest::Cleanup(CleanupWorkerGroup {
                group_id: group.group_id.clone(),
                subtree_session_id: subtree,
            }))
            .unwrap()
        {
            WorkerResponse::Cleanup(r) => r,
            _ => panic!("expected cleanup"),
        }
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        for id in self.manager.list_sessions().unwrap_or_default() {
            let _ = self.manager.shutdown_session(id);
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn managed_workers_bootstrap_nest_report_and_cleanup_without_deleting_work() {
    fn assert_bootstrap_received(
        h: &Harness,
        group: &WorkerGroup,
        worker: &WorkerTask,
        task: &str,
        parent: &SessionId,
    ) {
        use std::time::{Duration, Instant};

        let actor_tx = {
            let sessions = h.manager.sessions().unwrap();
            let Some(ManagedSession::Live { actor, .. }) = sessions.get(&worker.session.session_id)
            else {
                panic!("expected live worker for bootstrap receipt");
            };
            actor.tx.clone()
        };
        let metadata = format!(
            "Group: {}\nTopic: {}\nTask ID: {}\nYour session: {}\nImmediate parent: {}\nRoot session: {}\n",
            group.group_id,
            group.topic,
            worker.task_id,
            worker.session.session_id,
            parent,
            group.root.session_id,
        );
        let task_block = format!("\nTask:\n{task}\n");
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let (response, received) = std::sync::mpsc::channel();
            actor_tx
                .send(super::super::ActorCommand::SnapshotWithHistory {
                    history_cap: 64 * 1024,
                    response,
                })
                .unwrap();
            let snapshot = received
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .expect("timed out reading the child's bootstrap receipt")
                .unwrap();
            let output = String::from_utf8(snapshot.raw_output)
                .expect("bootstrap output must be UTF-8")
                .replace("\r\n", "\n");
            if output.contains(&metadata) && output.contains(&task_block) {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "child did not receive the exact bootstrap metadata and task: {output:?}"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    let h = Harness::new();
    let group = h.group();
    assert_eq!(h.group().group_id, group.group_id);
    let mut request = h.request(&group, "reviewer", &h.root);
    let literal_task = "Keep literal $(touch INJECTED) and `touch INJECTED2` text.";
    request.task = literal_task.into();
    let worker = h.spawn(request.clone());
    assert_eq!(h.spawn(request), worker);
    assert_bootstrap_received(&h, &group, &worker, literal_task, &h.root);
    let nested = match h
        .manager
        .worker_operation(WorkerRequest::Create(CreateWorkerGroup {
            parent_session_id: worker.session.session_id.clone(),
            key: "nested".into(),
            topic: "A subproblem".into(),
        }))
        .unwrap()
    {
        WorkerResponse::Group(g) => g,
        _ => panic!(),
    };
    assert_eq!(nested.group_id, group.group_id);
    let child_request = h.request(&group, "child", &worker.session.session_id);
    let child_task = child_request.task.clone();
    let child = h.spawn(child_request);
    assert_eq!(child.parent, worker.session);
    assert_bootstrap_received(&h, &group, &child, &child_task, &worker.session.session_id);
    h.update(&group, &worker, WorkerPhase::Ready, None).unwrap();
    h.update(&group, &worker, WorkerPhase::Running, None)
        .unwrap();
    h.update(
        &group,
        &worker,
        WorkerPhase::Succeeded,
        Some("No findings. Retain the worktree for integration."),
    )
    .unwrap();
    h.update(
        &group,
        &worker,
        WorkerPhase::Succeeded,
        Some("No findings. Retain the worktree for integration."),
    )
    .unwrap();
    assert!(
        h.update(&group, &worker, WorkerPhase::Running, None)
            .is_err()
    );
    std::fs::write(h.dir.join("unintegrated.txt"), "keep").unwrap();
    let report = h.cleanup(&group, None);
    assert!(report.errors.is_empty());
    assert_eq!(report.closed.len(), 2);
    assert_eq!(report.group.phase, WorkerGroupPhase::Closed);
    assert_eq!(report.group.workers[0].phase, WorkerPhase::Succeeded);
    assert_eq!(report.group.workers[1].phase, WorkerPhase::Cancelled);
    assert!(
        report.group.workers[0]
            .result
            .as_ref()
            .unwrap()
            .contains("No findings")
    );
    assert_eq!(h.manager.list_sessions().unwrap(), vec![h.root.clone()]);
    assert!(h.dir.join("unintegrated.txt").is_file());
    assert!(!h.dir.join("INJECTED").exists());
    assert!(!h.dir.join("INJECTED2").exists());
    assert!(h.cleanup(&group, None).closed.is_empty());
}

#[test]
fn cleanup_subtree_preserves_root_and_siblings() {
    let h = Harness::new();
    let g = h.group();
    let a = h.spawn(h.request(&g, "a", &h.root));
    let b = h.spawn(h.request(&g, "b", &h.root));
    let c = h.spawn(h.request(&g, "c", &a.session.session_id));
    let report = h.cleanup(&g, Some(a.session.session_id.clone()));
    assert_eq!(report.group.phase, WorkerGroupPhase::Open);
    assert_eq!(report.closed.len(), 2);
    assert!(report.closed.contains(&c.session.session_id));
    assert!(h.manager.snapshot_session(b.session.session_id).is_ok());
    assert!(h.manager.snapshot_session(h.root.clone()).is_ok());
    assert!(
        h.manager
            .worker_operation(WorkerRequest::Spawn(h.request(
                &g,
                "late",
                &a.session.session_id
            )))
            .is_err()
    );
    assert!(
        h.manager
            .worker_operation(WorkerRequest::Cleanup(CleanupWorkerGroup {
                group_id: g.group_id,
                subtree_session_id: Some(h.root.clone())
            }))
            .is_err()
    );
}

#[test]
fn retry_key_reconciles_a_launch_committed_before_the_registry_ack() {
    let h = Harness::new();
    let g = h.group();
    let request = h.request(&g, "once", &h.root);
    let w = h.spawn(request.clone());
    {
        let mut guard = h.manager.worker_registry.lock().unwrap();
        let registry = guard.as_mut().unwrap();
        let mut next = registry.clone();
        next.groups[0].workers[0].phase = WorkerPhase::Launching;
        h.manager.save_workers(registry, next).unwrap();
    }
    assert_eq!(h.spawn(request).session, w.session);
    assert_eq!(h.manager.list_sessions().unwrap().len(), 2);
}

#[test]
fn conflicting_key_unknown_profile_and_unrelated_parent_are_rejected() {
    let h = Harness::new();
    let g = h.group();
    let request = h.request(&g, "once", &h.root);
    h.spawn(request.clone());
    let mut different = request;
    different.task = "Different task".into();
    assert!(
        h.manager
            .worker_operation(WorkerRequest::Spawn(different))
            .is_err()
    );
    let mut unknown = h.request(&g, "unknown", &h.root);
    unknown.profile = "unconfigured".into();
    assert!(
        h.manager
            .worker_operation(WorkerRequest::Spawn(unknown))
            .is_err()
    );
    let unrelated = h
        .manager
        .start_session(StartSessionRequest::new("/bin/cat"))
        .unwrap();
    assert!(
        h.manager
            .worker_operation(WorkerRequest::Spawn(h.request(&g, "unrelated", &unrelated)))
            .is_err()
    );
    assert_eq!(h.manager.list_sessions().unwrap().len(), 3);
}

#[test]
fn cleanup_does_not_touch_a_reused_session_id_with_a_different_identity() {
    let h = Harness::new();
    let g = h.group();
    let w = h.spawn(h.request(&g, "a", &h.root));
    h.manager
        .shutdown_session(w.session.session_id.clone())
        .unwrap();
    let replacement = SessionIdentity {
        session_id: w.session.session_id.clone(),
        instance_id: new_session_instance(),
    };
    h.manager
        .start_session_inner(
            StartSessionRequest::new("/bin/cat"),
            Some(replacement.clone()),
        )
        .unwrap();
    let report = h.cleanup(&g, None);
    assert!(report.closed.is_empty());
    assert!(report.group.workers[0].session_closed);
    assert!(h.manager.identity_exists(&replacement).unwrap());
    assert!(
        !h.manager
            .snapshot_session(replacement.session_id)
            .unwrap()
            .exited
    );
}

#[test]
fn durable_results_and_identity_survive_a_cold_restore() {
    let h = Harness::new();
    let g = h.group();
    let w = h.spawn(h.request(&g, "a", &h.root));
    h.update(&g, &w, WorkerPhase::Ready, None).unwrap();
    h.update(&g, &w, WorkerPhase::Running, None).unwrap();
    h.update(&g, &w, WorkerPhase::Succeeded, Some("durable result"))
        .unwrap();
    // A second manager restores only historical data; it never owns these live PTYs.
    let restored = SessionManager::new(SessionManagerConfig::new(&h.dir));
    assert!(restored.identity_exists(&w.session).unwrap());
    let WorkerResponse::Group(restored_group) = restored
        .worker_operation(WorkerRequest::Get {
            group_id: g.group_id,
        })
        .unwrap()
    else {
        panic!()
    };
    assert_eq!(restored_group.root, g.root);
    assert_eq!(
        restored_group.workers[0].result.as_deref(),
        Some("durable result")
    );
    assert_eq!(restored_group.workers[0].session_exited, Some(true));
}

#[test]
fn successor_reloads_group_records_after_predecessor_freezes() {
    let h = Harness::new();
    let successor = SessionManager::new(SessionManagerConfig::new(&h.dir));
    let g = h.group();
    let w = h.spawn(h.request(&g, "a", &h.root));
    let guard = h.manager.begin_handover().unwrap();
    assert!(h.manager.worker_operation(WorkerRequest::List).is_err());
    successor.reload_workers();
    let WorkerResponse::Group(group) = successor
        .worker_operation(WorkerRequest::Get {
            group_id: g.group_id,
        })
        .unwrap()
    else {
        panic!()
    };
    assert_eq!(group.workers[0].session, w.session);
    let serialized = h.manager.serialize_active_sessions().unwrap();
    assert!(
        serialized
            .state
            .sessions
            .iter()
            .any(|s| s.id == w.session.session_id && s.instance_id == w.session.instance_id)
    );
    for fd in serialized.fds {
        unsafe { libc::close(fd) };
    }
    drop(guard);
}

#[test]
fn corrupt_registry_fails_closed_without_affecting_terminal_sessions() {
    let h = Harness::new();
    std::fs::write(h.dir.join("worker-groups.json"), "not json").unwrap();
    let restored = SessionManager::new(SessionManagerConfig::new(&h.dir));
    assert!(
        restored
            .worker_operation(WorkerRequest::List)
            .unwrap_err()
            .to_string()
            .contains("unavailable")
    );
    assert_eq!(restored.list_sessions().unwrap(), vec![h.root.clone()]);
    assert_eq!(
        std::fs::read_to_string(h.dir.join("worker-groups.json")).unwrap(),
        "not json"
    );
}

#[test]
fn failed_cancellation_persistence_does_not_kill_workers() {
    let h = Harness::new();
    let g = h.group();
    let w = h.spawn(h.request(&g, "a", &h.root));
    std::fs::remove_file(h.dir.join("worker-groups.json")).unwrap();
    std::fs::create_dir(h.dir.join("worker-groups.json")).unwrap();
    assert!(
        h.manager
            .worker_operation(WorkerRequest::Cleanup(CleanupWorkerGroup {
                group_id: g.group_id,
                subtree_session_id: None
            }))
            .is_err()
    );
    assert!(
        !h.manager
            .snapshot_session(w.session.session_id)
            .unwrap()
            .exited
    );
}

#[test]
fn concurrent_identical_launches_create_one_session() {
    let h = Harness::new();
    let g = h.group();
    let request = h.request(&g, "once", &h.root);
    let handles = (0..4)
        .map(|_| {
            let manager = h.manager.clone();
            let request = request.clone();
            std::thread::spawn(move || {
                manager
                    .worker_operation(WorkerRequest::Spawn(request))
                    .unwrap()
            })
        })
        .collect::<Vec<_>>();
    let workers = handles
        .into_iter()
        .map(|t| t.join().unwrap())
        .collect::<Vec<_>>();
    assert!(workers.iter().all(|w| *w == workers[0]));
    assert_eq!(h.manager.list_sessions().unwrap().len(), 2);
}

#[test]
fn task_protocol_rejects_out_of_order_and_wrong_session_updates() {
    let h = Harness::new();
    let g = h.group();
    let w = h.spawn(h.request(&g, "a", &h.root));
    assert!(
        h.update(&g, &w, WorkerPhase::Succeeded, Some("too soon"))
            .is_err()
    );
    assert!(
        h.manager
            .worker_operation(WorkerRequest::Update(UpdateWorker {
                group_id: g.group_id.clone(),
                task_id: w.task_id.clone(),
                session_id: h.root.clone(),
                phase: WorkerPhase::Ready,
                result: None
            }))
            .is_err()
    );
    h.update(&g, &w, WorkerPhase::Ready, None).unwrap();
    assert!(h.update(&g, &w, WorkerPhase::Failed, None).is_err());
    h.update(&g, &w, WorkerPhase::Failed, Some("could not load project"))
        .unwrap();
}
#[test]
fn interrupted_registry_rotation_recovers_backup_and_corrupt_primary_fails_closed() {
    let h = Harness::new();
    let g = h.group();
    let primary = h.dir.join("worker-groups.json");
    let backup = primary.with_extension("json.bak");
    std::fs::rename(&primary, &backup).unwrap();
    assert_eq!(
        WorkerRegistry::load(&h.dir).unwrap().groups[0].group_id,
        g.group_id
    );
    std::fs::write(&primary, "corrupt primary").unwrap();
    assert!(WorkerRegistry::load(&h.dir).is_err());
}

#[test]
fn owned_shutdown_refuses_a_changed_incarnation_inside_the_lifecycle_guard() {
    let h = Harness::new();
    let g = h.group();
    let w = h.spawn(h.request(&g, "a", &h.root));
    let error = h
        .manager
        .shutdown_session_inner(
            w.session.session_id.clone(),
            Some("stale-incarnation"),
            Some(std::time::Instant::now() + std::time::Duration::from_secs(1)),
        )
        .unwrap_err();
    assert!(error.to_string().contains("ownership changed"));
    assert!(h.manager.identity_exists(&w.session).unwrap());
    assert_eq!(h.manager.worker_liveness(&w.session).unwrap(), Some(false));
}

#[test]
fn failed_launch_retries_the_saved_profile_and_drops_it_after_acknowledgment() {
    use std::os::unix::fs::PermissionsExt;
    let h = Harness::new();
    let g = h.group();
    let executable = h.dir.join("delayed-helper");
    let mut request = h.request(&g, "delayed", &h.root);
    request.profile = "delayed".into();
    // Inject a profile directly to preserve the same immutable launch request.
    let task = WorkerTask {
        task_id: "task-delayed".into(),
        key: request.key.clone(),
        session: SessionIdentity {
            session_id: SessionId::new("worker-delayed").unwrap(),
            instance_id: new_session_instance(),
        },
        parent: g.root.clone(),
        profile: request.profile.clone(),
        cwd: request.cwd.clone(),
        task: request.task.clone(),
        phase: WorkerPhase::Launching,
        result: None,
        launch_error: None,
        session_closed: false,
        session_exited: None,
    };
    {
        let mut guard = h.manager.worker_registry.lock().unwrap();
        let registry = guard.as_mut().unwrap();
        let mut next = registry.clone();
        next.groups[0].workers.push(task.clone());
        next.launches.insert(
            task.task_id.clone(),
            WorkerProfile {
                command: executable.to_string_lossy().into_owned(),
                args: vec!["{prompt}".into()],
            },
        );
        h.manager.save_workers(registry, next).unwrap();
    }
    assert!(
        h.manager
            .worker_operation(WorkerRequest::Spawn(request.clone()))
            .is_err()
    );
    assert_eq!(h.manager.list_sessions().unwrap(), vec![h.root.clone()]);
    std::fs::write(&executable, "#!/bin/sh\nexec /bin/cat\n").unwrap();
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
    let launched = h.spawn(request);
    assert_eq!(launched.session, task.session);
    assert_eq!(launched.phase, WorkerPhase::Launched);
    assert!(
        !h.manager
            .worker_registry
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .launches
            .contains_key(&task.task_id)
    );
}

#[test]
fn near_admission_capacity_cleanup_still_fits_and_stops_owned_sessions() {
    let h = Harness::new();
    let g = h.group();
    let w = h.spawn(h.request(&g, "a", &h.root));
    {
        let mut guard = h.manager.worker_registry.lock().unwrap();
        let registry = guard.as_mut().unwrap();
        let mut next = registry.clone();
        let mut second = g.clone();
        second.group_id = "group-second".into();
        second.key = "second".into();
        next.groups.push(second);
        for group_index in 0..2 {
            next.groups[group_index].workers.clear();
            for index in 0..MAX_WORKERS_PER_GROUP {
                let mut task = w.clone();
                if group_index != 0 || index != 0 {
                    task.key = format!("ghost-{group_index}-{index}");
                    task.task_id = format!("task-{}", task.key);
                    task.session.session_id =
                        SessionId::new(format!("worker-{}", task.key)).unwrap();
                    task.session.instance_id = new_session_instance();
                }
                task.task = "t".repeat(MAX_WORKER_TEXT_BYTES);
                task.result = Some("r".repeat(MAX_WORKER_TEXT_BYTES));
                task.phase = WorkerPhase::Running;
                next.groups[group_index].workers.push(task);
            }
        }
        let target = MAX_REGISTRY_BYTES - CLEANUP_RESERVE_BYTES;
        let mut excess = serde_json::to_vec_pretty(&next).unwrap().len() - target;
        for group in &mut next.groups {
            for task in &mut group.workers {
                let result = task.result.as_mut().unwrap();
                let remove = excess.min(result.len() - 1);
                result.truncate(result.len() - remove);
                excess -= remove;
            }
        }
        assert_eq!(excess, 0);
        assert_eq!(serde_json::to_vec_pretty(&next).unwrap().len(), target);
        h.manager.reserve_worker_capacity(&next).unwrap();
        let mut too_large = next.clone();
        too_large.groups[0].topic.push('x');
        assert!(h.manager.reserve_worker_capacity(&too_large).is_err());
        h.manager.save_workers(registry, next).unwrap();
    }
    let report = h.cleanup(&g, None);
    assert!(report.errors.is_empty());
    assert_eq!(report.closed, vec![w.session.session_id]);
    assert_eq!(report.group.phase, WorkerGroupPhase::Closed);
    assert_eq!(h.manager.list_sessions().unwrap(), vec![h.root.clone()]);
    assert!(WorkerRegistry::load(&h.dir).is_ok());
}

#[test]
fn terminal_result_retry_survives_group_cleanup() {
    let h = Harness::new();
    let g = h.group();
    let w = h.spawn(h.request(&g, "a", &h.root));
    h.update(&g, &w, WorkerPhase::Ready, None).unwrap();
    h.update(&g, &w, WorkerPhase::Running, None).unwrap();
    h.update(&g, &w, WorkerPhase::Succeeded, Some("saved"))
        .unwrap();
    h.cleanup(&g, None);
    h.update(&g, &w, WorkerPhase::Succeeded, Some("saved"))
        .unwrap();
    assert!(
        h.update(&g, &w, WorkerPhase::Succeeded, Some("changed"))
            .is_err()
    );
}

use std::os::fd::{FromRawFd as _, IntoRawFd as _, OwnedFd as LifecycleOwnedFd};
use std::time::{Duration as LifecycleDuration, Instant as LifecycleInstant};

struct LifecycleFixtureCleanup {
    manager: Arc<SessionManager>,
    fake_ids: Vec<SessionId>,
}

impl LifecycleFixtureCleanup {
    fn new(manager: Arc<SessionManager>) -> Self {
        Self {
            manager,
            fake_ids: Vec::new(),
        }
    }
}

impl Drop for LifecycleFixtureCleanup {
    fn drop(&mut self) {
        for fd in self.manager.take_pending_adoption_fds_for_test() {
            // The drain transfers ownership of each retained descriptor here.
            drop(unsafe { LifecycleOwnedFd::from_raw_fd(fd) });
        }
        for id in &self.fake_ids {
            if let Some(ManagedSession::Live { actor, .. }) =
                self.manager.sessions().unwrap().remove(id)
            {
                actor.detach();
            }
        }
        for id in self.manager.list_sessions().unwrap_or_default() {
            let identity = self
                .manager
                .sessions()
                .unwrap()
                .get(&id)
                .map(|session| session.instance_id().to_owned());
            if let Some(instance) = identity {
                let _ = self.manager.shutdown_session_inner(
                    id,
                    Some(&instance),
                    Some(LifecycleInstant::now() + LifecycleDuration::from_secs(2)),
                );
            }
        }
    }
}

fn lifecycle_group(manager: &SessionManager, id: &str) -> WorkerGroup {
    match manager
        .worker_operation(WorkerRequest::Get {
            group_id: id.to_owned(),
        })
        .unwrap()
    {
        WorkerResponse::Group(group) => group,
        other => panic!("expected group, got {other:?}"),
    }
}

fn lifecycle_install_fake_actor(
    h: &Harness,
    worker: &WorkerTask,
    tx: std::sync::mpsc::Sender<super::super::ActorCommand>,
    handle: Option<std::thread::JoinHandle<()>>,
    exited: Arc<std::sync::atomic::AtomicBool>,
) -> LifecycleFixtureCleanup {
    h.manager
        .shutdown_session(worker.session.session_id.clone())
        .unwrap();
    let log_path = h.dir.join(format!("{}.log", worker.session.session_id));
    std::fs::write(&log_path, b"retained worker output\r\n").unwrap();
    let mut cleanup = LifecycleFixtureCleanup::new(h.manager.clone());
    cleanup.fake_ids.push(worker.session.session_id.clone());
    let replaced = h.manager.sessions().unwrap().insert(
        worker.session.session_id.clone(),
        ManagedSession::Live {
            actor: super::super::SessionActor {
                child_exited: exited,
                tx,
                worker: handle,
                reader: None,
                writer: None,
                last_activity_ms: Arc::new(std::sync::atomic::AtomicU64::new(1)),
                last_input_ms: Arc::new(std::sync::atomic::AtomicU64::new(1)),
            },
            lease: super::super::InputLeaseState::default(),
            launch: super::super::PersistedSessionLaunch {
                instance_id: worker.session.instance_id.clone(),
                command: "/bin/cat".into(),
                args: Vec::new(),
                cwd: Some(h.dir.clone()),
                size: Default::default(),
                log_path,
            },
            last_known_cwd: Some(h.dir.clone()),
            agent: None,
            agent_tracking: false,
            agent_observed: false,
        },
    );
    assert!(replaced.is_none());
    cleanup
}

#[test]
fn lifecycle_queue_and_adopt_preserve_real_worker_identity_and_result() {
    let h = Harness::new();
    let successor = Arc::new(SessionManager::new(SessionManagerConfig::new(&h.dir)));
    let _successor_cleanup = LifecycleFixtureCleanup::new(successor.clone());
    let group = h.group();
    let worker = h.spawn(h.request(&group, "adopted", &h.root));
    h.update(&group, &worker, WorkerPhase::Ready, None).unwrap();
    h.update(&group, &worker, WorkerPhase::Running, None)
        .unwrap();
    h.update(
        &group,
        &worker,
        WorkerPhase::Succeeded,
        Some("result survives the production adoption path"),
    )
    .unwrap();
    let freeze = h.manager.begin_handover().unwrap();
    let serialized = h.manager.serialize_active_sessions().unwrap();
    successor
        .queue_handover_adoptions(serialized.state, serialized.fds)
        .unwrap();
    let retained = {
        let mut pending = successor.pending_adoptions.lock().unwrap();
        std::mem::take(&mut *pending)
    };
    let (sessions, fds) = retained.into_iter().unzip();
    // Drive the production adoption entry directly, avoiding its process-global
    // retry-thread completion hook in a parallel unit-test process.
    successor
        .adopt_sessions(
            crate::handover::HandoverState {
                sessions,
                ..Default::default()
            },
            fds,
        )
        .unwrap();
    successor.refresh_pending_adoption_ids();
    h.manager.detach_all_live_sessions();
    drop(freeze);

    {
        let sessions = successor.sessions().unwrap();
        let adopted = sessions.get(&worker.session.session_id).unwrap();
        assert!(matches!(adopted, ManagedSession::Live { .. }));
        assert_eq!(adopted.instance_id(), worker.session.instance_id);
        assert_eq!(
            sessions[&group.root.session_id].instance_id(),
            group.root.instance_id
        );
    }
    let adopted = lifecycle_group(&successor, &group.group_id);
    assert_eq!(adopted.root, group.root);
    assert_eq!(adopted.workers[0].session, worker.session);
    assert_eq!(adopted.workers[0].parent, worker.parent);
    assert_eq!(adopted.workers[0].phase, WorkerPhase::Succeeded);
    assert_eq!(
        adopted.workers[0].result.as_deref(),
        Some("result survives the production adoption path")
    );
    let WorkerResponse::Cleanup(report) = successor
        .worker_operation(WorkerRequest::Cleanup(CleanupWorkerGroup {
            group_id: group.group_id,
            subtree_session_id: None,
        }))
        .unwrap()
    else {
        panic!("expected cleanup")
    };
    assert!(report.errors.is_empty(), "{:?}", report.errors);
    assert_eq!(report.closed, vec![worker.session.session_id]);
    assert_eq!(report.group.phase, WorkerGroupPhase::Closed);
    assert_eq!(report.group.workers[0].phase, WorkerPhase::Succeeded);
    assert_eq!(successor.list_sessions().unwrap(), vec![h.root.clone()]);
    assert!(h.dir.is_dir());
}

#[test]
fn lifecycle_empty_queue_refreshes_results_loaded_before_the_final_freeze() {
    let h = Harness::new();
    let successor = Arc::new(SessionManager::new(SessionManagerConfig::new(&h.dir)));
    let _successor_cleanup = LifecycleFixtureCleanup::new(successor.clone());
    let group = h.group();
    let worker = h.spawn(h.request(&group, "finished", &h.root));
    h.update(&group, &worker, WorkerPhase::Ready, None).unwrap();
    h.update(&group, &worker, WorkerPhase::Running, None)
        .unwrap();
    h.update(
        &group,
        &worker,
        WorkerPhase::Succeeded,
        Some("final durable result"),
    )
    .unwrap();
    h.cleanup(&group, None);
    h.manager.shutdown_session(h.root.clone()).unwrap();
    let freeze = h.manager.begin_handover().unwrap();
    let serialized = h.manager.serialize_active_sessions().unwrap();
    let no_descriptors = serialized.fds.is_empty();
    for fd in serialized.fds {
        drop(unsafe { LifecycleOwnedFd::from_raw_fd(fd) });
    }
    assert!(serialized.state.sessions.is_empty());
    assert!(no_descriptors);
    successor
        .queue_handover_adoptions(serialized.state, Vec::new())
        .unwrap();
    drop(freeze);
    assert!(!successor.has_pending_adoptions());
    let refreshed = lifecycle_group(&successor, &group.group_id);
    assert_eq!(refreshed.phase, WorkerGroupPhase::Closed);
    assert_eq!(refreshed.workers[0].session, worker.session);
    assert_eq!(
        refreshed.workers[0].result.as_deref(),
        Some("final durable result")
    );
}

#[test]
fn lifecycle_pending_missing_worker_defers_launch_retry_and_cleanup() {
    let h = Harness::new();
    let group = h.group();
    let request = h.request(&group, "pending", &h.root);
    let worker = h.spawn(request.clone());
    let serialized = h.manager.serialize_active_sessions().unwrap();
    let descriptors: Vec<_> = serialized
        .fds
        .into_iter()
        .map(|fd| unsafe { LifecycleOwnedFd::from_raw_fd(fd) })
        .collect();
    let inherited = serialized
        .state
        .sessions
        .into_iter()
        .find(|session| session.id == worker.session.session_id)
        .unwrap();
    drop(descriptors);
    h.manager
        .shutdown_session(worker.session.session_id.clone())
        .unwrap();
    let profile = h.manager.worker_profiles().unwrap()["test"].clone();
    {
        let mut guard = h.manager.worker_registry.lock().unwrap();
        let registry = guard.as_mut().unwrap();
        let mut next = registry.clone();
        let i = next.group_index(&group.group_id).unwrap();
        next.groups[i].workers[0].phase = WorkerPhase::Launching;
        next.launches.insert(worker.task_id.clone(), profile);
        h.manager.save_workers(registry, next).unwrap();
    }
    let _pending_cleanup = LifecycleFixtureCleanup::new(h.manager.clone());
    // No actor is installed from this inert descriptor: the test pins ownership
    // while adoption is pending, independently of an OS child's behavior.
    let pending_fd = std::fs::File::open("/dev/null").unwrap().into_raw_fd();
    h.manager
        .queue_handover_adoptions(
            crate::handover::HandoverState {
                sessions: vec![inherited],
                ..Default::default()
            },
            vec![pending_fd],
        )
        .unwrap();
    assert!(!h.manager.identity_exists(&worker.session).unwrap());
    let mut launch = super::super::PersistedSessionLaunch::from(&super::super::SessionConfig::new(
        "/bin/cat",
        h.dir.join("pending-placeholder.log"),
    ));
    launch.instance_id = worker.session.instance_id.clone();
    let historical = super::super::HistoricalSession::restore(
        launch.into_persisted(worker.session.session_id.clone(), true),
    )
    .unwrap();
    h.manager.sessions().unwrap().insert(
        worker.session.session_id.clone(),
        ManagedSession::Historical {
            session: Box::new(historical),
            lease: Default::default(),
        },
    );
    assert_eq!(h.manager.worker_liveness(&worker.session).unwrap(), None);
    h.manager
        .sessions()
        .unwrap()
        .remove(&worker.session.session_id);
    let error = h
        .manager
        .worker_operation(WorkerRequest::Spawn(request))
        .unwrap_err();
    assert!(format!("{error:#}").contains("adoption"), "{error:#}");
    assert_eq!(h.manager.list_sessions().unwrap(), vec![h.root.clone()]);
    let report = h.cleanup(&group, None);
    assert_eq!(report.group.phase, WorkerGroupPhase::Closing);
    assert!(report.closed.is_empty());
    assert!(report.errors[worker.session.session_id.as_str()].contains("adoption"));
    assert!(!report.group.workers[0].session_closed);
    assert_eq!(report.group.workers[0].phase, WorkerPhase::Cancelled);
    assert_eq!(h.manager.pending_adoptions.lock().unwrap().len(), 1);
    assert!(
        h.manager
            .session_awaits_adoption(&worker.session.session_id)
    );
    for fd in h.manager.take_pending_adoption_fds_for_test() {
        drop(unsafe { LifecycleOwnedFd::from_raw_fd(fd) });
    }
    let report = h.cleanup(&group, None);
    assert!(report.errors.is_empty());
    assert_eq!(report.group.phase, WorkerGroupPhase::Closed);
    assert!(report.group.workers[0].session_closed);
    assert!(h.manager.identity_exists(&group.root).unwrap());
}

#[test]
fn lifecycle_parked_actor_observation_does_not_pin_handover() {
    let h = Harness::new();
    let group = h.group();
    let worker = h.spawn(h.request(&group, "parked", &h.root));
    let (tx, commands) = std::sync::mpsc::channel();
    let exited = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let cleanup = lifecycle_install_fake_actor(&h, &worker, tx, None, exited.clone());
    let manager = h.manager.clone();
    let group_id = group.group_id.clone();
    let (observed_tx, observed_rx) = std::sync::mpsc::channel();
    let observer = std::thread::spawn(move || {
        let _ = observed_tx.send(manager.worker_operation(WorkerRequest::Get { group_id }));
    });
    let observed = observed_rx.recv_timeout(LifecycleDuration::from_secs(2));
    let manager = h.manager.clone();
    let (handover_tx, handover_rx) = std::sync::mpsc::channel();
    let handover = std::thread::spawn(move || {
        let admitted = manager.begin_handover().is_some();
        let _ = handover_tx.send(admitted);
    });
    let admitted = handover_rx.recv_timeout(LifecycleDuration::from_secs(2));
    let queued = commands.try_recv();
    exited.store(true, std::sync::atomic::Ordering::Relaxed);
    let observed_exit = if observed.is_ok() {
        Some(lifecycle_group(&h.manager, &group.group_id).workers[0].session_exited)
    } else {
        None
    };
    // Disconnect first even when a regression left a request parked, then join.
    drop(commands);
    drop(queued);
    drop(cleanup);
    observer.join().unwrap();
    handover.join().unwrap();
    let WorkerResponse::Group(observed) = observed.expect("observation waited for actor").unwrap()
    else {
        panic!("expected group")
    };
    assert_eq!(observed.workers[0].session_exited, Some(false));
    assert_eq!(observed_exit, Some(Some(true)));
    assert!(admitted.expect("handover waited for registry"));
}

#[test]
fn lifecycle_handover_refuses_a_busy_registry_without_waiting() {
    let h = Harness::new();
    let held = h.manager.worker_registry.lock().unwrap();
    let manager = h.manager.clone();
    let (reply_tx, reply_rx) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        let admitted = manager.begin_handover().is_some();
        let _ = reply_tx.send(admitted);
    });
    let reply = reply_rx.recv_timeout(LifecycleDuration::from_secs(2));
    drop(held);
    thread.join().unwrap();
    assert!(!reply.expect("handover admission blocked on worker registry"));
}

#[test]
fn lifecycle_timed_out_owned_shutdown_retries_after_the_actor_finishes() {
    let h = Harness::new();
    let group = h.group();
    let worker = h.spawn(h.request(&group, "late-shutdown", &h.root));
    let (tx, commands) = std::sync::mpsc::channel();
    let (seen_tx, seen_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let exited = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let actor_exited = exited.clone();
    let actor = std::thread::spawn(move || {
        let command = commands.recv_timeout(LifecycleDuration::from_secs(5));
        if let Ok(super::super::ActorCommand::Shutdown { response }) = command {
            let _ = seen_tx.send(());
            let _ = release_rx.recv_timeout(LifecycleDuration::from_secs(5));
            actor_exited.store(true, std::sync::atomic::Ordering::Relaxed);
            let _ = response.send(Ok(triage_core::session::CompletedSession {
                output_seq: 1,
                bytes_logged: 24,
                visible_rows: vec!["retained worker output".into()],
            }));
        }
    });
    let cleanup = lifecycle_install_fake_actor(&h, &worker, tx, Some(actor), exited);
    let manager = h.manager.clone();
    let identity = worker.session.clone();
    let (result_tx, result_rx) = std::sync::mpsc::channel();
    let caller = std::thread::spawn(move || {
        let result = manager.shutdown_session_inner(
            identity.session_id,
            Some(&identity.instance_id),
            Some(LifecycleInstant::now() + LifecycleDuration::from_secs(2)),
        );
        let _ = result_tx.send(result);
    });
    let seen = seen_rx.recv_timeout(LifecycleDuration::from_secs(3));
    let result = result_rx.recv_timeout(LifecycleDuration::from_secs(3));
    // Releasing before assertions lets both the old and fixed paths unwind.
    let _ = release_tx.send(());
    caller.join().unwrap();
    seen.expect("owned shutdown never reached its actor");
    let error = result
        .expect("owned shutdown did not honor its deadline")
        .unwrap_err();
    assert!(format!("{error:#}").contains("deadline"), "{error:#}");
    let deadline = LifecycleInstant::now() + LifecycleDuration::from_secs(3);
    loop {
        let finished = {
            let sessions = h.manager.sessions().unwrap();
            matches!(sessions.get(&worker.session.session_id), Some(ManagedSession::Live { actor, .. }) if actor.worker.as_ref().is_some_and(std::thread::JoinHandle::is_finished))
        };
        if finished {
            break;
        }
        assert!(
            LifecycleInstant::now() < deadline,
            "late actor did not finish"
        );
        std::thread::sleep(LifecycleDuration::from_millis(1));
    }
    h.manager
        .shutdown_session_inner(
            worker.session.session_id.clone(),
            Some(&worker.session.instance_id),
            Some(LifecycleInstant::now() + LifecycleDuration::from_secs(2)),
        )
        .expect("finished owned actor remained permanently unremovable after timeout");
    assert!(!h.manager.identity_exists(&worker.session).unwrap());
    let report = h.cleanup(&group, None);
    assert!(report.errors.is_empty());
    assert_eq!(report.group.phase, WorkerGroupPhase::Closed);
    assert!(report.group.workers[0].session_closed);
    assert!(h.manager.identity_exists(&group.root).unwrap());
    drop(cleanup);
}

#[test]
fn lifecycle_finished_actor_without_confirmed_child_exit_stays_owned() {
    let h = Harness::new();
    let group = h.group();
    let worker = h.spawn(h.request(&group, "unconfirmed-exit", &h.root));
    let (tx, commands) = std::sync::mpsc::channel();
    drop(commands);
    let actor = std::thread::spawn(|| {});
    let deadline = LifecycleInstant::now() + LifecycleDuration::from_secs(3);
    while !actor.is_finished() {
        assert!(
            LifecycleInstant::now() < deadline,
            "fake actor did not finish"
        );
        std::thread::sleep(LifecycleDuration::from_millis(1));
    }
    let exited = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let _cleanup = lifecycle_install_fake_actor(&h, &worker, tx, Some(actor), exited);
    let observed = h.manager.worker_liveness(&worker.session).unwrap();
    let report = h.cleanup(&group, None);
    let retained = h.manager.identity_exists(&worker.session).unwrap();

    assert_eq!(
        observed, None,
        "actor completion did not confirm child exit"
    );
    assert!(report.closed.is_empty());
    assert!(
        report
            .errors
            .contains_key(worker.session.session_id.as_str())
    );
    assert_eq!(report.group.phase, WorkerGroupPhase::Closing);
    assert!(!report.group.workers[0].session_closed);
    assert!(retained, "cleanup discarded an unconfirmed owned session");
    assert!(h.manager.identity_exists(&group.root).unwrap());
}

#[test]
fn managed_launch_announces_cached_git_context_after_session_started() {
    use triage_transport_ws::ServerMessage;

    fn git(repo: &std::path::Path, args: &[&str]) {
        let output = std::process::Command::new("git")
            .current_dir(repo)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env_remove("GIT_CONFIG_COUNT")
            .env_remove("GIT_DIR")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .args([
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=Triage Test",
                "-c",
                "user.email=triage@example.invalid",
            ])
            .args(args)
            .output()
            .expect("run isolated git command");
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let h = Harness::new();
    let group = h.group();
    let repo = h.dir.join("context-repo");
    let worktree = h.dir.join("context-worktree");
    let cwd = worktree.join("nested");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--initial-branch=main"]);
    git(
        &repo,
        &["commit", "--allow-empty", "-m", "test: seed worker context"],
    );
    git(
        &repo,
        &[
            "worktree",
            "add",
            "-b",
            "feature/worker-context",
            worktree.to_str().unwrap(),
        ],
    );
    std::fs::create_dir_all(&cwd).unwrap();
    let expected_repo = std::fs::canonicalize(&repo).unwrap();
    let expected_worktree = std::fs::canonicalize(&worktree).unwrap();
    let expected_cwd = std::fs::canonicalize(&cwd).unwrap();
    assert_ne!(expected_repo, expected_worktree);

    let events = h.manager.register_global_receiver();
    let mut request = h.request(&group, "context", &h.root);
    request.cwd = expected_cwd.clone();
    let worker = h.spawn(request);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    let mut saw_started = false;
    loop {
        let event = events
            .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
            .expect("managed launch did not publish its cached git context");
        match event {
            ServerMessage::SessionStarted {
                session_id,
                current_working_directory,
                ..
            } if session_id == worker.session.session_id => {
                assert!(!saw_started, "duplicate startup announcement");
                saw_started = true;
                assert_eq!(
                    current_working_directory
                        .as_deref()
                        .map(|p| std::fs::canonicalize(p).unwrap()),
                    Some(expected_cwd.clone())
                );
            }
            ServerMessage::SessionContextUpdated {
                session_id,
                current_working_directory,
                repository_root,
                worktree_root,
                branch,
            } if session_id == worker.session.session_id => {
                assert!(
                    saw_started,
                    "context update preceded the startup announcement"
                );
                assert_eq!(
                    current_working_directory
                        .as_deref()
                        .map(|p| std::fs::canonicalize(p).unwrap()),
                    Some(expected_cwd.clone())
                );
                assert_eq!(
                    repository_root
                        .as_deref()
                        .map(|p| std::fs::canonicalize(p).unwrap()),
                    Some(expected_repo.clone())
                );
                assert_eq!(
                    worktree_root
                        .as_deref()
                        .map(|p| std::fs::canonicalize(p).unwrap()),
                    Some(expected_worktree.clone())
                );
                assert_eq!(branch.as_deref(), Some("feature/worker-context"));
                break;
            }
            _ => {}
        }
    }
    assert!(h.cleanup(&group, None).errors.is_empty());
}

#[test]
fn real_worker_exit_is_observed_without_an_actor_snapshot_or_invented_result() {
    use std::time::{Duration, Instant};
    use triage_core::session::{
        ClientId, InputControllerKind, InputLeaseRequest, WriteInputRequest,
    };

    let h = Harness::new();
    let group = h.group();
    let worker = h.spawn(h.request(&group, "real-exit", &h.root));
    let initial = lifecycle_group(&h.manager, &group.group_id);
    assert_eq!(initial.workers[0].session_exited, Some(false));
    assert_eq!(initial.workers[0].phase, WorkerPhase::Launched);
    assert!(initial.workers[0].result.is_none());

    let client_id = ClientId::new("worker-exit-observer").unwrap();
    h.manager
        .acquire_input_lease(InputLeaseRequest {
            session_id: worker.session.session_id.clone(),
            client_id: client_id.clone(),
            kind: InputControllerKind::Agent,
        })
        .unwrap();
    // The real profile execs cat on its canonical PTY. EOF ends the child
    // without going through manager shutdown or a snapshot that polls it.
    h.manager
        .write_input(WriteInputRequest {
            session_id: worker.session.session_id.clone(),
            client_id,
            bytes: vec![0x04],
        })
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let observed = lifecycle_group(&h.manager, &group.group_id);
        assert_eq!(observed.workers[0].phase, WorkerPhase::Launched);
        assert!(observed.workers[0].result.is_none());
        if observed.workers[0].session_exited == Some(true) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "real worker exit was not observed: {observed:?}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    let report = h.cleanup(&group, None);
    assert!(report.errors.is_empty(), "{:?}", report.errors);
    assert_eq!(report.closed, vec![worker.session.session_id]);
    assert_eq!(report.group.phase, WorkerGroupPhase::Closed);
    assert_eq!(report.group.workers[0].phase, WorkerPhase::Cancelled);
    assert!(report.group.workers[0].result.is_none());
    assert_eq!(h.manager.list_sessions().unwrap(), vec![h.root.clone()]);
}

#[test]
fn managed_context_retries_after_backpressure_while_idle_or_output_closed() {
    use std::time::{Duration, Instant};
    use triage_core::session::{
        ClientId, InputControllerKind, InputLeaseRequest, WriteInputRequest,
    };
    use triage_transport_ws::ServerMessage;

    let h = Harness::new();
    let group = h.group();
    let repo = h.dir.join("context-retry-repo");
    let cwd = repo.join("nested");
    std::fs::create_dir_all(&cwd).unwrap();
    let git = std::process::Command::new("git")
        .current_dir(&repo)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env_remove("GIT_CONFIG_COUNT")
        .env_remove("GIT_DIR")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .args(["init", "--quiet", "--initial-branch=feature/context-retry"])
        .output()
        .unwrap();
    assert!(
        git.status.success(),
        "{}",
        String::from_utf8_lossy(&git.stderr)
    );
    let expected_repo = std::fs::canonicalize(&repo).unwrap();
    let expected_cwd = std::fs::canonicalize(&cwd).unwrap();
    let capacity = super::super::GLOBAL_PUSH_CHANNEL_CAPACITY;

    for output_closed in [false, true] {
        let events = h.manager.register_global_receiver();
        for _ in 0..capacity - 1 {
            // Only enqueue unrelated notifications; do not terminate the root.
            h.manager
                .broadcast_global(ServerMessage::SessionTerminated {
                    session_id: h.root.clone(),
                });
        }
        let mut request = h.request(
            &group,
            if output_closed {
                "retry-exited"
            } else {
                "retry-idle"
            },
            &h.root,
        );
        request.cwd = expected_cwd.clone();
        let worker = h.spawn(request);
        let actor_tx = {
            let sessions = h.manager.sessions().unwrap();
            let Some(ManagedSession::Live { actor, .. }) = sessions.get(&worker.session.session_id)
            else {
                panic!("expected live worker");
            };
            actor.tx.clone()
        };
        let (barrier_tx, barrier_rx) = std::sync::mpsc::channel();
        actor_tx
            .send(super::super::ActorCommand::Context {
                response: barrier_tx,
            })
            .unwrap();
        // This command follows ResendContext on the same actor queue. Keep the
        // global receiver full until the actor has attempted that notification.
        let cached = barrier_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("context barrier did not complete")
            .unwrap()
            .expect("worker did not cache its git context");
        assert_eq!(cached.repository_root, Some(expected_repo.clone()));
        assert_eq!(cached.worktree_root, Some(expected_repo.clone()));
        assert_eq!(cached.branch.as_deref(), Some("feature/context-retry"));

        if output_closed {
            let client_id = ClientId::new("context-retry-observer").unwrap();
            h.manager
                .acquire_input_lease(InputLeaseRequest {
                    session_id: worker.session.session_id.clone(),
                    client_id: client_id.clone(),
                    kind: InputControllerKind::Agent,
                })
                .unwrap();
            h.manager
                .write_input(WriteInputRequest {
                    session_id: worker.session.session_id.clone(),
                    client_id,
                    bytes: vec![0x04],
                })
                .unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            while h.manager.worker_liveness(&worker.session).unwrap() != Some(true) {
                assert!(Instant::now() < deadline, "worker did not exit on EOF");
                std::thread::sleep(Duration::from_millis(10));
            }
        }

        // Exactly the fillers and startup fit before the initial context attempt.
        // Any later successful retry is queued after this startup notification.
        for index in 0..capacity {
            let message = events.recv_timeout(Duration::from_secs(3)).unwrap();
            if index + 1 == capacity {
                assert!(
                    matches!(message, ServerMessage::SessionStarted { session_id, .. } if session_id == worker.session.session_id),
                    "startup did not occupy the final free global-push slot"
                );
            } else {
                assert!(
                    matches!(message, ServerMessage::SessionTerminated { session_id } if session_id == h.root),
                    "unrelated actor updates perturbed the controlled queue"
                );
            }
        }

        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let message = events
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .expect("cached context was never retried after the receiver drained");
            if let ServerMessage::SessionContextUpdated {
                session_id,
                current_working_directory,
                repository_root,
                worktree_root,
                branch,
            } = message
                && session_id == worker.session.session_id
            {
                let canonical =
                    |value: Option<String>| value.map(|path| std::fs::canonicalize(path).unwrap());
                assert_eq!(
                    canonical(current_working_directory),
                    Some(expected_cwd.clone())
                );
                assert_eq!(canonical(repository_root), Some(expected_repo.clone()));
                assert_eq!(canonical(worktree_root), Some(expected_repo.clone()));
                assert_eq!(branch.as_deref(), Some("feature/context-retry"));
                break;
            }
        }
        assert!(
            h.cleanup(&group, Some(worker.session.session_id))
                .errors
                .is_empty(),
            "owned subtree cleanup failed"
        );
    }
    assert!(h.cleanup(&group, None).errors.is_empty());
    assert_eq!(h.manager.list_sessions().unwrap(), vec![h.root.clone()]);
}

fn no_replay_finished_actor() -> std::thread::JoinHandle<()> {
    let actor = std::thread::spawn(|| {});
    let deadline = LifecycleInstant::now() + LifecycleDuration::from_secs(3);
    while !actor.is_finished() {
        assert!(
            LifecycleInstant::now() < deadline,
            "fake actor did not finish"
        );
        std::thread::sleep(LifecycleDuration::from_millis(1));
    }
    actor
}

#[test]
fn lifecycle_finished_owned_cleanup_does_not_require_replayable_history() {
    let h = Harness::new();
    let group = h.group();
    let worker = h.spawn(h.request(&group, "obsolete-history", &h.root));
    let (tx, commands) = std::sync::mpsc::channel();
    drop(commands);
    let _cleanup = lifecycle_install_fake_actor(
        &h,
        &worker,
        tx,
        Some(no_replay_finished_actor()),
        Arc::new(std::sync::atomic::AtomicBool::new(true)),
    );
    let log_path = h.dir.join(format!("{}.log", worker.session.session_id));
    std::fs::remove_file(&log_path).unwrap();
    std::fs::create_dir(&log_path).unwrap();
    let persisted = {
        let sessions = h.manager.sessions().unwrap();
        sessions[&worker.session.session_id].persisted(worker.session.session_id.clone())
    };
    // Establish that reconstruction really fails, before it can resolve context.
    assert!(super::super::HistoricalSession::restore(persisted).is_err());
    h.manager.custom_labels().unwrap().insert(
        worker.session.session_id.to_string(),
        "finished helper".into(),
    );
    h.manager
        .send_session_message(
            h.root.clone(),
            worker.session.session_id.clone(),
            "retained until removal".into(),
        )
        .unwrap();
    h.manager
        .persist_manifest(&h.manager.sessions().unwrap())
        .unwrap();
    let manifest_path = h.manager.config.manifest_path();
    let original_manifest = std::fs::read(&manifest_path).unwrap();
    std::fs::remove_file(&manifest_path).unwrap();
    std::fs::create_dir(&manifest_path).unwrap();

    let refused = h.cleanup(&group, None);
    let retained = h.manager.identity_exists(&worker.session).unwrap();
    // Restore persistence before asserting, so fixture cleanup remains usable.
    std::fs::remove_dir(&manifest_path).unwrap();
    std::fs::write(&manifest_path, original_manifest).unwrap();
    assert!(
        refused
            .errors
            .contains_key(worker.session.session_id.as_str())
    );
    assert!(!refused.group.workers[0].session_closed);
    assert!(retained, "failed manifest removal discarded ownership");
    assert!(
        h.manager
            .inboxes()
            .unwrap()
            .contains_key(&worker.session.session_id)
    );
    assert!(
        h.manager
            .custom_labels()
            .unwrap()
            .contains_key(worker.session.session_id.as_str())
    );

    let report = h.cleanup(&group, None);
    assert!(report.errors.is_empty(), "{:?}", report.errors);
    assert_eq!(report.closed, vec![worker.session.session_id.clone()]);
    assert_eq!(report.group.phase, WorkerGroupPhase::Closed);
    assert!(report.group.workers[0].session_closed);
    assert!(!h.manager.identity_exists(&worker.session).unwrap());
    assert!(h.manager.identity_exists(&group.root).unwrap());
    assert!(
        !h.manager
            .inboxes()
            .unwrap()
            .contains_key(&worker.session.session_id)
    );
    assert!(
        !h.manager
            .custom_labels()
            .unwrap()
            .contains_key(worker.session.session_id.as_str())
    );
    let manifest: super::super::SessionManifest =
        serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).unwrap();
    assert!(
        !manifest
            .sessions
            .iter()
            .any(|s| s.id == worker.session.session_id)
    );
    assert!(h.dir.is_dir());
}

#[test]
fn lifecycle_owned_cleanup_does_not_resolve_context_for_live_or_finished_actors() {
    for already_finished in [false, true] {
        let h = Harness::new();
        let group = h.group();
        let worker = h.spawn(h.request(&group, "no-context", &h.root));
        let (tx, commands) = std::sync::mpsc::channel();
        let exited = Arc::new(std::sync::atomic::AtomicBool::new(already_finished));
        let actor = if already_finished {
            drop(commands);
            no_replay_finished_actor()
        } else {
            let actor_exited = exited.clone();
            std::thread::spawn(move || {
                if let Ok(super::super::ActorCommand::Shutdown { response }) =
                    commands.recv_timeout(LifecycleDuration::from_secs(5))
                {
                    actor_exited.store(true, std::sync::atomic::Ordering::Relaxed);
                    let _ = response.send(Ok(triage_core::session::CompletedSession {
                        output_seq: 1,
                        bytes_logged: 24,
                        visible_rows: vec!["retained worker output".into()],
                    }));
                }
            })
        };
        let _cleanup = lifecycle_install_fake_actor(&h, &worker, tx, Some(actor), exited);
        // Any reconstruction's context resolution must acquire this mutex, even
        // with a warm cache. The actor reply itself does not need the mutex.
        let mut context_cache = super::super::SESSION_CONTEXT_CACHE.lock().unwrap();
        let manager = h.manager.clone();
        let group_id = group.group_id.clone();
        let (reply_tx, reply_rx) = std::sync::mpsc::channel();
        let caller = std::thread::spawn(move || {
            let _ = reply_tx.send(manager.worker_operation(WorkerRequest::Cleanup(
                CleanupWorkerGroup {
                    group_id,
                    subtree_session_id: None,
                },
            )));
        });
        let reply = reply_rx.recv_timeout(LifecycleDuration::from_secs(3));
        // Release the barrier before assertions/join, and provide a fresh answer
        // for this fixture so the unfixed path also unwinds without invoking Git.
        context_cache
            .get_or_insert_with(std::collections::HashMap::new)
            .insert(h.dir.clone(), (None, LifecycleInstant::now()));
        drop(context_cache);
        caller.join().unwrap();
        let response = reply
            .expect("owned cleanup waited for context resolution")
            .unwrap();
        let WorkerResponse::Cleanup(report) = response else {
            panic!("expected cleanup response");
        };
        assert!(report.errors.is_empty(), "{:?}", report.errors);
        assert!(report.group.workers[0].session_closed);
        assert!(!h.manager.identity_exists(&worker.session).unwrap());
        assert!(h.manager.identity_exists(&group.root).unwrap());
    }
}

#[test]
fn lifecycle_live_owned_cleanup_retains_identity_when_removal_commit_fails_after_shutdown() {
    let h = Harness::new();
    let group = h.group();
    let worker = h.spawn(h.request(&group, "post-shutdown-commit", &h.root));
    let manifest_path = h.manager.config.manifest_path();
    let fault_manifest = manifest_path.clone();
    let prepared_manifest = h
        .manager
        .shutdown_manifest_temp_path(&worker.session.session_id);
    let (tx, commands) = std::sync::mpsc::channel();
    let (fault_tx, fault_rx) = std::sync::mpsc::channel();
    let exited = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let actor_exited = exited.clone();
    let actor = std::thread::spawn(move || {
        if let Ok(super::super::ActorCommand::Shutdown { response }) =
            commands.recv_timeout(LifecycleDuration::from_secs(10))
        {
            // Receiving Shutdown proves the live path passed its initial prepare.
            let prepared = prepared_manifest.is_file();
            let fault = std::fs::remove_file(&fault_manifest)
                .and_then(|()| std::fs::create_dir(&fault_manifest))
                .map_err(|error| error.to_string());
            let _ = fault_tx.send((prepared, fault));
            actor_exited.store(true, std::sync::atomic::Ordering::Relaxed);
            let _ = response.send(Ok(triage_core::session::CompletedSession {
                output_seq: 1,
                bytes_logged: 24,
                visible_rows: vec!["retained worker output".into()],
            }));
        } else {
            let _ = fault_tx.send((false, Err("live actor did not receive Shutdown".into())));
        }
    });
    let _cleanup = lifecycle_install_fake_actor(&h, &worker, tx, Some(actor), exited);
    h.manager.custom_labels().unwrap().insert(
        worker.session.session_id.to_string(),
        "retain ownership until removal commits".into(),
    );
    h.manager
        .send_session_message(
            h.root.clone(),
            worker.session.session_id.clone(),
            "retain this inbox until removal commits".into(),
        )
        .unwrap();
    h.manager
        .persist_manifest(&h.manager.sessions().unwrap())
        .unwrap();
    let original_manifest = std::fs::read(&manifest_path).unwrap();
    {
        let sessions = h.manager.sessions().unwrap();
        assert!(
            matches!(sessions.get(&worker.session.session_id), Some(ManagedSession::Live { actor, .. }) if actor.worker.as_ref().is_some_and(|handle| !handle.is_finished())),
            "fixture must enter owned cleanup with a live actor"
        );
    }

    let refused = h.cleanup(&group, None);
    let fault = fault_rx.recv_timeout(LifecycleDuration::from_secs(3));
    let retained = h.manager.identity_exists(&worker.session).unwrap();
    // Restore persistence before any assertion so failure paths remain removable.
    if manifest_path.is_dir() {
        std::fs::remove_dir(&manifest_path).unwrap();
    }
    std::fs::write(&manifest_path, original_manifest).unwrap();
    let (prepared, fault) = fault.expect("live actor never staged the post-shutdown fault");
    fault.expect("failed to stage the post-shutdown manifest replacement fault");
    assert!(
        prepared,
        "initial live shutdown preparation did not succeed"
    );
    assert!(
        retained,
        "post-shutdown manifest commit failure discarded the owned actor identity"
    );
    assert_eq!(refused.group.phase, WorkerGroupPhase::Closing);
    assert!(!refused.group.workers[0].session_closed);
    let error = &refused.errors[worker.session.session_id.as_str()];
    assert!(error.contains("committing its removal failed"), "{error}");
    assert!(error.contains("ownership retained for retry"), "{error}");
    assert!(
        h.manager
            .inboxes()
            .unwrap()
            .contains_key(&worker.session.session_id)
    );
    assert!(
        h.manager
            .custom_labels()
            .unwrap()
            .contains_key(worker.session.session_id.as_str())
    );
    assert!(h.manager.identity_exists(&group.root).unwrap());

    let deadline = LifecycleInstant::now() + LifecycleDuration::from_secs(3);
    loop {
        let finished = {
            let sessions = h.manager.sessions().unwrap();
            matches!(sessions.get(&worker.session.session_id), Some(ManagedSession::Live { actor, .. }) if actor.worker.as_ref().is_some_and(std::thread::JoinHandle::is_finished))
        };
        if finished {
            break;
        }
        assert!(
            LifecycleInstant::now() < deadline,
            "retained owned actor did not finish after acknowledging shutdown"
        );
        std::thread::sleep(LifecycleDuration::from_millis(1));
    }
    let report = h.cleanup(&group, None);
    assert!(report.errors.is_empty(), "{:?}", report.errors);
    assert_eq!(report.closed, vec![worker.session.session_id.clone()]);
    assert_eq!(report.group.phase, WorkerGroupPhase::Closed);
    assert!(report.group.workers[0].session_closed);
    assert!(!h.manager.identity_exists(&worker.session).unwrap());
    assert!(h.manager.identity_exists(&group.root).unwrap());
    assert!(
        !h.manager
            .inboxes()
            .unwrap()
            .contains_key(&worker.session.session_id)
    );
    assert!(
        !h.manager
            .custom_labels()
            .unwrap()
            .contains_key(worker.session.session_id.as_str())
    );
    let manifest: super::super::SessionManifest =
        serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).unwrap();
    assert!(
        !manifest
            .sessions
            .iter()
            .any(|session| session.id == worker.session.session_id)
    );
    assert_eq!(h.manager.list_sessions().unwrap(), vec![h.root.clone()]);
    assert!(h.dir.is_dir());
}
