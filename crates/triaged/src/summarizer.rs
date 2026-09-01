//! Local-LLM session summarizer.
//!
//! Generates a short, one-line description of what a terminal session is doing
//! (e.g. "running cargo test") for display in the client's side rail. All
//! inference runs on a single dedicated worker thread that owns one
//! [`cera::CeraEngine`] — the engine is heavy (hundreds of MB) and generation is
//! CPU-bound, so serializing through one thread keeps inference off the tokio
//! reactor and off the session actors, and avoids loading the model more than
//! once. The model is downloaded + loaded lazily on the first job, so enabling
//! the summarizer never blocks daemon startup.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use cera::manifest::GenerationDefaults;
use cera::session::{FinishReason, ModalitySink};
use cera::tokenizer::{BpeTokenizer, ChatMessage};
use triage_core::judge::{JudgeRequest, JudgeVerdict};
use triage_core::session::{SessionContext, SessionId};

/// How long the idle worker sleeps between checks for "every handle has been
/// dropped". Only paid when the queue is empty, so it costs one wakeup per
/// second on a daemon with nothing to summarize.
///
/// A timed wait rather than a plain one, on purpose. The retirement condition is
/// an `Arc` refcount, and that count only falls to one *after* the last handle's
/// `Drop` body has finished, so there is no moment from which a handle could
/// safely notify. Re-checking on a timer makes the condition impossible to miss,
/// where a plain `wait` plus a notify would risk parking the worker forever.
const IDLE_POLL: Duration = Duration::from_secs(1);

/// Instruction given to the model. Kept terse; the model only needs to label.
const SYSTEM_PROMPT: &str = "You label terminal sessions. Reply with a terse description of what \
the session's primary task or main work is (and its status if active), at most 8 words, no \
trailing punctuation, no quotes. Preserve the main body of work even if currently waiting at a \
prompt. Output only the label.";

/// Instruction for the longer-form detail summary shown in the hover popover and
/// used as the future session-search corpus. The repo/branch/worktree the
/// session lives in are prepended deterministically by [`generate_detail`] (the
/// model can't see them and must not invent them), so this prompt only asks for
/// the activity. Length is generous — enough sentences to localize the user.
const DETAIL_SYSTEM_PROMPT: &str = "You summarize terminal sessions so a developer can tell which \
of many sessions this is, what work it was created for, and what it currently needs. Describe the \
initial/main body of work (the primary task, command, or goal initiated in the session) along with \
the current state (building, tests passing/failing, an error and its message, or finished/waiting \
at a prompt for input). Even if the session is currently waiting at a prompt, describe the main \
work that was performed or started. Use as many short sentences as the activity needs — up to \
about five — but no filler. Be concrete and factual; prefer specifics (command names, file paths, \
error text) over generalities. Do not guess the git repository, branch, or directory. No markdown, \
no quotes, no preamble — output only the summary.";

/// Cap on the sanitized snippet length (characters), before the ellipsis a
/// truncation adds, so a cut label renders one character over this.
const MAX_SNIPPET_CHARS: usize = 60;
/// Cap on the sanitized snippet length (words). Cutting here also appends the
/// ellipsis, so a label over this renders as eight words plus the marker.
const MAX_SNIPPET_WORDS: usize = 8;

/// Cap on the sanitized detail summary length (characters), before the ellipsis
/// a truncation adds. Applies only to the model-written activity portion; the
/// deterministic context header is prepended afterwards and is never truncated.
const MAX_DETAIL_CHARS: usize = 480;

/// Runtime parameters for the summarizer worker. Built from the daemon config.
#[derive(Debug, Clone)]
pub struct SummarizerConfig {
    pub bundle_id: String,
    pub quant: String,
    pub context_size: u32,
    pub max_tokens: u32,
    /// Token budget for the longer-form detail summary (a few sentences).
    pub detail_max_tokens: u32,
    pub cache_dir: PathBuf,
    /// Upper bound on queued judge jobs. Summarize jobs are not bounded by this:
    /// they coalesce into a map keyed by session, so their count is capped by
    /// the number of live sessions rather than by a queue depth.
    pub judge_queue_depth: usize,
}

/// A request to summarize one session's current screen.
pub struct SummarizeJob {
    pub session_id: SessionId,
    pub prompt_text: String,
    pub output_seq: u64,
    /// Git context (repo/branch/worktree) for this session, used to build the
    /// deterministic localization header on the detail summary. `None` when the
    /// session isn't inside a git repo.
    pub context: Option<SessionContext>,
    /// Working directory for this session, used as fallback localization when
    /// the session is not inside a git repo.
    pub cwd: Option<PathBuf>,
}

/// A produced snippet, delivered to the `on_result` callback on the worker thread.
pub struct SnippetResult {
    pub session_id: SessionId,
    pub text: String,
    /// Longer-form summary for the hover popover / search: a deterministic
    /// `repo · branch · worktree` header (when the session has git context)
    /// followed by the model's activity description. `None` only when neither
    /// the model nor the git context produced anything usable (keeps any prior
    /// detail rather than clearing it).
    pub detail: Option<String>,
    pub generated_at_output_seq: u64,
}

/// A request to judge one tool call, plus the channel its verdict returns on.
///
/// Unlike [`SummarizeJob`], this is request/response: a caller is blocked on the
/// answer, and through them so is an agent's tool-call loop.
pub struct JudgeJob {
    pub request: JudgeRequest,
    /// Capacity-1 so the worker's reply never blocks, even if the caller has
    /// already timed out and stopped listening.
    pub reply: SyncSender<JudgeVerdict>,
}

/// One unit of work for the inference thread.
enum Job {
    Judge(JudgeJob),
    Summarize(SummarizeJob),
}

/// The worker's pending work.
///
/// Judge jobs are a queue; summarize jobs are a map keyed by session, which
/// coalesces them for free: a second job for a session that has not started yet
/// replaces the first, so a busy session never summarizes a stale screen twice.
#[derive(Default)]
struct QueueInner {
    judge: VecDeque<JudgeJob>,
    summarize: HashMap<SessionId, SummarizeJob>,
}

/// Shared queue between the [`Summarizer`] handles and the inference thread.
struct JobQueue {
    inner: Mutex<QueueInner>,
    signal: Condvar,
    /// Cancel flag of the summarize generation running right now, if any. A
    /// judge job arriving mid-summary flips it so the worker becomes available
    /// in one token's time rather than after a full detail summary.
    in_flight_summary: Mutex<Option<Arc<AtomicBool>>>,
    /// Upper bound on queued judge jobs. Past this, callers get a fallback
    /// `ask` immediately instead of queueing behind work they will outlive.
    judge_capacity: usize,
}

impl JobQueue {
    fn new(judge_capacity: usize) -> Self {
        Self {
            inner: Mutex::new(QueueInner::default()),
            signal: Condvar::new(),
            in_flight_summary: Mutex::new(None),
            judge_capacity,
        }
    }

