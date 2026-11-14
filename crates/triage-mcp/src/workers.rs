use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};
use triage_core::session::SessionApi;
use triage_core::workers::*;

use super::{JsonRpcError, ToolCallError, arguments_object};

pub(super) const TOOL_NAMES: &[&str] = &[
    "list_worker_profiles",
    "create_worker_group",
    "list_worker_groups",
    "get_worker_group",
    "spawn_worker",
    "update_worker",
    "cleanup_worker_group",
];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Empty {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GetGroup {
    group_id: String,
}

fn decode<T: serde::de::DeserializeOwned>(value: Value) -> std::result::Result<T, ToolCallError> {
    arguments_object(&value)?;
    serde_json::from_value(value)
        .map_err(|e| JsonRpcError::invalid_params(format!("invalid worker arguments: {e}")).into())
}

pub(super) fn call(
    api: &impl SessionApi,
    name: &str,
    value: Value,
) -> std::result::Result<Value, ToolCallError> {
    let request = match name {
        "list_worker_profiles" => {
            let _: Empty = decode(value)?;
            WorkerRequest::Profiles
        }
        "list_worker_groups" => {
            let _: Empty = decode(value)?;
            WorkerRequest::List
        }
        "create_worker_group" => WorkerRequest::Create(decode(value)?),
        "get_worker_group" => WorkerRequest::Get {
            group_id: decode::<GetGroup>(value)?.group_id,
        },
        "spawn_worker" => WorkerRequest::Spawn(decode(value)?),
        "update_worker" => WorkerRequest::Update(decode(value)?),
        "cleanup_worker_group" => WorkerRequest::Cleanup(decode(value)?),
        _ => return Err(JsonRpcError::invalid_params("unknown worker tool").into()),
    };
    request
        .validate()
        .map_err(|e| JsonRpcError::invalid_params(e.to_string()))?;
    let response = api.worker_operation(request)?;
    response_value(response).map_err(Into::into)
}

fn response_value(response: WorkerResponse) -> Result<Value> {
    Ok(match response {
        WorkerResponse::Profiles(profiles) => json!({ "profiles": profiles }),
        WorkerResponse::Groups(groups) => json!({ "groups": groups }),
        WorkerResponse::Group(group) => json!({ "group": group }),
        WorkerResponse::Worker(worker) => json!({ "worker": worker }),
        WorkerResponse::Cleanup(report) => serde_json::to_value(report)?,
    })
}

pub(super) fn definitions() -> Vec<Value> {
    let string = json!({"type":"string", "minLength":1});
    [
        ("list_worker_profiles", "List configured executable/argv worker profiles. Profile args contain a literal {prompt} placeholder; model flags are configured by the user.", json!({}), vec![], true, false),
        ("create_worker_group", "Create a durable parent/topic group using a retry key. A managed helper automatically inherits its existing group. Read TRIAGE_SESSION_ID for your parent_session_id.", json!({"parent_session_id":string,"key":string,"topic":string}), vec!["parent_session_id","key","topic"], false, false),
        ("list_worker_groups", "List durable groups, parent relationships, task results, and observed worker liveness, including closed groups.", json!({}), vec![], true, false),
        ("get_worker_group", "Read durable task phases/results and observed session liveness for a group. Launched means a process started; ready/running require worker acknowledgment. A missing or exited session without a result is interrupted work.", json!({"group_id":string}), vec!["group_id"], true, false),
        ("spawn_worker", "Launch a configured helper with a bootstrap task, in this group under an immediate parent. Retry an ambiguous launch with the identical group/key/request; it reconciles the saved launch intention without duplicating a session. Reusing a key with different task/profile/cwd/parent is rejected. Prefer native subagents when the calling runtime supports the requested provider/model and has capacity; otherwise use this tool.", json!({"group_id":string,"parent_session_id":string,"key":string,"profile":string,"cwd":string,"task":string}), vec!["group_id","parent_session_id","key","profile","cwd","task"], false, true),
        ("update_worker", "Report ready, then running, then succeeded or failed. Include a nonblank result for terminal updates. Results persist across restarts and cleanup. Duplicate identical updates are safe. Sender session_id is caller-asserted, like direct mail, within the trusted local daemon boundary.", json!({"group_id":string,"task_id":string,"session_id":string,"phase":{"type":"string","enum":["ready","running","succeeded","failed"]},"result":{"type":"string"}}), vec!["group_id","task_id","session_id","phase"], false, false),
        ("cleanup_worker_group", "Cancel unfinished work and stop only worker incarnations owned by this group. Omit subtree_session_id for the entire group; set it to a worker to include that worker and all descendants. The root session, task results, and all working directories/worktrees are retained. Inspect errors and retry cleanup when needed.", json!({"group_id":string,"subtree_session_id":string}), vec!["group_id"], false, true),
    ].into_iter().map(|(name, description, properties, required, read, destructive)| json!({
        "name":name, "description":description,
        "inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false},
        "annotations":{"readOnlyHint":read,"destructiveHint":destructive,"idempotentHint":true,"openWorldHint":name == "spawn_worker"}
    })).collect()
}

pub(super) fn update_cli(args: impl IntoIterator<Item = std::ffi::OsString>) -> Result<()> {
    use triage_core::session::SessionId;
    let mut args = args.into_iter();
    let usage = "usage: triage-mcp worker-update <group-id> <task-id> <ready|running|succeeded|failed> [--result-file <path>] [--socket <path>]";
    let group_id = args
        .next()
        .context(usage)?
        .into_string()
        .map_err(|_| anyhow::anyhow!(usage))?;
    let task_id = args
        .next()
        .context(usage)?
        .into_string()
        .map_err(|_| anyhow::anyhow!(usage))?;
    let phase = args
        .next()
        .context(usage)?
        .into_string()
        .map_err(|_| anyhow::anyhow!(usage))?;
    let phase = serde_json::from_value::<WorkerPhase>(json!(phase)).context(usage)?;
    let mut result = None;
    let mut socket = None;
    while let Some(flag) = args.next() {
        match flag.to_str() {
            Some("--result-file") if result.is_none() => {
                use std::io::Read;
                let path = args.next().context(usage)?;
                let mut bytes = Vec::new();
                std::fs::File::open(path)?
                    .take(MAX_WORKER_TEXT_BYTES as u64 + 1)
                    .read_to_end(&mut bytes)?;
                result = Some(String::from_utf8(bytes).context("result must be UTF-8")?);
            }
            Some("--socket") if socket.is_none() => {
                socket = Some(std::path::PathBuf::from(args.next().context(usage)?))
            }
            _ => bail!(usage),
        }
    }
    let request = WorkerRequest::Update(UpdateWorker {
        group_id,
        task_id,
        session_id: SessionId::new(
            std::env::var("TRIAGE_SESSION_ID")
                .context("worker-update must run inside its Triage session")?,
        )?,
        phase,
        result,
    });
    request.validate()?;
    #[cfg(any(unix, windows))]
    {
        let client =
            triaged::ipc::IpcClient::new(socket.unwrap_or_else(triaged::ipc::default_socket_path));
        let response = response_value(client.worker_operation(request)?)?;
        println!("{}", serde_json::to_string(&response)?);
        Ok(())
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (request, socket);
        bail!("worker-update requires local IPC")
    }
}
