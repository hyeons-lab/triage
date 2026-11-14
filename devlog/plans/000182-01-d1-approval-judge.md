# Plan: Upgrade Cera to 0.7.4 and Replace LFM2 Judge with Liquid d1 Decision Model

## Thinking

Today `triaged` pins `cera = "0.5.6"` and shares one generative `cera::CeraEngine` (`LFM2-2.6B-GGUF` at `Q4_K_M`, 1.46 GB) between two distinct subsystems:

1. **Session Summarizer (`crates/triaged/src/summarizer.rs`):** Generates natural-language prose (8-word rail labels and multi-sentence hover summaries). Before the approval judge was added in PR #143 (`devlog/000126-feat-approval-judge.md`), the summarizer defaulted to `LFM2.5-1.2B-Instruct-GGUF` at `Q4_0` (664 MB). It was bumped to `LFM2-2.6B-GGUF` (`Q4_K_M`) solely because the 1.2B model collapsed onto a single label when judging shell commands.
2. **Tool-Call Approval Judge (`crates/triaged/src/judge.rs`):** Evaluates ambiguous shell commands that miss the deterministic deny and allow rule tables, using a GBNF grammar (`root ::= "allow" | "ask"`) over greedy token decoding. Coupling Layer 3 to the summarizer's generative LLM had three drawbacks:
   - Disabling `[summarizer] enabled = false` silently disabled the judge's model layer.
   - Switching `[summarizer]` to a reasoning model (`LFM2.5`) broke single-token grammar decoding because `<think>` tokens preceded the verdict.
   - Generative causal LMs produce uncalibrated next-token logits rather than calibrated option probabilities.

`cera` `0.7.4` (latest on crates.io) adds `cera::d1::D1Engine`, which natively runs Liquid AI's open-weight `d1` decision models (`LiquidAI/d1-omni-600M-GGUF`, `LiquidAI/d1-2B-GGUF`, `LiquidAI/d1-3B-GGUF`) directly from Hugging Face GGUFs with **zero output tokens**, returning calibrated probabilities over named options in a single forward pass:

- `LiquidAI/d1-omni-600M-GGUF` (`lfm2-d1-omni`, `Q8_0` 407 MB / `F16` 764 MB): bidirectional LFM2.5 encoder trunk + dedicated 2-layer `d1` decision head; runs both trunk and head on Metal on macOS.
- `LiquidAI/d1-2B-GGUF` (`lfm3-d1`, `Q4_K_M` 1.10 GB): LFM3 2B causal `systemone` decision model; runs on `cera`'s `smmla` + Accelerate BLAS CPU backend on macOS.
- `LiquidAI/d1-3B-GGUF` (`lfm2-d1`, `Q4_K_M` 1.67 GB): LFM2.5 3B causal `systemone` decision model; runs on Metal on macOS.

For text-only shell command evaluation, none of these models require loading their multimodal `mmproj` file (`D1Engine::open(path, None, BackendPreference::Auto)`), saving 200-850 MB of download size and resident memory. And `cera::bundle::BundleRepo::resolve_url` caches GGUFs in `~/.cache/triage/models/huggingface.co/...` with `X-Linked-Etag` SHA-256 verification and offline cache reuse.

Because `d1` is a pure classification/decision model (`output_tokens: 0`), it cannot generate prose session summaries. The clean architecture is:
- Keep the single dedicated inference worker thread (`triage-summarizer` / inference worker) so GPU/CPU compute never contends between concurrent summary decodes and judge forward passes, and judge jobs continue to preempt in-flight summary decodes via `cancel_in_flight_summary()`.
- Give the worker two independent lazy engine slots:
  - `judge_engine: Option<cera::d1::D1Engine>` configured from `[judge]` (`model`, `quant`, `min_allow_confidence`, `cache_dir`), loaded lazily on the first `Judge` job regardless of whether `[summarizer]` is enabled.
  - `summarizer_engine: Option<cera::CeraEngine>` configured from `[summarizer]`, loaded lazily on the first `Summarize` job, with `SummarizerConfig::default()` restored to `LFM2.5-1.2B-Instruct-GGUF` (`Q4_0`, 664 MB).