    /// Queues a judge job and preempts any running summary. `Err` carries why it
    /// could not be queued, which the caller reports as the `ask` reason: a
    /// poisoned lock and a full queue are different problems and naming one as
    /// the other sends whoever reads the audit log to the wrong place.
    fn push_judge(&self, job: JudgeJob) -> Result<(), &'static str> {
        let Ok(mut inner) = self.inner.lock() else {
            tracing::error!("inference queue mutex is poisoned; judging is unavailable");
            return Err("local model queue is unavailable");
        };
        if inner.judge.len() >= self.judge_capacity {
            return Err("judge queue is full");
        }
        inner.judge.push_back(job);
        drop(inner);
        self.cancel_in_flight_summary();
        self.signal.notify_all();
        Ok(())
    }

    /// Queues a summarize job, replacing any not-yet-started job for the same
    /// session when this one describes a newer screen.
    fn push_summarize(&self, job: SummarizeJob) -> bool {
        let Ok(mut inner) = self.inner.lock() else {
            return false;
        };
        let pushed = match inner.summarize.get(&job.session_id) {
            Some(existing) if existing.output_seq >= job.output_seq => false,
            _ => {
                inner.summarize.insert(job.session_id.clone(), job);
                true
            }
        };
        drop(inner);
        if pushed {
            self.signal.notify_all();
        }
        pushed
    }

    /// Blocks until a job is available, judge jobs first. Returns `None` once
    /// every [`Summarizer`] handle has been dropped and nothing is left to do,
    /// which is what retires the worker thread.
    fn next_job(self: &Arc<Self>) -> Option<Job> {
        let Ok(mut inner) = self.inner.lock() else {
            // Retiring silently here would strand the worker forever and leave
            // every later judge call reporting a full queue, which is a
            // misleading cause for a poisoned lock.
            tracing::error!("inference queue mutex is poisoned; retiring the inference worker");
            return None;
        };
        loop {
            if let Some(job) = inner.judge.pop_front() {
                return Some(Job::Judge(job));
            }
            // Not `remove(..).map(Job::Summarize)`: that would route an
            // impossible `None` into this function's "retire the worker
            // forever" signal, which is far too load-bearing a return value to
            // reach by accident.
            if let Some(session_id) = inner.summarize.keys().next().cloned()
                && let Some(job) = inner.summarize.remove(&session_id)
            {
                return Some(Job::Summarize(job));
            }
            // Only this thread's own Arc remains, so no handle can enqueue again.
            if Arc::strong_count(self) == 1 {
                return None;
            }
            inner = self.signal.wait_timeout(inner, IDLE_POLL).ok()?.0;
        }
    }

    /// Publishes the cancel handle of the summary about to run, so a judge job
    /// can preempt it. The returned guard clears the slot when the generation
    /// finishes.
    fn register_summary(&self, handle: Arc<AtomicBool>) -> InFlightGuard<'_> {
        if let Ok(mut slot) = self.in_flight_summary.lock() {
            *slot = Some(Arc::clone(&handle));
        }
        // Re-check after publishing the handle, not before. A judge job pushed
        // in the window between the caller's check and this registration would
        // otherwise be missed by both sides: `cancel_in_flight_summary` ran
        // while the slot was still empty, and the caller's check ran before the
        // job arrived. Whichever of the two goes second now sees the other.
        if self.has_pending_judge() {
            handle.store(true, Ordering::Relaxed);
        }
        InFlightGuard { queue: self }
    }

    /// Whether a judge job is waiting right now.
    ///
    /// Checked between the two summary passes: the cancel handle only covers a
    /// generation that is actually running, so a judge job arriving in the gap
    /// between them would otherwise wait out a whole detail summary, which is
    /// long enough to burn the caller's timeout.
    fn has_pending_judge(&self) -> bool {
        self.inner.lock().is_ok_and(|inner| !inner.judge.is_empty())
    }

    fn cancel_in_flight_summary(&self) {
        if let Ok(slot) = self.in_flight_summary.lock()
            && let Some(handle) = slot.as_ref()
        {
            handle.store(true, Ordering::Relaxed);
        }
    }
}

/// Clears the in-flight summary slot on drop, so a cancel aimed at a finished
/// generation cannot leak onto the next one.
struct InFlightGuard<'a> {
    queue: &'a JobQueue,
}

impl Drop for InFlightGuard<'_> {
    fn drop(&mut self) {
        if let Ok(mut slot) = self.queue.in_flight_summary.lock() {
            *slot = None;
        }
    }
}

/// Handle to the inference worker. Cheap to clone (an `Arc` bump).
/// A disabled handle accepts nothing, which is the state when summarization is
/// turned off or the model fails to load.
#[derive(Clone)]
pub struct Summarizer {
    queue: Option<Arc<JobQueue>>,
}

impl Summarizer {
    /// Spawns the worker thread. The engine is loaded lazily on the first job.
    /// `on_result` is invoked on the worker thread for each produced snippet.
    pub fn spawn(
        config: SummarizerConfig,
        on_result: impl Fn(SnippetResult) + Send + 'static,
    ) -> Self {
        let queue = Arc::new(JobQueue::new(config.judge_queue_depth.max(1)));
        let worker_queue = Arc::clone(&queue);
        let builder = std::thread::Builder::new().name("triage-summarizer".to_string());
        if let Err(error) = builder.spawn(move || run_worker(config, worker_queue, on_result)) {
            tracing::error!(%error, "failed to spawn summarizer thread; snippets disabled");
            return Self::disabled();
        }
        Self { queue: Some(queue) }
    }

    /// A no-op summarizer that never produces snippets and never judges.
    pub fn disabled() -> Self {
        Self { queue: None }
    }

    pub fn is_enabled(&self) -> bool {
        self.queue.is_some()
    }

    /// Enqueues a job without blocking. Returns `false` if the summarizer is
    /// disabled (the upstream debounce loop will re-enqueue on the next settle,
    /// so dropping here is acceptable).
    pub fn try_enqueue(&self, job: SummarizeJob) -> bool {
        match &self.queue {
            Some(queue) => queue.push_summarize(job),
            None => false,
        }
    }

    /// Asks the model to judge one tool call, blocking up to `timeout`.
    ///
    /// Never fails: a disabled summarizer, a full judge queue, an unloaded
    /// model, or an expired timeout all return a fallback `ask`. The caller is
    /// an agent's blocked tool-call loop, so a bounded wait matters more than a
    /// precise answer.
    pub fn judge(&self, request: JudgeRequest, timeout: Duration) -> JudgeVerdict {
        let Some(queue) = &self.queue else {
            return JudgeVerdict::fallback("local model is disabled");
        };
        let (reply, verdicts) = sync_channel(1);
        if let Err(reason) = queue.push_judge(JudgeJob { request, reply }) {
            return JudgeVerdict::fallback(reason);
        }
        verdicts
            .recv_timeout(timeout)
            .unwrap_or_else(|_| JudgeVerdict::fallback("local model did not answer in time"))
    }
}

