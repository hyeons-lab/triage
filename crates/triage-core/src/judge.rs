//! Wire types for the tool-call approval judge.
//!
//! An agent CLI running inside a Triage session (today: `agy`, via its
//! `PreToolUse` lifecycle hook) asks the daemon whether a tool call should run.
//! The daemon answers with a [`JudgeDecision`]. These types are the contract
//! between the hook shim, the IPC transport, and the daemon-side judge, so they
//! live in `triage-core` alongside the other wire payloads rather than in either
//! endpoint.
//!
//! The security model lives in the daemon (see `triaged::judge`), but two of its
//! guarantees are visible here and are the reason the types are shaped this way:
//!
//! * [`JudgeDecision::Ask`] is the safe answer, not an error case. It is exactly
//!   what the agent does today without a judge: prompt the user. Every failure
//!   path in the shim and the daemon resolves to `Ask`.
//! * [`JudgeDecision::Deny`] can only ever be produced by a deterministic rule.
//!   The model is never given the option, because a denial it invented would be
//!   indistinguishable to the user from one that was meant.

use serde::{Deserialize, Serialize};

use crate::session::SessionId;

/// A request to judge one tool call.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JudgeRequest {
    /// The Triage session the agent is running in, taken from `TRIAGE_SESSION_ID`
    /// in the agent's environment.
    pub session_id: SessionId,
    /// The agent's tool name, e.g. `run_command`. Tool calls other than command
    /// execution are not judged today, but the field is carried so the daemon
    /// decides that rather than the shim.
    pub tool_name: String,
    /// The command line the agent wants to run. `None` for a tool call that
    /// carries no command.
    pub command_line: Option<String>,
    /// The target path the agent wants to read or inspect, if applicable.
    #[serde(default)]
    pub path: Option<String>,
    /// The agent's working directory, when the hook payload reported one.
    /// Model context only: it is not written to the audit log, and no rule ever
    /// consults it, so it can never widen what is approved.
    pub cwd: Option<String>,
}

/// The verdict for one tool call. Mirrors the subset of `agy`'s `PreToolUse`
/// decision vocabulary that Triage produces; `force_ask` is deliberately not
/// modeled, since bypassing the user's own "always allow" cache is the user's
/// call to make, not the judge's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JudgeDecision {
    /// Run the tool call without prompting.
    Allow,
    /// Prompt the user, exactly as if no judge were installed. This is the
    /// fail-safe: an unreachable daemon, a disabled judge, an unloaded model, a
    /// timeout, or an unparseable payload all land here.
    Ask,
    /// Block the tool call outright. Only ever produced by a deterministic rule.
    Deny,
}

impl JudgeDecision {
    /// The wire value `agy` expects in the hook's `decision` field.
    pub fn as_hook_str(self) -> &'static str {
        match self {
            Self::Allow => "allow",
            Self::Ask => "ask",
            Self::Deny => "deny",
        }
    }
}

/// Renders the same lowercase word as the hook wire value and the serde
/// representation. The audit log formats with `Display` rather than `Debug` so
/// that grepping the log matches what the docs, the hook output, and the IPC
/// payload all say; `Debug` would print `Allow` and quietly break all three.
impl std::fmt::Display for JudgeDecision {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_hook_str())
    }
}

/// Which layer produced a decision. Carried alongside the decision so the audit
/// log can distinguish "the allowlist matched" from "the model chose to allow",
/// which are very different claims when reviewing what the judge let through.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JudgeSource {
    /// A deterministic deny rule matched.
    DenyRule,
    /// A deterministic allow rule matched.
    AllowRule,
    /// The local model decided the ambiguous middle.
    Model,
    /// No decision was reached: judging is off for this session, the model is
    /// unavailable, or something failed. Always paired with [`JudgeDecision::Ask`].
    Fallback,
}

impl JudgeSource {
    /// The snake_case label, matching the serde representation.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::DenyRule => "deny_rule",
            Self::AllowRule => "allow_rule",
            Self::Model => "model",
            Self::Fallback => "fallback",
        }
    }
}

/// See the note on [`JudgeDecision`]'s `Display`: the audit log is a documented
/// surface people grep, so it renders `allow_rule`, not `AllowRule`.
impl std::fmt::Display for JudgeSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One session's judge policy, as both the raw override and the resolved answer.
///
/// Carries the override rather than only the effective value so a client can
/// distinguish "pinned on" from "following a default that happens to be on".
/// Those look identical in the resolved bool but behave differently the moment
/// the configured default changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionJudgePolicy {
    /// The per-session override: `None` means the session follows the default.
    pub explicit: Option<bool>,
    /// The resolved policy, override applied over the configured default.
    pub effective: bool,
}