- Structural `deny` impossibility is preserved by construction: `judge_with_d1` asks a single 2-option `choice` question (`"allow"` vs `"ask"`) and requires both `choice == "allow"` and `P(allow) >= min_allow_confidence`, mapping anything else (including parse/inference errors) to `Ask`.

Before locking in the default `d1` model, quantization, question phrasing, and `min_allow_confidence`, we will benchmark the candidate `d1` GGUF models on a labeled 24-command evaluation set (12 routine developer commands + 12 side-effecting/network/install/system commands + adversarial delimiter-injection cases) and record exact accuracy, false-allow count, calibrated probability margins, and per-decision latency in the devlog.

## Plan

1. **Upgrade `cera` to `0.7.4`:**
   - Update `Cargo.toml` workspace dependency `cera` from `0.5.6` to `0.7.4`.
   - Enable `features = ["metal", "blas"]` on macOS in `crates/triaged/Cargo.toml`.
   - Verify workspace compilation and resolve any `cera 0.7.4` API changes in `crates/triaged/src/summarizer.rs` and `crates/triaged/src/judge.rs`.

2. **Benchmark Liquid `d1` Models for Approval Judging:**
   - Write a temporary benchmark harness to evaluate `LiquidAI/d1-omni-600M-GGUF` (`Q8_0`), `LiquidAI/d1-2B-GGUF` (`Q4_K_M`), and (if needed) `LiquidAI/d1-3B-GGUF` (`Q4_K_M`) via `cera::d1::D1Engine` across candidate `choice` / `noul` prompts on a 24-command labeled set plus delimiter-injection controls.
   - Select the default model, quantization, prompt formulation, and `min_allow_confidence` achieving zero false allows with strong recall and low latency/memory. Remove any temporary probe file after recording full results in `devlog/000182-feat-d1-approval-judge.md`.

3. **Implement `d1` Judge Config, Loader, Inference, and Worker Decoupling:**
   - Extend `JudgeConfig` in `crates/triage-core/src/config.rs` with `model` (Hugging Face repo ID, direct HF GGUF URL, or local `.gguf` path), `quant`, `min_allow_confidence` (validated in `(0.0, 1.0]`, represented cleanly in TOML), and `cache_dir`, preserving backward compatibility for existing `config.toml` files and `persist_judge_config` in `crates/triage-core/src/judge_rules.rs`.
   - Return `SummarizerConfig::default()` in `crates/triage-core/src/config.rs` to `LFM2.5-1.2B-Instruct-GGUF` (`Q4_0`).
   - Replace `judge_with_model` in `crates/triaged/src/judge.rs` with `judge_with_d1(&cera::d1::D1Engine, &JudgeRequest, min_allow_confidence)` building a `cera::d1::D1Request`, evaluating calibrated `allow` vs `ask` probabilities, and recording `p_allow` in the audit reason.
   - Refactor `crates/triaged/src/summarizer.rs` and `crates/triaged/src/session.rs` so the inference worker spawns whenever either `summarizer.enabled` or `judge.enabled` is true, lazily loads `D1Engine` (resolving remote HF models through `BundleRepo`) independently of `CeraEngine`, and supports hot reloading or config changes cleanly.

4. **Update Client Badge, Docs, and Tests:**
   - Update the approval judge badge in `flutter/triage_client/lib/main.dart` (`Local AI · ...`) and corresponding widget tests if asserted.
   - Update `docs/approval-judge.md` and `crates/triaged/README.md` to document the dedicated Liquid `d1` judge model and `[judge]` model settings.
   - Add unit tests for `JudgeConfig` validation/TOML round-trip, `d1` request/response parsing and threshold fail-safes, and judge-only worker operation when `summarizer.enabled = false`.

5. **Validate, Open PR, and Deploy Locally:**
   - Run `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, `cargo test --workspace`, `flutter analyze`, and `flutter test`.
   - Update `devlog/000182-feat-d1-approval-judge.md`, commit, push `feat/d1-approval-judge`, and open a PR.
   - Rebuild and install release CLI/daemon binaries via `scripts/install.sh`, run zero-downtime `triaged reload`, and rebuild/sign/install/relaunch `/Applications/Triage.app`.