fn run_worker(config: SummarizerConfig, queue: Arc<JobQueue>, on_result: impl Fn(SnippetResult)) {
    let mut engine: Option<cera::CeraEngine> = None;
    let mut load_failed = false;

    while let Some(job) = queue.next_job() {
        if !load_failed && engine.is_none() {
            match load_engine(&config) {
                Ok(loaded) => {
                    tracing::info!(
                        bundle_id = %config.bundle_id,
                        quant = %config.quant,
                        "loaded session summarizer model"
                    );
                    engine = Some(loaded);
                }
                Err(error) => {
                    tracing::error!(%error, "failed to load summarizer model; snippets disabled");
                    load_failed = true;
                }
            }
        }
        // One place that answers when there is no model, rather than one per
        // way of getting here. A judge job left unanswered blocks its caller
        // until that caller's own timeout, for an answer that will never come.
        let Some(engine) = engine.as_ref() else {
            if let Job::Judge(job) = job {
                reply_to(&job, JudgeVerdict::fallback("local model failed to load"));
            }
            continue;
        };

        match job {
            Job::Judge(job) => run_judge_job(engine, &job),
            Job::Summarize(job) => run_summarize_job(engine, &config, &queue, job, &on_result),
        }
    }
}

/// Judges one tool call and replies. Any inference failure becomes a fallback
/// `ask` rather than propagating, so the caller always gets an answer.
fn run_judge_job(engine: &cera::CeraEngine, job: &JudgeJob) {
    let verdict = match crate::judge::judge_with_model(engine, &job.request) {
        Ok(verdict) => verdict,
        Err(error) => {
            tracing::warn!(%error, "judge inference failed; answering ask");
            JudgeVerdict::fallback("local model could not decide")
        }
    };
    reply_to(job, verdict);
}

/// Sends a verdict back, tolerating a caller that has already timed out.
fn reply_to(job: &JudgeJob, verdict: JudgeVerdict) {
    if job.reply.try_send(verdict).is_err() {
        tracing::debug!("judge caller stopped waiting before the verdict arrived");
    }
}

/// Runs the two summary passes for one session, abandoning the job if a judge
/// job preempts it. A preempted summary is simply dropped: the debounce loop
/// re-enqueues on the next settle, so nothing is lost by giving up here.
fn run_summarize_job(
    engine: &cera::CeraEngine,
    config: &SummarizerConfig,
    queue: &JobQueue,
    job: SummarizeJob,
    on_result: &impl Fn(SnippetResult),
) {
    if queue.has_pending_judge() {
        tracing::debug!(
            session_id = %job.session_id,
            "summarize job preempted before start by judge job"
        );
        return;
    }
    match generate_one_line(engine, config, queue, &job.prompt_text) {
        Ok(Some(text)) => {
            // Second, longer-form pass for the hover popover / search, skipped
            // when a judge job is already waiting: that caller is blocking an
            // agent, and the debounce loop regenerates the detail on the next
            // settle anyway. Failures here are non-fatal, so a missing detail
            // still emits the one-liner rather than dropping the result.
            let detail = if queue.has_pending_judge() {
                None
            } else {
                generate_detail(
                    engine,
                    config,
                    queue,
                    &job.prompt_text,
                    job.context.as_ref(),
                    job.cwd.as_deref(),
                )
                .unwrap_or_else(|error| {
                    if error
                        .downcast_ref::<cera::session::CeraError>()
                        .is_some_and(|e| matches!(e, cera::session::CeraError::Cancelled))
                    {
                        tracing::debug!(
                            session_id = %job.session_id,
                            "detail summary generation preempted by judge job"
                        );
                    } else {
                        tracing::warn!(
                            %error,
                            session_id = %job.session_id,
                            "detail summary generation failed"
                        );
                    }
                    None
                })
            };
            on_result(SnippetResult {
                session_id: job.session_id,
                text,
                detail,
                generated_at_output_seq: job.output_seq,
            });
        }
        Ok(None) => {
            tracing::debug!(
                session_id = %job.session_id,
                "snippet generation produced empty output (dropped)"
            )
        }
        Err(error) => {
            if error
                .downcast_ref::<cera::session::CeraError>()
                .is_some_and(|e| matches!(e, cera::session::CeraError::Cancelled))
            {
                tracing::debug!(
                    session_id = %job.session_id,
                    "snippet generation preempted by judge job"
                );
            } else {
                tracing::warn!(%error, session_id = %job.session_id, "snippet generation failed");
            }
        }
    }
}

fn load_engine(config: &SummarizerConfig) -> Result<cera::CeraEngine, cera::session::CeraError> {
    let repo = cera::bundle::BundleRepo::new(&config.cache_dir);
    let engine_config = cera::EngineConfig {
        context_size: config.context_size as usize,
        backend: cera::BackendPreference::Auto,
        bundle_repo: Some(repo),
    };
    cera::CeraEngine::from_bundle_id(&config.bundle_id, &config.quant, engine_config)
}

/// Runs one inference and returns a sanitized one-line snippet, or `None` if the
/// model produced nothing usable (so we don't overwrite a good prior snippet).
fn generate_one_line(
    engine: &cera::CeraEngine,
    config: &SummarizerConfig,
    queue: &JobQueue,
    prompt_text: &str,
) -> anyhow::Result<Option<String>> {
    let mut session = engine.new_session(cera::SessionConfig::default())?;
    let cancel = session.cancel_handle();
    let _in_flight = queue.register_summary(Arc::clone(&cancel));
    let messages = [
        ChatMessage {
            role: "system".to_string(),
            content: SYSTEM_PROMPT.to_string(),
        },
        ChatMessage {
            role: "user".to_string(),
            content: prompt_text.to_string(),
        },
    ];
    let rendered = cera::tokenizer::apply_chat_template(engine.tokenizer(), &messages, true)?;
    session.append_text(&rendered)?;
    if queue.has_pending_judge() {
        cancel.store(true, Ordering::Relaxed);
        return Ok(None);
    }

    let mut sink = OneLineSink::new(engine.tokenizer());
    // Sampled per the bundle manifest, like the detail pass: a label's run-to-run
    // variance is a rewording of the same fact, so the manifest's tuning is worth
    // more than a byte-stable rail.
    let opts = sampling_opts(engine, config.max_tokens);
    session.generate(&opts, &mut sink)?;
    if cancel.load(Ordering::Relaxed) && !sink.is_complete() {
        // Preempted by a judge job mid-label, so the text so far is a fragment,
        // which would be worse than the snippet already on screen. A cancel that
        // lands after the label finished is harmless and the result is kept:
        // nothing here ends decode at the label, so a finished one sits in the
        // sink while decode runs out its token budget, and that window is wide
        // enough that discarding it would throw away good results routinely.
        return Ok(None);
    }

    Ok(sanitize_one_line(&sink.text, sink.cut_short()))
}

