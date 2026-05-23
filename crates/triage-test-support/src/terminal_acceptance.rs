//! Engine-neutral terminal acceptance scenarios for Phase 1.

use crate::vt::TerminalFixture;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Capability {
    Resize,
    LateAttach,
    Reconnect,
    AltScreen,
    BracketedPaste,
    MouseReporting,
    ScrollRegions,
    Replay,
    LogTee,
}

impl Capability {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Resize => "resize",
            Self::LateAttach => "late_attach",
            Self::Reconnect => "reconnect",
            Self::AltScreen => "alt_screen",
            Self::BracketedPaste => "bracketed_paste",
            Self::MouseReporting => "mouse_reporting",
            Self::ScrollRegions => "scroll_regions",
            Self::Replay => "replay",
            Self::LogTee => "log_tee",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalScenario {
    pub name: &'static str,
    pub capability: Capability,
    pub description: &'static str,
    pub bytes: &'static [u8],
    pub replay_chunks: &'static [&'static [u8]],
}

impl TerminalScenario {
    pub fn transcript_lines(self) -> String {
        let mut fixture = TerminalFixture::default();
        fixture.feed(self.bytes);
        fixture.events_as_lines()
    }

    pub fn replay_transcript_lines(self) -> String {
        let mut fixture = TerminalFixture::default();
        for chunk in self.replay_chunks {
            fixture.feed(chunk);
        }
        fixture.events_as_lines()
    }
}

const RESIZE_BYTES: &[u8] = b"\x1b[8;40;120tresized";
const LATE_ATTACH_BYTES: &[u8] = b"before attach\r\n\x1b[2J\x1b[Hafter attach";
const RECONNECT_BYTES: &[u8] = b"connected\r\n\x1b[?1049hscreen\x1b[?1049lback";
const ALT_SCREEN_BYTES: &[u8] = b"main\x1b[?1049halt\x1b[2J\x1b[Hinside\x1b[?1049lmain";
const BRACKETED_PASTE_BYTES: &[u8] = b"\x1b[?2004h\x1b[200~pasted\r\ntext\x1b[201~\x1b[?2004l";
const MOUSE_REPORTING_BYTES: &[u8] =
    b"\x1b[?1000h\x1b[?1006h\x1b[<0;12;5M\x1b[<0;12;5m\x1b[?1006l\x1b[?1000l";
const SCROLL_REGION_BYTES: &[u8] = b"\x1b[2;5rone\r\ntwo\r\nthree\x1b[r";
const REPLAY_CHUNK_ONE: &[u8] = b"one\r\n";
const REPLAY_CHUNK_TWO: &[u8] = b"\x1b[31mtwo";
const REPLAY_CHUNK_THREE: &[u8] = b"\x1b[0m\r\nthree";
const REPLAY_BYTES: &[u8] = b"one\r\n\x1b[31mtwo\x1b[0m\r\nthree";
const LOG_TEE_BYTES: &[u8] = b"raw\x00bytes\x1b[31mred\x1b[0m\r\n";

pub const SCENARIOS: &[TerminalScenario] = &[
    TerminalScenario {
        name: "resize_window_report",
        capability: Capability::Resize,
        description: "Tracks terminal resize control traffic as ordered input to the daemon state model.",
        bytes: RESIZE_BYTES,
        replay_chunks: &[RESIZE_BYTES],
    },
    TerminalScenario {
        name: "late_attach_screen_reset",
        capability: Capability::LateAttach,
        description: "Exercises screen clearing and cursor home before a late client snapshot.",
        bytes: LATE_ATTACH_BYTES,
        replay_chunks: &[LATE_ATTACH_BYTES],
    },
    TerminalScenario {
        name: "reconnect_alt_screen_boundary",
        capability: Capability::Reconnect,
        description: "Models reconnect across an alt-screen section and return to main screen.",
        bytes: RECONNECT_BYTES,
        replay_chunks: &[RECONNECT_BYTES],
    },
    TerminalScenario {
        name: "alt_screen_enter_exit",
        capability: Capability::AltScreen,
        description: "Covers alternate-screen enter, clear, cursor home, content, and exit.",
        bytes: ALT_SCREEN_BYTES,
        replay_chunks: &[ALT_SCREEN_BYTES],
    },
    TerminalScenario {
        name: "bracketed_paste_round_trip",
        capability: Capability::BracketedPaste,
        description: "Captures paste mode enable/disable plus pasted payload boundaries.",
        bytes: BRACKETED_PASTE_BYTES,
        replay_chunks: &[BRACKETED_PASTE_BYTES],
    },
    TerminalScenario {
        name: "sgr_mouse_press_release",
        capability: Capability::MouseReporting,
        description: "Captures mouse mode toggles and SGR press/release reports.",
        bytes: MOUSE_REPORTING_BYTES,
        replay_chunks: &[MOUSE_REPORTING_BYTES],
    },
    TerminalScenario {
        name: "scroll_region_reset",
        capability: Capability::ScrollRegions,
        description: "Covers DECSTBM scroll-region setup and reset around line output.",
        bytes: SCROLL_REGION_BYTES,
        replay_chunks: &[SCROLL_REGION_BYTES],
    },
    TerminalScenario {
        name: "chunked_replay_matches_contiguous_stream",
        capability: Capability::Replay,
        description: "Ensures chunked replay preserves parser state across PTY read boundaries.",
        bytes: REPLAY_BYTES,
        replay_chunks: &[REPLAY_CHUNK_ONE, REPLAY_CHUNK_TWO, REPLAY_CHUNK_THREE],
    },
    TerminalScenario {
        name: "log_tee_preserves_raw_bytes",
        capability: Capability::LogTee,
        description: "Keeps raw byte logging distinct from parsed terminal state.",
        bytes: LOG_TEE_BYTES,
        replay_chunks: &[LOG_TEE_BYTES],
    },
];
