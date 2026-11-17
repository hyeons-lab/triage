# Devlog: Upgrade Cera to 0.7.4 and Adopt Liquid d1 Decision Model for Approval Judge

- **Agent:** Antigravity (Gemini 4 Carbon High) @ triage branch feat/d1-approval-judge
- **Agent:** Antigravity (model switch at 2026-11-12T18:28-0800) @ triage branch feat/d1-approval-judge
- **Intent:** Upgrade the `cera` local inference engine dependency to the latest `0.7.4` release and replace the generative `LFM2-2.6B` grammar-constrained approval judge with a dedicated Liquid `d1` zero-output-token decision model (`cera::d1::D1Engine`), while decoupling the judge's model lifecycle from the session summarizer.

## What Changed

- 2026-11-11T08:29-0800 `Cargo.toml`, `Cargo.lock`, `crates/triaged/Cargo.toml`: upgraded `cera` from `0.5.6` to `0.7.4` (`features = ["remote"]`) and enabled `["metal", "blas"]` on macOS/iOS targets in `triaged`.
- 2026-11-11T08:29-0800 `crates/triage-core/src/config.rs`: added `model` (`"LiquidAI/d1-2B-GGUF"`), `quant` (`"Q4_K_M"`), `min_allow_confidence_pct` (`65`), and `cache_dir` (`None`) to `JudgeConfig` with validation; returned `SummarizerConfig::default()` to `LFM2.5-1.2B-Instruct-GGUF` (`Q4_0`, 664 MB) now that judging has its own dedicated decision model.
- 2026-11-11T08:29-0800 `crates/triaged/src/judge.rs`: replaced generative `SYSTEM_PROMPT`, `DECISION_GRAMMAR`, and `judge_with_model` with `judge_with_d1`, `build_d1_request`, `interpret_d1_response`, `d1_model_download_url`, and `resolve_d1_model_path` backed by `cera::d1::D1Engine`. Added unit tests covering threshold enforcement, `deny` rejection, malformed probability refusal, structured JSON state construction, and URL/local-path resolution.
- 2026-11-11T08:29-0800 `crates/triaged/src/summarizer.rs`, `crates/triaged/src/session.rs`, `crates/triaged/src/main.rs`: decoupled the worker into two lazy model slots (`Option<cera::CeraEngine>` for session summaries and `Option<cera::d1::D1Engine>` for Layer 3 judging) on the single priority inference thread via `InferenceWorkerConfig` and `SessionManager::start_inference`, so `[summarizer] enabled = false` keeps Layer 3 judging active while preserving single-token summary preemption when both are enabled.
- 2026-11-11T08:29-0800 `flutter/triage_client/lib/main.dart`, `docs/approval-judge.md`, `docs/configuration.md`, `crates/triaged/README.md`: updated the Approval Judge settings badge to `Local AI · Liquid d1-2B` and documented the `d1` model architecture, configuration keys, and independent summarizer toggle.
- 2026-11-12T18:28-0800 `crates/triage-core/src/{config,judge_rules,logging}.rs`, `crates/triaged/src/{judge,session,summarizer}.rs`, `flutter/triage_client/lib/main.dart`, `README.md`: Hardened `d1` configuration, worker lifecycle, and URL credential redaction across six review rounds: persisted `model`, `quant`, `min_allow_confidence_pct`, and `cache_dir` in `persist_judge_config_to`, expanded `~` home prefixes on `cache_dir` and local `.gguf` paths, validated `judge.quant` and candidate Hugging Face / HTTP `.gguf` URLs against `cera` cache-key rules before network access while allowing empty `quant` when `judge` is disabled or `model` is self-contained, enforced post-JSON-serialization byte caps on `D1Request` before queue preemption, pruned cancelled timed-out `JudgeJob` entries and latched per-engine load failures and `WorkerExitGuard` LIFO teardown before engine destructors, muted `cera::bundle=error` in `DEFAULT_FILTER`, and scrubbed embedded URL `userinfo`, `?query`, and `#fragment` secrets via `redact_model_spec_for_log` and `redact_urls_in_text`.

## Decisions

- 2026-11-11T08:05-0800 Upgrade `cera` from `0.5.6` to `0.7.4` and enable `blas` alongside `metal` on macOS in `crates/triaged/Cargo.toml`: `cera 0.7.4` introduces `cera::d1::D1Engine` supporting Liquid's public `d1-omni-600M`, `d1-2B`, and `d1-3B` GGUFs across Metal, CPU (`smmla` + Apple Accelerate BLAS), wgpu, and Hexagon NPU, plus prefill and decode speedups for session summarization.
- 2026-11-11T08:05-0800 Separate the approval judge's `D1Engine` from the session summarizer's `CeraEngine` while keeping both serialized on the single priority inference worker thread: `d1` models answer typed classification questions in a single forward pass with zero output tokens and cannot generate prose session summaries, while generative models are heavier and uncalibrated for binary gating. Hosting both lazy engine slots on the priority worker avoids GPU/CPU thread-pool contention, preserves summary preemption when a blocking judge request arrives, allows `[summarizer] enabled = false` without disabling Layer 3 judging, and lets `SummarizerConfig::default()` return to the lightweight `LFM2.5-1.2B-Instruct-GGUF` (`Q4_0`, 664 MB).
- 2026-11-11T08:29-0800 Select `LiquidAI/d1-2B-GGUF` at `Q4_K_M` (`1,048.7 MiB`, `lfm3-d1` on Metal) with structured JSON state `{"working_directory": ..., "command": ...}` and `min_allow_confidence_pct = 65`: empirically beat both `LFM2-2.6B` (`Q4_K_M`, `1.46 GiB`) and `LiquidAI/d1-omni-600M-GGUF` (`Q8_0`, `388.3 MiB`) with 50/50 accuracy across two independent command suites, zero false allows, 410 MiB smaller footprint than `LFM2-2.6B`, ~1.8x faster latency on Metal, and a wide `[0.25, 0.81]` probability separation margin around `0.65`.