/// Runs one inference for the longer-form detail summary and returns it
/// sanitized, with a deterministic `repo · branch · worktree` header prepended
/// (or directory fallback) so the reader can localize the session at a glance.
/// Returns `None` only when neither the model nor the location produced
/// anything usable.
fn generate_detail(
    engine: &cera::CeraEngine,
    config: &SummarizerConfig,
    queue: &JobQueue,
    prompt_text: &str,
    context: Option<&SessionContext>,
    cwd: Option<&std::path::Path>,
) -> anyhow::Result<Option<String>> {
    let mut session = engine.new_session(cera::SessionConfig::default())?;
    let cancel = session.cancel_handle();
    let _in_flight = queue.register_summary(Arc::clone(&cancel));
    let messages = [
        ChatMessage {
            role: "system".to_string(),
            content: DETAIL_SYSTEM_PROMPT.to_string(),
        },
        ChatMessage {
            role: "user".to_string(),
            content: prompt_text.to_string(),
        },
    ];
    let rendered = cera::tokenizer::apply_chat_template(engine.tokenizer(), &messages, true)?;
    session.append_text(&rendered)?;
    if queue.has_pending_judge() {
        cancel.store(true, Ordering::Relaxed);
        return Ok(None);
    }

    let mut sink = TextSink::new(engine.tokenizer());
    let opts = sampling_opts(engine, config.detail_max_tokens);
    session.generate(&opts, &mut sink)?;
    if cancel.load(Ordering::Relaxed) {
        // Preempted mid-detail. Keep the one-line label the caller already has
        // and drop the partial paragraph.
        return Ok(None);
    }

    let header = context
        .and_then(SessionContext::localization_label)
        .or_else(|| cwd.and_then(triage_core::session::path_leaf_name));
    let summary = sanitize_detail(&sink.text, sink.cut_short());
    Ok(match (header, summary) {
        (Some(header), Some(summary)) => Some(format!("{header}\n{summary}")),
        (Some(header), None) => Some(header),
        (None, summary) => summary,
    })
}

/// Builds [`GenerateOpts`] for the summarizer's generative passes: both the
/// one-line rail label and the longer detail summary.
///
/// When the loaded model is a text bundle whose LeapBundles manifest ships
/// advisory `sampling_parameters`, honor them: start from cera's own defaults
/// and apply every param the manifest carries (temperature / min-p / top-p /
/// top-k / repetition-penalty), so a param the manifest *omits* keeps cera's
/// default rather than being forced off. In particular a manifest that sets
/// top-p/top-k but no temperature still samples (at cera's default temperature)
/// instead of collapsing to greedy.
///
/// A manifest that carries no sampling guidance at all — a `Text` block with
/// every field unset, a bare GGUF, or a non-text inference type — falls back to
/// deterministic greedy decoding (temperature 0) so output is stable across
/// regenerations.
///
/// The judge's decision decode deliberately does not use this and stays greedy
/// whatever the manifest says; `judge_with_model` explains why, and
/// `devlog/000126-feat-approval-judge.md` has the measurement behind it.
///
/// Both the `GenerationDefaults` match and the `Text` destructure are
/// exhaustive (no wildcard arm, no `..`) on purpose: if cera grows another
/// manifest sampling param, or a variant that carries one, this stops compiling
/// so we wire it through rather than silently dropping it.
fn sampling_opts(engine: &cera::CeraEngine, max_tokens: u32) -> cera::GenerateOpts {
    sampling_opts_from_defaults(&engine.manifest().generation_defaults, max_tokens)
}

/// Engine-free core of [`sampling_opts`] — splits the decision out from the
/// `CeraEngine` so the manifest→opts mapping is unit-testable.
fn sampling_opts_from_defaults(
    defaults: &GenerationDefaults,
    max_tokens: u32,
) -> cera::GenerateOpts {
    // Start from cera's real defaults; the greedy fallback below only kicks in
    // when the manifest provides no guidance at all.
    let mut opts = cera::GenerateOpts {
        max_tokens,
        ..Default::default()
    };
    match defaults {
        GenerationDefaults::Text {
            temperature,
            min_p,
            top_p,
            top_k,
            repetition_penalty,
        } => {
            // Honor the manifest only when its `Text` block actually carries a
            // sampling param. An all-`None` block falls through to greedy rather
            // than silently inheriting cera's sampling default temperature.
            let has_sampling_params = temperature.is_some()
                || min_p.is_some()
                || top_p.is_some()
                || top_k.is_some()
                || repetition_penalty.is_some();
            if has_sampling_params {
                if let Some(temperature) = temperature {
                    opts.temperature = *temperature;
                }
                if let Some(min_p) = min_p {
                    opts.min_p = *min_p;
                }
                if let Some(top_p) = top_p {
                    opts.top_p = *top_p;
                }
                if let Some(top_k) = top_k {
                    opts.top_k = *top_k;
                }
                if let Some(repetition_penalty) = repetition_penalty {
                    opts.repetition_penalty = *repetition_penalty;
                }
                return opts;
            }
        }
        // Both fall through to greedy, for different reasons. `Audio` carries no
        // text sampling params at all. `Other` holds the raw
        // `generation_time_parameters` JSON of an inference type cera does not
        // model, which *may* contain them: reading them would mean guessing at
        // the shape of a manifest written for something this daemon does not
        // load, so the deliberate choice is to drop them. Listed rather than
        // folded into a wildcard so a future cera variant stops this compiling.
        GenerationDefaults::Audio { .. } | GenerationDefaults::Other { .. } => {}
    }
    // No manifest sampling guidance: deterministic greedy decoding.
    opts.temperature = 0.0;
    opts
}

/// A [`ModalitySink`] that accumulates all decoded text. Shared by the detail
/// summary here and by the judge's decision decode, which want the same thing:
/// every token, concatenated. The one-line label needs different behaviour and
/// keeps its own sink.
pub(crate) struct TextSink<'a> {
    tokenizer: &'a BpeTokenizer,
    pub(crate) text: String,
    /// How decode ended. The detail pass marks a summary that ran out of room;
    /// the judge ignores it, since a grammar-constrained verdict is either
    /// parseable or rejected outright.
    finish: Option<FinishReason>,
}

impl<'a> TextSink<'a> {
    pub(crate) fn new(tokenizer: &'a BpeTokenizer) -> Self {
        Self {
            tokenizer,
            text: String::new(),
            finish: None,
        }
    }

    fn cut_short(&self) -> bool {
        decode_cut_short(self.finish.as_ref())
    }
}

impl ModalitySink for TextSink<'_> {
    fn on_text_tokens(&mut self, tokens: &[u32]) {
        self.text.push_str(&self.tokenizer.decode(tokens));
    }

    fn on_done(&mut self, reason: FinishReason) {
        self.finish = Some(reason);
    }
}

/// Normalizes the raw detail output: trims, collapses blank-line runs and
/// internal whitespace, caps at [`MAX_DETAIL_CHARS`]. Returns `None` if empty.
///
/// `cut_short` reports that decode ran out of room, which matters here as much
/// as on the label: the token budget can be spent well before the character cap
/// on a summary dense in the paths and command names the prompt asks for, and
/// that ends the paragraph mid-sentence with nothing in the text to show it.
fn sanitize_detail(raw: &str, cut_short: bool) -> Option<String> {
    // Collapse all whitespace (including newlines) to single spaces — the
    // popover renders it as a wrapped paragraph.
    let collapsed: String = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    let (capped, truncated) = cap_chars(collapsed.trim(), MAX_DETAIL_CHARS)?;
    Some(if truncated || cut_short {
        mark_truncated(capped)
    } else {
        capped
    })
}