/// A decision plus its provenance.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JudgeVerdict {
    pub decision: JudgeDecision,
    pub source: JudgeSource,
    /// Short human-readable justification, surfaced to the user by `agy` and
    /// recorded in the audit log. Rule-sourced verdicts name the rule; model
    /// verdicts say so, since the model is not asked to explain itself.
    pub reason: String,
}

impl JudgeVerdict {
    /// The fail-safe verdict: prompt the user, and say why we could not do
    /// better than that.
    pub fn fallback(reason: impl Into<String>) -> Self {
        Self {
            decision: JudgeDecision::Ask,
            source: JudgeSource::Fallback,
            reason: reason.into(),
        }
    }

    /// A refusal from a deterministic rule, the only source permitted to deny.
    /// A constructor rather than a literal so that pairing stays impossible to
    /// get wrong, the same reason [`Self::fallback`] exists.
    pub fn deny_rule(rule: impl std::fmt::Display) -> Self {
        Self {
            decision: JudgeDecision::Deny,
            source: JudgeSource::DenyRule,
            reason: format!("blocked by deny rule: {rule}"),
        }
    }
}

/// Status of the agent PreToolUse hook configuration on disk.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JudgeHookStatus {
    /// Absolute path to `.agents/hooks.json` (or target hook file).
    pub path: String,
    /// Whether `.agents/hooks.json` exists on disk.
    pub exists: bool,
    /// Whether the `triage-approval-judge` hook is enabled inside the file.
    pub enabled: bool,
    /// Whether the `triage-hook` executable is detected on PATH or in ~/.cargo/bin.
    pub shim_installed: bool,
}

/// A record of a single past tool call evaluated by the approval judge.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JudgeRecord {
    pub timestamp: String,
    pub session_id: SessionId,
    pub tool_name: String,
    pub command_line: Option<String>,
    pub decision: JudgeDecision,
    pub source: JudgeSource,
    pub reason: String,
}

/// Active judge rules configuration including both builtins and custom user rules.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JudgeRulesInfo {
    pub builtin_allow_commands: Vec<String>,
    pub custom_allow_commands: Vec<String>,
    pub builtin_deny_substrings: Vec<String>,
    pub custom_deny_substrings: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_strings_match_the_agy_vocabulary() {
        assert_eq!(JudgeDecision::Allow.as_hook_str(), "allow");
        assert_eq!(JudgeDecision::Ask.as_hook_str(), "ask");
        assert_eq!(JudgeDecision::Deny.as_hook_str(), "deny");
    }

    #[test]
    fn fallback_is_always_ask() {
        let verdict = JudgeVerdict::fallback("daemon unreachable");
        assert_eq!(verdict.decision, JudgeDecision::Ask);
        assert_eq!(verdict.source, JudgeSource::Fallback);
    }

    #[test]
    fn decision_round_trips_as_snake_case() {
        let json = serde_json::to_string(&JudgeDecision::Ask).expect("serialize");
        assert_eq!(json, "\"ask\"");
        let parsed: JudgeDecision = serde_json::from_str("\"deny\"").expect("deserialize");
        assert_eq!(parsed, JudgeDecision::Deny);
    }

    /// The audit log formats both enums with `Display`, and `docs/approval-judge.md`
    /// tells the reader to grep for these exact words. Asserting `Display` against
    /// the serde form keeps the log, the hook payload, and the docs from drifting
    /// apart, which they already did once when the log used `Debug`.
    #[test]
    fn log_labels_match_the_serde_representation() {
        for decision in [
            JudgeDecision::Allow,
            JudgeDecision::Ask,
            JudgeDecision::Deny,
        ] {
            let json = serde_json::to_string(&decision).expect("serialize");
            assert_eq!(format!("\"{decision}\""), json);
        }
        for source in [
            JudgeSource::DenyRule,
            JudgeSource::AllowRule,
            JudgeSource::Model,
            JudgeSource::Fallback,
        ] {
            let json = serde_json::to_string(&source).expect("serialize");
            assert_eq!(format!("\"{source}\""), json);
        }
        assert_eq!(JudgeSource::AllowRule.to_string(), "allow_rule");
    }
}
