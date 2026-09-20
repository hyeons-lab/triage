//! AI coding agents triage can track and resume.
//!
//! A triage session is a shell, but its interesting occupant is usually an
//! agent TUI running inside it. The daemon observes which agent (if any) is
//! in each session's foreground and records an [`AgentAttachment`]; after a
//! reboot, restoring the session resumes that conversation instead of a
//! fresh shell. Attachments are live-state only: exiting the agent clears
//! them, and exited sessions never carry one.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// AI coding agents triage can track and resume.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentKind {
    Claude,
    Codex,
    Antigravity,
    Muse,
}

impl AgentKind {
    /// All supported agents, for exhaustive matching.
    pub fn all() -> [AgentKind; 4] {
        [
            AgentKind::Claude,
            AgentKind::Codex,
            AgentKind::Antigravity,
            AgentKind::Muse,
        ]
    }

    /// Executable file stems (lowercase, no extension) identifying this agent.
    pub fn binary_names(&self) -> &'static [&'static str] {
        match self {
            AgentKind::Claude => &["claude"],
            AgentKind::Codex => &["codex"],
            AgentKind::Antigravity => &["agy", "antigravity"],
            AgentKind::Muse => &["muse"],
        }
    }

    /// Primary binary name, used when building resume commands.
    pub fn primary_binary(&self) -> &'static str {
        match self {
            AgentKind::Claude => "claude",
            AgentKind::Codex => "codex",
            AgentKind::Antigravity => "agy",
            AgentKind::Muse => "muse",
        }
    }

    /// Match a process executable file name (any case, `.exe` tolerated)
    /// against the known agent binaries.
    pub fn detect(exe_file_name: &str) -> Option<AgentKind> {
        let lowered = exe_file_name.to_ascii_lowercase();
        let stem = lowered.strip_suffix(".exe").unwrap_or(&lowered);
        AgentKind::all()
            .into_iter()
            .find(|kind| kind.binary_names().contains(&stem))
    }
}

/// The agent observed in a session's foreground: its kind, the conversation
/// it runs (when known), and where that conversation's transcript lives.
///
/// `conversation_id` is `None` for agents started fresh whose transcript
/// could not be unambiguously correlated; restoring those falls back to the
/// agent's most-recent conversation. `transcript_path` is `None` for the
/// same cases, and always for Antigravity, whose local store is unknown.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentAttachment {
    pub kind: AgentKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<PathBuf>,
    /// Absolute path of the running agent binary, captured at observe time
    /// so restore spawns the same binary without relying on the daemon's
    /// `PATH` (login shells often extend `PATH` beyond what the daemon
    /// sees). `None` for attachments predating this field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exe_path: Option<PathBuf>,
    /// Wall-clock attach time, milliseconds since the Unix epoch.
    pub last_seen_ms: u64,
}

impl AgentAttachment {
    /// Identity for change detection: two attachments are the same
    /// observation when kind, conversation, transcript, and binary path
    /// match, ignoring only the timestamp so re-reports do not churn the
    /// manifest. The binary path is compared so a moved binary refreshes
    /// the manifest instead of pinning a dead path that later vetoes
    /// resume; paths are stable per process, so this cannot flap.
    pub fn same_observation(&self, other: &AgentAttachment) -> bool {
        self.kind == other.kind
            && self.conversation_id == other.conversation_id
            && self.transcript_path == other.transcript_path
            && self.exe_path == other.exe_path
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_matches_known_binaries() {
        assert_eq!(AgentKind::detect("claude"), Some(AgentKind::Claude));
        assert_eq!(AgentKind::detect("codex"), Some(AgentKind::Codex));
        assert_eq!(AgentKind::detect("agy"), Some(AgentKind::Antigravity));
        assert_eq!(
            AgentKind::detect("antigravity"),
            Some(AgentKind::Antigravity)
        );
        assert_eq!(AgentKind::detect("muse"), Some(AgentKind::Muse));
        assert_eq!(AgentKind::detect("Muse"), Some(AgentKind::Muse));
        assert_eq!(AgentKind::detect("codex.exe"), Some(AgentKind::Codex));
        assert_eq!(AgentKind::detect("bash"), None);
        assert_eq!(AgentKind::detect("claude-code"), None);
    }

    #[test]
    fn same_observation_ignores_timestamp() {
        let left = AgentAttachment {
            kind: AgentKind::Claude,
            conversation_id: Some("abc".to_string()),
            transcript_path: None,
            exe_path: None,
            last_seen_ms: 1,
        };
        let right = AgentAttachment {
            last_seen_ms: 2,
            ..left.clone()
        };
        assert!(left.same_observation(&right));
        let changed = AgentAttachment {
            conversation_id: Some("abd".to_string()),
            ..left.clone()
        };
        assert!(!left.same_observation(&changed));
    }
}