/// A [`ModalitySink`] that accumulates decoded text up to the newline that ends
/// the label, skipping any blank lines the model opens with. See
/// [`push_label_chunk`], which holds the rule and is where to change it.
struct OneLineSink<'a> {
    tokenizer: &'a BpeTokenizer,
    text: String,
    stopped: bool,
    /// How decode ended, recorded because the caller cannot otherwise tell a
    /// label the model finished from one that decode cut off. `None` until
    /// `on_done` runs, which reads as neither finished nor cut.
    finish: Option<FinishReason>,
}

impl<'a> OneLineSink<'a> {
    fn new(tokenizer: &'a BpeTokenizer) -> Self {
        Self {
            tokenizer,
            text: String::new(),
            stopped: false,
            finish: None,
        }
    }

    fn is_complete(&self) -> bool {
        label_is_complete(self.stopped, self.finish.as_ref())
    }

    fn cut_short(&self) -> bool {
        label_cut_short(self.stopped, self.finish.as_ref())
    }
}

/// Whether the label is a whole thought rather than a fragment. True when its
/// terminating newline arrived, and also when decode ended on EOS: the prompt
/// asks for the label and nothing else, so a model that obeys it ends that way
/// and never emits a newline at all.
///
/// Split from [`OneLineSink`], as [`push_label_chunk`] is, so the rule is
/// testable without a [`BpeTokenizer`].
fn label_is_complete(stopped: bool, finish: Option<&FinishReason>) -> bool {
    stopped || matches!(finish, Some(FinishReason::Stop))
}

/// Whether decode ran out of room mid-label, by either the token budget or the
/// context window. Only meaningful before the terminating newline: after it the
/// sink is discarding tokens anyway, so how decode ended says nothing about the
/// label.
///
/// A cancel is deliberately not counted: the caller drops an incomplete label
/// outright rather than marking it. Nor is `Error`, whose outer `Result` is the
/// authoritative channel and propagates before this is consulted.
fn label_cut_short(stopped: bool, finish: Option<&FinishReason>) -> bool {
    !stopped && decode_cut_short(finish)
}

/// Whether decode stopped for want of room rather than because the model was
/// done. Every other outcome reads as not cut, which is the safe direction: a
/// cancel the caller drops rather than marks, an error whose outer `Result`
/// propagates before this is consulted, a grammar dead end that no summarizer
/// decode can reach (neither pass sets one), and `None` from an `on_done` that
/// never ran.
fn decode_cut_short(finish: Option<&FinishReason>) -> bool {
    matches!(
        finish,
        Some(FinishReason::MaxTokens | FinishReason::ContextFull)
    )
}

/// Appends the truncation marker, unless the text already ends in one. A model
/// that trails off on its own ("checking configs...") and then hits the token
/// budget would otherwise render a doubled marker.
fn mark_truncated(mut text: String) -> String {
    if text.ends_with('…') || text.ends_with("...") {
        text
    } else {
        text.push('…');
        text
    }
}

impl ModalitySink for OneLineSink<'_> {
    fn on_text_tokens(&mut self, tokens: &[u32]) {
        if self.stopped {
            return;
        }
        let decoded = self.tokenizer.decode(tokens);
        self.stopped = push_label_chunk(&mut self.text, &decoded);
    }

    fn on_done(&mut self, reason: FinishReason) {
        self.finish = Some(reason);
    }
}

/// Appends one decoded chunk to a one-line label, returning `true` once the
/// newline that ends the label has arrived.
///
/// A newline arriving before any content is the model opening with a blank
/// line, not ending the label. Treating that as terminal would leave the label
/// empty, and an empty label drops the whole job including the detail pass, so
/// leading whitespace is skipped rather than accepted as the end.
///
/// Split out from [`OneLineSink`] so this is testable without a tokenizer.
fn push_label_chunk(text: &mut String, decoded: &str) -> bool {
    let pending = if text.trim().is_empty() {
        decoded.trim_start()
    } else {
        decoded
    };
    match pending.find('\n') {
        Some(newline) => {
            text.push_str(&pending[..newline]);
            true
        }
        None => {
            text.push_str(pending);
            false
        }
    }
}

/// Normalizes raw model output into a single short label, or `None` if empty.
/// `cut_short` reports that decode ran out of room mid-label, which the text
/// alone cannot show: a fragment that happens to fit both caps is
/// indistinguishable from a finished label, and is marked as cut on this word.
fn sanitize_one_line(raw: &str, cut_short: bool) -> Option<String> {
    // `trim_start` before splitting, so a leading blank line is skipped rather
    // than read as an empty first line. This is the same rule
    // [`push_label_chunk`] applies as tokens arrive, and the two halves have to
    // agree: the sink's output is what usually lands here, but this function is
    // also reachable with raw text.
    let first_line = raw.trim_start().lines().next().unwrap_or("").trim();
    // Collapse internal whitespace runs to single spaces.
    let collapsed: String = first_line.split_whitespace().collect::<Vec<_>>().join(" ");
    // Strip a single layer of wrapping quotes/backticks.
    let unquoted = collapsed
        .strip_prefix(['"', '\'', '`'])
        .and_then(|s| s.strip_suffix(['"', '\'', '`']))
        .unwrap_or(&collapsed)
        .trim();
    // Cap by words, then by characters. Both caps mark what they cut, for the
    // same reason the detail pass does: the rail shows the whole label, so a
    // silent cut reads as the model's finished answer rather than a fragment.
    let word_truncated = unquoted.split(' ').count() > MAX_SNIPPET_WORDS;
    let word_capped: String = unquoted
        .split(' ')
        .take(MAX_SNIPPET_WORDS)
        .collect::<Vec<_>>()
        .join(" ");
    let (capped, char_truncated) = cap_chars(&word_capped, MAX_SNIPPET_CHARS)?;
    Some(if word_truncated || char_truncated || cut_short {
        mark_truncated(capped)
    } else {
        capped
    })
}

/// Caps `text` at `max_chars`, trimming any trailing space the cut exposes.
/// Returns the capped text and whether anything was removed, or `None` when the
/// result is empty. Shared by both sanitizers so their two caps cannot drift.
///
/// Counts characters rather than bytes: these caps exist to bound what the
/// client renders, and a byte cap would both cut multi-byte text short and risk
/// slicing mid-character.
fn cap_chars(text: &str, max_chars: usize) -> Option<(String, bool)> {
    let (slice, was_cut) = match text.char_indices().nth(max_chars) {
        Some((idx, _)) => (&text[..idx], true),
        None => (text, false),
    };
    let capped = slice.trim_end();
    // Compared against the trimmed source, so cutting nothing but trailing
    // whitespace does not count: no content was lost, and reporting truncation
    // would put a marker on a complete string.
    let truncated = if was_cut {
        capped.len() < text.trim_end().len()
    } else {
        false
    };
    (!capped.is_empty()).then(|| (capped.to_string(), truncated))
}