## Research & Discoveries

- 2026-11-11T08:16-0800 Benchmarked `LFM2-2.6B-GGUF` (`Q4_K_M`), `LiquidAI/d1-omni-600M-GGUF` (`Q8_0`), and `LiquidAI/d1-2B-GGUF` (`Q4_K_M`) in release mode on Apple Silicon Metal across a 28-command labeled Layer-3 set (14 routine local read/lint/test/pipe commands + 14 risky install/network/push/delete/outside-cwd/service/delimiter-injection commands) plus an unseen 22-command adversarial stress set:
  - `LFM2-2.6B-GGUF` (`Q4_K_M`, 1.46 GiB, GBNF generative decode): **24/28** (`85.7%`), **1 false allow** (`git config --global user.name "Bot"`), 3 conservative false asks, `211.6 ms`/decision on Metal.
  - `LiquidAI/d1-omni-600M-GGUF` (`Q8_0`, 388.3 MiB, `lfm2-d1-omni` on Metal): `37.5` to `53.2 ms`/decision, but 600M capacity lacked clean separation on grey-zone shell commands (`lowest Allow = 0.8281` vs `highest Ask = 0.8839` on text `choice`, 6 false allows at `0.50`; requiring `thr = 0.90` for zero false allows reduced score to `22/28`).
  - `LiquidAI/d1-2B-GGUF` (`Q4_K_M`, 1,048.7 MiB, `lfm3-d1` on Metal): **28/28 (100%)** on the primary benchmark at thresholds `0.50`, `0.65`, and `0.75` (`117.3 ms`/decision; `lowest Allow = 0.8086`, `highest Ask = 0.2471`), plus **22/22 (100%)** on the unseen 22-command stress set (`lowest Allow = 0.8884`, `highest Ask = 0.2484`, prompt-injection + curl-pipe scored `p_allow = 0.0146`), and **8/8** on opposite criteria-polarity controls.
- 2026-11-11T08:18-0800 `BundleRepo::resolve_url` reuses cached files offline when `HEAD` fails, whereas `inspect_and_resolve_manifest` queries the Hugging Face commits API first. Resolving the canonical `https://huggingface.co/{owner}/{repo}/resolve/main/{stem}-{quant}.gguf` URL via `BundleRepo::resolve_url` first (falling back to `inspect_and_resolve_manifest` only on miss/404) keeps cached `d1` models offline-capable.

## Issues

- 2026-11-12T18:28-0800 Character-capped `D1Request` commands expanded up to 6x under JSON control-character escaping (`\u00XX`), risking right-truncation of the structured `state` JSON tail, and validating `D1Request` on the worker let oversized requests preempt queued jobs: enforced post-JSON byte bounds in `build_bounded_d1_request` on the caller thread before `queue.push_judge`.
- 2026-11-12T18:28-0800 `HfSpec::parse` silently dropped unrecognized URL verbs and truncated 3-segment Hugging Face URLs into repo-root lookups, and forward URL delimiter scans missed `userinfo@host` when unencoded `?` or `#` appeared inside `userinfo` or broke early on escaped JSON quotes (`\"`): validated raw URL segment arity and `cera` cache-key segments up front, scanned `@host[:port]` right-to-left before `/`, and verified `redact_urls_in_text` over 400,000+ randomized composite error strings with zero leaks.

## Commits

- `061e27a`: feat(judge): upgrade cera to 0.7.4 and adopt Liquid d1-2B decision model
- `HEAD`: fix(judge): harden d1 config, worker lifecycle, and URL credential redaction

## Progress

- [x] Create `worktrees/d1-approval-judge` (`feat/d1-approval-judge`), devlog, and implementation plan
- [x] Upgrade `cera` to `0.7.4` and benchmark candidate Liquid `d1` GGUF models (`d1-omni-600M`, `d1-2B`) on labeled approval-judge command sets
- [x] Wire `cera::d1::D1Engine` into `JudgeConfig`, `judge.rs`, `summarizer.rs`, and `session.rs`
- [x] Update Flutter UI badge, documentation, and unit tests
- [x] Pass format, lint, and test gates, open PR, and rebuild/install/reload `triaged` and `Triage.app`