/// Builds the prompt text fed to the model from a session's visible rows:
/// captures initial rows (preserving the session's launch command, main task, or
/// initial body of work) and recent activity rows (capturing current state and
/// progress), capped at `MAX_PROMPT_CHARS`. Returns `None` when the screen is
/// effectively empty.
pub fn build_prompt_text(visible_rows: &[String]) -> Option<String> {
    const MAX_HEAD_ROWS: usize = 8;
    const MAX_TAIL_ROWS: usize = 16;
    const MAX_COMBINED_ROWS: usize = MAX_HEAD_ROWS + MAX_TAIL_ROWS;
    const MAX_PROMPT_CHARS: usize = 1500;

    let kept: Vec<&str> = visible_rows
        .iter()
        .map(|row| row.trim_end())
        .filter(|row| !row.is_empty())
        .collect();
    if kept.is_empty() {
        return None;
    }

    let text = if kept.len() <= MAX_COMBINED_ROWS {
        kept.join("\n")
    } else {
        let head = &kept[..MAX_HEAD_ROWS];
        let tail_start = kept.len().saturating_sub(MAX_TAIL_ROWS);
        let tail = &kept[tail_start..];
        format!("{}\n[...]\n{}", head.join("\n"), tail.join("\n"))
    };

    let mut text = text;
    if text.chars().count() > MAX_PROMPT_CHARS {
        let skip = text.chars().count() - MAX_PROMPT_CHARS;
        text = text.chars().skip(skip).collect();
    }
    Some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn judge_request(command: &str) -> JudgeRequest {
        JudgeRequest {
            session_id: SessionId::new("s").expect("valid session id"),
            tool_name: "run_command".to_string(),
            command_line: Some(command.to_string()),
            path: None,
            cwd: None,
        }
    }

    fn summarize_job(session: &str, output_seq: u64) -> SummarizeJob {
        SummarizeJob {
            session_id: SessionId::new(session).expect("valid session id"),
            prompt_text: format!("screen at {output_seq}"),
            output_seq,
            context: None,
            cwd: None,
        }
    }

    /// Pushes a judge job and returns the receiver, asserting it was accepted.
    fn push_judge(queue: &JobQueue, command: &str) -> std::sync::mpsc::Receiver<JudgeVerdict> {
        let (reply, verdicts) = sync_channel(1);
        assert!(
            queue
                .push_judge(JudgeJob {
                    request: judge_request(command),
                    reply,
                })
                .is_ok()
        );
        verdicts
    }

    #[test]
    fn judge_jobs_jump_ahead_of_queued_summaries() {
        // A judge call blocks an agent's tool loop; a rail label is cosmetic. So
        // a judge job queued last must still be served first.
        let queue = Arc::new(JobQueue::new(8));
        queue.push_summarize(summarize_job("a", 1));
        queue.push_summarize(summarize_job("b", 1));
        let _verdicts = push_judge(&queue, "ls");

        assert!(matches!(queue.next_job(), Some(Job::Judge(_))));
        assert!(matches!(queue.next_job(), Some(Job::Summarize(_))));
        assert!(matches!(queue.next_job(), Some(Job::Summarize(_))));
        // Drained, and no handles left but this one, so the worker retires.
        assert!(queue.next_job().is_none());
    }

    #[test]
    fn summarize_jobs_coalesce_per_session_keeping_the_newest_screen() {
        let queue = Arc::new(JobQueue::new(8));
        queue.push_summarize(summarize_job("a", 1));
        queue.push_summarize(summarize_job("a", 7));
        // An older screen must not overwrite a newer one already queued.
        queue.push_summarize(summarize_job("a", 3));

        let Some(Job::Summarize(job)) = queue.next_job() else {
            panic!("expected a summarize job");
        };
        assert_eq!(job.output_seq, 7);
        assert!(queue.next_job().is_none(), "only one job per session");
    }

    #[test]
    fn a_pending_judge_job_is_visible_between_summary_passes() {
        // The cancel handle only covers a generation that is actually running,
        // so the gap between the one-line and detail passes needs this check or
        // a judge job landing there waits out a whole detail summary.
        let queue = Arc::new(JobQueue::new(8));
        assert!(!queue.has_pending_judge());

        let _verdicts = push_judge(&queue, "ls");
        assert!(queue.has_pending_judge());

        assert!(matches!(queue.next_job(), Some(Job::Judge(_))));
        assert!(!queue.has_pending_judge(), "draining clears it");
    }

    #[test]
    fn a_full_judge_queue_is_rejected_rather_than_queued() {
        // Rejection becomes a fallback `ask` at the caller, which is far better
        // than queueing behind work the caller will outlive.
        let queue = Arc::new(JobQueue::new(2));
        let _first = push_judge(&queue, "one");
        let _second = push_judge(&queue, "two");

        let (reply, _verdicts) = sync_channel(1);
        assert_eq!(
            queue.push_judge(JudgeJob {
                request: judge_request("three"),
                reply,
            }),
            Err("judge queue is full")
        );
    }

    #[test]
    fn queueing_a_judge_job_cancels_the_running_summary() {
        let queue = Arc::new(JobQueue::new(8));
        let cancel = Arc::new(AtomicBool::new(false));
        let guard = queue.register_summary(Arc::clone(&cancel));

        let _verdicts = push_judge(&queue, "ls");
        assert!(
            cancel.load(Ordering::Relaxed),
            "an arriving judge job must preempt the running summary"
        );
        drop(guard);
    }

    #[test]
    fn a_judge_job_queued_before_registration_still_preempts() {
        // The load-bearing half of the race fix: `register_summary` publishes
        // the handle and then re-checks the queue. Without that re-check a judge
        // job arriving in the window between the worker's own check and this
        // registration is seen by neither side, and the summary runs to
        // completion while a blocked agent waits out its timeout.
        let queue = Arc::new(JobQueue::new(8));
        let _verdicts = push_judge(&queue, "ls");

        let cancel = Arc::new(AtomicBool::new(false));
        let _guard = queue.register_summary(Arc::clone(&cancel));
        assert!(
            cancel.load(Ordering::Relaxed),
            "a summary starting while a judge job waits must cancel immediately"
        );
    }

    #[test]
    fn a_finished_summary_is_not_preempted_after_the_fact() {
        // The guard must clear the slot when a generation ends, or a later judge
        // job would flip a handle belonging to a summary that is already over.
        // With cera's `clear_cancel` reusing sessions, a leaked flag would abort
        // the *next* generation instead.
        let queue = Arc::new(JobQueue::new(8));
        let cancel = Arc::new(AtomicBool::new(false));
        let guard = queue.register_summary(Arc::clone(&cancel));
        drop(guard);

        let _verdicts = push_judge(&queue, "ls");
        assert!(
            !cancel.load(Ordering::Relaxed),
            "a summary that already finished must not be cancelled retroactively"
        );
    }

    #[test]
    fn a_disabled_summarizer_judges_ask_without_blocking() {
        let summarizer = Summarizer::disabled();
        assert!(!summarizer.is_enabled());
        let verdict = summarizer.judge(judge_request("rm -rf /"), Duration::from_secs(5));
        assert_eq!(verdict.decision, triage_core::judge::JudgeDecision::Ask);
        assert_eq!(verdict.source, triage_core::judge::JudgeSource::Fallback);
    }

    #[test]
    fn a_label_is_complete_on_its_newline_or_on_eos() {
        // EOS is the common completion: the prompt asks for the label and
        // nothing else, so an obedient model never emits the newline.
        assert!(label_is_complete(false, Some(&FinishReason::Stop)));
        assert!(label_is_complete(true, Some(&FinishReason::MaxTokens)));
        // Running out of room mid-label is not completion.
        assert!(!label_is_complete(false, Some(&FinishReason::MaxTokens)));
        assert!(!label_is_complete(false, Some(&FinishReason::ContextFull)));
        assert!(!label_is_complete(false, Some(&FinishReason::Cancelled)));
        // `on_done` never ran, so nothing is known: not complete.
        assert!(!label_is_complete(false, None));
    }

    #[test]
    fn a_label_is_cut_short_only_when_decode_ran_out_of_room() {
        assert!(label_cut_short(false, Some(&FinishReason::MaxTokens)));
        assert!(label_cut_short(false, Some(&FinishReason::ContextFull)));
        // Past the newline the label is whole, whatever decode did afterwards.
        assert!(!label_cut_short(true, Some(&FinishReason::MaxTokens)));
        // A cancel is dropped by the caller, not marked; EOS is a clean end.
        assert!(!label_cut_short(false, Some(&FinishReason::Cancelled)));
        assert!(!label_cut_short(false, Some(&FinishReason::Stop)));
        assert!(!label_cut_short(false, None));
    }

    #[test]
    fn label_chunks_skip_a_leading_blank_line() {
        // The model opening with a newline must not end the label: an empty
        // label drops the detail pass with it.
        let mut text = String::new();
        assert!(!push_label_chunk(&mut text, "\n"));
        assert!(!push_label_chunk(&mut text, "  \n "));
        assert!(!push_label_chunk(&mut text, "Running"));
        assert_eq!(text, "Running");
        // Once there is content, the next newline does end it.
        assert!(push_label_chunk(&mut text, " tests\nand more"));
        assert_eq!(text, "Running tests");
    }

    #[test]
    fn label_chunk_ends_on_a_newline_within_one_chunk() {
        let mut text = String::new();
        assert!(push_label_chunk(
            &mut text,
            "\n\nBuilding docs\nsecond line"
        ));
        assert_eq!(text, "Building docs");
    }

    #[test]
    fn sanitize_strips_quotes_and_caps_words() {
        assert_eq!(
            sanitize_one_line("\"running cargo test\"", false),
            Some("running cargo test".to_string())
        );
        // Over the word cap: marked, so the rail does not present a fragment as
        // the model's finished answer.
        assert_eq!(
            sanitize_one_line("one two three four five six seven eight nine ten", false),
            Some("one two three four five six seven eight…".to_string())
        );
        // Exactly at the cap is not truncation, so it carries no marker.
        assert_eq!(
            sanitize_one_line("one two three four five six seven eight", false),
            Some("one two three four five six seven eight".to_string())
        );
        assert_eq!(
            sanitize_one_line("first line\nsecond line", false),
            Some("first line".to_string())
        );
        assert_eq!(sanitize_one_line("   \n  ", false), None);
    }

    #[test]
    fn sanitize_detail_marks_a_decode_cut() {
        // Well under the character cap, so only the finish reason reveals that
        // the token budget ended the paragraph mid-sentence.
        assert_eq!(
            sanitize_detail("Running cargo test. Compiling triaged and", true),
            Some("Running cargo test. Compiling triaged and…".to_string())
        );
        assert_eq!(
            sanitize_detail("Running cargo test.", false),
            Some("Running cargo test.".to_string())
        );
    }

    #[test]
    fn sanitize_one_line_skips_a_leading_blank_line() {
        // Matches `push_label_chunk`: a leading newline is not an empty label.
        assert_eq!(
            sanitize_one_line("\n\nrunning cargo test", false),
            Some("running cargo test".to_string())
        );
    }

    #[test]
    fn a_truncation_marker_is_never_stacked() {
        // The model trailing off on its own, then hitting the token budget.
        assert_eq!(
            sanitize_one_line("checking configs...", true),
            Some("checking configs...".to_string())
        );
        assert_eq!(
            sanitize_one_line("checking configs…", true),
            Some("checking configs…".to_string())
        );
        assert_eq!(
            sanitize_detail("Reading the manifest…", true),
            Some("Reading the manifest…".to_string())
        );
    }

    #[test]
    fn cap_chars_ignores_trailing_whitespace_it_cuts() {
        // Only spaces fell past the cap, so no content was lost and nothing
        // should be marked.
        assert_eq!(
            cap_chars("abc    ", 3),
            Some(("abc".to_string(), false)),
            "trailing whitespace alone is not truncation"
        );
        assert_eq!(cap_chars("abcdef", 3), Some(("abc".to_string(), true)));
        assert_eq!(cap_chars("abc", 8), Some(("abc".to_string(), false)));
        assert_eq!(cap_chars("   ", 2), None);
    }

    #[test]
    fn sanitize_one_line_marks_a_decode_cut() {
        // Fits both caps, so only the decode's finish reason reveals that the
        // model was cut off mid-thought rather than finished.
        assert_eq!(
            sanitize_one_line("running cargo", true),
            Some("running cargo…".to_string())
        );
        // Marked once, not twice, when a cap also fired.
        let both = sanitize_one_line("one two three four five six seven eight nine", true)
            .expect("non-empty");
        assert!(both.ends_with('…') && !both.ends_with("……"), "{both:?}");
    }

    #[test]
    fn sanitize_one_line_marks_a_character_cap_cut() {
        // Under the word cap but over the character cap, so only the char branch
        // fires. The ellipsis is added after the cap, hence the + 1.
        let long_words = "aaaaaaaaaa ".repeat(MAX_SNIPPET_WORDS - 1) + "bbbbbbbbbb";
        let capped = sanitize_one_line(&long_words, false).expect("non-empty");
        assert!(capped.ends_with('…'), "{capped:?}");
        assert_eq!(capped.chars().count(), MAX_SNIPPET_CHARS + 1, "{capped:?}");
        assert!(
            !capped.contains("  "),
            "a cut at a space must not leave a dangling one: {capped:?}"
        );
    }

    #[test]
    fn sanitize_detail_collapses_whitespace_and_caps() {
        assert_eq!(
            sanitize_detail("  Running cargo test.\n\nAll 83 tests passed.  ", false),
            Some("Running cargo test. All 83 tests passed.".to_string())
        );
        assert_eq!(sanitize_detail("   \n\n  ", false), None);
        let long = "word ".repeat(100);
        let capped = sanitize_detail(&long, false).expect("non-empty");
        assert!(capped.chars().count() <= MAX_DETAIL_CHARS + 1, "{capped:?}");
        assert!(capped.ends_with('…'), "{capped:?}");
    }

    #[test]
    fn build_prompt_drops_blank_rows_and_keeps_tail() {
        let rows = vec![
            "".to_string(),
            "$ cargo build   ".to_string(),
            "   ".to_string(),
            "Compiling triaged".to_string(),
        ];
        let prompt = build_prompt_text(&rows).expect("non-empty");
        assert_eq!(prompt, "$ cargo build\nCompiling triaged");
        assert_eq!(build_prompt_text(&[]), None);
        assert_eq!(build_prompt_text(&["".to_string(), "  ".to_string()]), None);
    }

    #[test]
    fn build_prompt_preserves_head_and_tail_on_long_output() {
        let mut rows = Vec::new();
        rows.push("$ cargo build --release".to_string());
        for i in 1..=40 {
            rows.push(format!("line {i}"));
        }
        rows.push("$ echo done".to_string());
        let prompt = build_prompt_text(&rows).expect("non-empty");
        assert!(prompt.starts_with("$ cargo build --release\nline 1\nline 2"));
        assert!(prompt.contains("\n[...]\n"));
        assert!(prompt.ends_with("line 40\n$ echo done"));
    }

    // End-to-end: downloads the real LFM2 model (~1.5GB, cached) and runs
    // inference. Ignored so CI never pays the download; run manually with:
    //   cargo test -p triaged --release -- --ignored end_to_end --nocapture
    #[test]
    #[ignore = "downloads ~1.5GB model and runs local inference"]
    fn end_to_end_generates_a_snippet() {
        use std::sync::mpsc;
        use std::time::Duration;
        use triage_core::session::SessionId;

        let config = SummarizerConfig {
            bundle_id: "LFM2-2.6B-GGUF".to_string(),
            quant: "Q4_K_M".to_string(),
            context_size: 1024,
            max_tokens: 24,
            detail_max_tokens: 96,
            cache_dir: crate::session::default_model_cache_dir(),
            judge_queue_depth: 4,
        };

        let (tx, rx) = mpsc::channel();
        let summarizer = Summarizer::spawn(config, move |result| {
            let _ = tx.send(result);
        });
        assert!(summarizer.is_enabled(), "summarizer should spawn");

        let prompt = build_prompt_text(&[
            "user@host project % cargo test".to_string(),
            "   Compiling triaged v0.1.5".to_string(),
            "    Finished `test` profile in 4.2s".to_string(),
            "running 83 tests".to_string(),
            "test result: ok. 83 passed; 0 failed".to_string(),
        ])
        .expect("prompt");

        assert!(summarizer.try_enqueue(SummarizeJob {
            session_id: SessionId::new("e2e").unwrap(),
            prompt_text: prompt,
            output_seq: 1,
            context: Some(SessionContext {
                repository_root: Some("/home/dev/triage".into()),
                worktree_root: Some("/home/dev/triage/worktrees/feat-summary".into()),
                branch: Some("feat/summary".to_string()),
            }),
            cwd: None,
        }));

        // First call downloads the model, so allow a generous timeout.
        let result = rx
            .recv_timeout(Duration::from_secs(600))
            .expect("a snippet within timeout");
        eprintln!("GENERATED SNIPPET: {:?}", result.text);
        eprintln!("GENERATED DETAIL: {:?}", result.detail);
        assert!(!result.text.is_empty(), "snippet should be non-empty");
        assert!(
            result.text.split_whitespace().count() <= MAX_SNIPPET_WORDS,
            "snippet should respect the word cap: {:?}",
            result.text
        );
        // The detail must lead with the deterministic localization header.
        let detail = result.detail.expect("detail summary present");
        assert!(
            detail.starts_with("triage  ·  feat/summary  ·  feat-summary"),
            "detail should lead with the repo/branch/worktree header: {detail:?}"
        );
    }

    #[test]
    fn sampling_opts_without_temperature_samples_at_cera_default() {
        // Manifest recommends top-p/top-k but omits temperature: we must NOT
        // collapse to greedy, or those params never take effect. Temperature
        // stays at cera's sampling default so the recommendation is honored.
        let cera_default = cera::GenerateOpts::default();
        let opts = sampling_opts_from_defaults(
            &GenerationDefaults::Text {
                temperature: None,
                min_p: None,
                top_p: Some(0.5),
                top_k: Some(20),
                repetition_penalty: None,
            },
            99,
        );
        assert_eq!(opts.max_tokens, 99);
        assert!(
            (opts.temperature - cera_default.temperature).abs() < 1e-6,
            "temperature should fall back to cera's default, not greedy: {}",
            opts.temperature
        );
        assert!(opts.temperature > 0.0, "must stay stochastic, not greedy");
        assert!((opts.top_p - 0.5).abs() < 1e-6);
        assert_eq!(opts.top_k, 20);
    }

    #[test]
    fn sampling_opts_with_all_params_unset_is_greedy() {
        // A `Text` block that carries no sampling guidance falls back to
        // deterministic greedy decoding (temperature 0).
        let opts = sampling_opts_from_defaults(
            &GenerationDefaults::Text {
                temperature: None,
                min_p: None,
                top_p: None,
                top_k: None,
                repetition_penalty: None,
            },
            32,
        );
        assert!(
            opts.temperature.abs() < 1e-6,
            "all-unset manifest should be greedy: {}",
            opts.temperature
        );
    }

    #[test]
    fn sampling_opts_non_text_manifest_is_greedy() {
        // A non-text manifest (here: audio) carries no text sampling params, so
        // both generative passes stay greedy.
        let opts = sampling_opts_from_defaults(
            &GenerationDefaults::Audio {
                number_of_decoding_threads: None,
            },
            32,
        );
        assert!(
            opts.temperature.abs() < 1e-6,
            "non-text manifest should be greedy: {}",
            opts.temperature
        );
    }

    #[test]
    fn sampling_opts_applies_explicit_manifest_params() {
        let opts = sampling_opts_from_defaults(
            &GenerationDefaults::Text {
                temperature: Some(0.3),
                min_p: Some(0.05),
                top_p: Some(0.8),
                top_k: Some(15),
                repetition_penalty: Some(1.1),
            },
            64,
        );
        assert_eq!(opts.max_tokens, 64);
        assert!((opts.temperature - 0.3).abs() < 1e-6);
        assert!((opts.min_p - 0.05).abs() < 1e-6);
        assert!((opts.top_p - 0.8).abs() < 1e-6);
        assert_eq!(opts.top_k, 15);
        assert!((opts.repetition_penalty - 1.1).abs() < 1e-6);
    }
}
