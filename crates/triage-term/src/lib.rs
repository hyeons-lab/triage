use std::borrow::Cow;
use std::io::{Read, Write};
use std::time::{Duration, Instant};

use flate2::Compression;
use flate2::read::ZlibDecoder;
use flate2::write::ZlibEncoder;
use serde::{Deserialize, Serialize};
use tattoy_wezterm_surface::{CursorShape, CursorVisibility, Line, SequenceNo};
use tattoy_wezterm_term::color::ColorAttribute;
use tattoy_wezterm_term::{Blink, CellAttributes, Intensity, StableRowIndex, Terminal, Underline};
use unicode_width::UnicodeWidthChar;

pub const CELL_WORDS: usize = 4;

/// Little-endian magic word (`b"TCG1"`) at the start of every packed cell batch.
pub const TCG1_MAGIC: u32 = u32::from_le_bytes(*b"TCG1");

/// Uncompressed `TCG1` payload.
pub const CELL_COMPRESSION_NONE: u8 = 0;
/// Zlib-compressed `TCG1` payload.
pub const CELL_COMPRESSION_ZLIB: u8 = 1;

/// Maximum number of newly scrolled boundary rows pushed inline inside a live
/// `TerminalSyncPatch` before the client falls back to demand-paging older rows.
pub const MAX_INLINE_PUSHED_SCROLLBACK_ROWS: usize = 64;

/// Maximum column count encoded in the 12-bit `stored_cols` / `logical_cols` fields.
pub const MAX_ENCODED_COLS: usize = 0x0FFF;

/// Maximum uncompressed byte size accepted when decoding a `TCG1` cell batch (16 MiB).
pub const MAX_DECOMPRESSED_TCG1_BYTES: usize = 16 * 1024 * 1024;

// Line flag bits stored in the upper byte of the second line-header word.
pub const LINE_FLAG_WRAPS_NEXT: u8 = 1 << 0;
pub const LINE_FLAG_HAS_COMBINING: u8 = 1 << 1;

// Mode flag bits synced in `TerminalSyncPatch.mode_flags`.
pub const MODE_ALT_SCREEN: u32 = 1 << 0;
pub const MODE_CURSOR_VISIBLE: u32 = 1 << 1;
pub const MODE_BRACKETED_PASTE: u32 = 1 << 2;
pub const MODE_APP_CURSOR_KEYS: u32 = 1 << 3;
pub const MODE_APP_KEYPAD: u32 = 1 << 4;
pub const MODE_ORIGIN: u32 = 1 << 5;
pub const MODE_AUTO_WRAP: u32 = 1 << 6;
pub const MODE_REPORT_FOCUS: u32 = 1 << 7;
pub const MODE_SAW_ERASE_SCROLLBACK: u32 = 1 << 8;
pub const MODE_SAW_ERASE_DISPLAY: u32 = 1 << 9;
pub const MODE_BELL_RANG: u32 = 1 << 10;
pub const MODE_TITLE_CHANGED: u32 = 1 << 11;
pub const MODE_REVERSE_VIDEO: u32 = 1 << 12;
pub const MODE_FULL_VIEWPORT: u32 = 1 << 13;

// Cell color type encodings (shifted by 25).
pub const COLOR_NORMAL: u32 = 0;
pub const COLOR_NAMED: u32 = 1 << 25;
pub const COLOR_PALETTE: u32 = 2 << 25;
pub const COLOR_RGB: u32 = 3 << 25;

// Cell attribute bit flags.
pub const ATTR_BOLD: u32 = 1 << 0;
pub const ATTR_FAINT: u32 = 1 << 1;
pub const ATTR_ITALIC: u32 = 1 << 2;
pub const ATTR_UNDERLINE: u32 = 1 << 3;
pub const ATTR_BLINK: u32 = 1 << 4;
pub const ATTR_INVERSE: u32 = 1 << 5;
pub const ATTR_INVISIBLE: u32 = 1 << 6;
pub const ATTR_STRIKETHROUGH: u32 = 1 << 7;
pub const ATTR_OVERLINE: u32 = 1 << 8;
pub const ATTR_DOUBLE_UNDERLINE: u32 = 1 << 9;
pub const ATTR_UNDERCURL: u32 = 1 << 10;
pub const ATTR_DOTTED_UNDERLINE: u32 = 1 << 11;
pub const ATTR_DASHED_UNDERLINE: u32 = 1 << 12;

// Cell content bit layout.
pub const CONTENT_CODEPOINT_MASK: u32 = 0x1f_ffff;
pub const CONTENT_WIDTH_SHIFT: u32 = 22;

/// Serializable subset of sideband DEC private modes and title preserved across
/// zero-downtime `triaged` handover when active modes were entered more than
/// 16 MiB prior to the raw replay tail.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandoverTerminalModes {
    #[serde(default)]
    pub app_cursor_keys: bool,
    #[serde(default)]
    pub app_keypad: bool,
    #[serde(default)]
    pub origin_mode: bool,
    #[serde(default = "default_auto_wrap")]
    pub auto_wrap: bool,
    #[serde(default)]
    pub report_focus: bool,
    #[serde(default)]
    pub mouse_mode: u32,
    #[serde(default)]
    pub mouse_report_mode: u32,
    #[serde(default)]
    pub kitty_keyboard_flags: u32,
    #[serde(default)]
    pub in_alt_screen: bool,
    #[serde(default)]
    pub primary_kitty_stack: Vec<u32>,
    #[serde(default)]
    pub alt_kitty_stack: Vec<u32>,
    #[serde(default)]
    pub bracketed_paste: bool,
    #[serde(default)]
    pub reverse_video: bool,
    #[serde(default = "default_cursor_visible")]
    pub cursor_visible: bool,
    #[serde(default)]
    pub cursor_style: u8,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub has_custom_title: bool,
    #[serde(default)]
    pub erase_scrollback_gen: u64,
    #[serde(default)]
    pub journal_clear_floor: u64,
    #[serde(default)]
    pub unjournaled_trimmed_top_rows: u64,
}

fn default_auto_wrap() -> bool {
    true
}

fn default_cursor_visible() -> bool {
    true
}

impl Default for HandoverTerminalModes {
    fn default() -> Self {
        Self {
            app_cursor_keys: false,
            app_keypad: false,
            origin_mode: false,
            auto_wrap: true,
            report_focus: false,
            mouse_mode: 0,
            mouse_report_mode: 0,
            kitty_keyboard_flags: 0,
            in_alt_screen: false,
            primary_kitty_stack: Vec::new(),
            alt_kitty_stack: Vec::new(),
            bracketed_paste: false,
            reverse_video: false,
            cursor_visible: true,
            cursor_style: 0,
            title: String::new(),
            has_custom_title: false,
            erase_scrollback_gen: 0,
            journal_clear_floor: 0,
            unjournaled_trimmed_top_rows: 0,
        }
    }
}

/// Applies persisted handover modes onto `terminal` without clobbering cursor
/// position or erasing screen cells. Caller should run this while the PTY
/// writer is replay-gated so synthetic escape sequences emit nothing to the
/// child process.
pub fn apply_handover_modes_to_terminal(terminal: &mut Terminal, modes: &HandoverTerminalModes) {
    fn push_kitty_stack_seq(seq: &mut Vec<u8>, stack: &[u32]) {
        seq.extend_from_slice(b"\x1b[<128u");
        let start = stack.len().saturating_sub(128);
        for &raw_flags in &stack[start..] {
            let flags = raw_flags & 0x1f;
            seq.extend_from_slice(b"\x1b[>");
            let mut num_buf = [0u8; 16];
            let len = write_usize_ascii(flags as usize, &mut num_buf);
            seq.extend_from_slice(&num_buf[..len]);
            seq.extend_from_slice(b";1u");
        }
    }

    let fallback_single = [modes.kitty_keyboard_flags & 0x1f];
    let (primary_stack, alt_stack): (&[u32], &[u32]) =
        if !modes.primary_kitty_stack.is_empty() || !modes.alt_kitty_stack.is_empty() {
            (&modes.primary_kitty_stack, &modes.alt_kitty_stack)
        } else if (modes.kitty_keyboard_flags & 0x1f) != 0 {
            if modes.in_alt_screen {
                (&[], &fallback_single)
            } else {
                (&fallback_single, &[])
            }
        } else {
            (&[], &[])
        };

    let mut seq = Vec::with_capacity(224);
    let was_alt = terminal.is_alt_screen_active();
    if modes.in_alt_screen {
        if was_alt {
            seq.extend_from_slice(b"\x1b[?47l");
        }
        push_kitty_stack_seq(&mut seq, primary_stack);
        seq.extend_from_slice(b"\x1b[?47h");
        push_kitty_stack_seq(&mut seq, alt_stack);
    } else {
        if was_alt || !alt_stack.is_empty() {
            if !was_alt {
                seq.extend_from_slice(b"\x1b[?47h");
            }
            push_kitty_stack_seq(&mut seq, alt_stack);
            seq.extend_from_slice(b"\x1b[?47l");
        }
        push_kitty_stack_seq(&mut seq, primary_stack);
    }
    seq.extend_from_slice(if modes.app_cursor_keys {
        b"\x1b[?1h"
    } else {
        b"\x1b[?1l"
    });
    seq.extend_from_slice(if modes.app_keypad { b"\x1b=" } else { b"\x1b>" });
    seq.extend_from_slice(if modes.auto_wrap {
        b"\x1b[?7h"
    } else {
        b"\x1b[?7l"
    });
    seq.extend_from_slice(if modes.bracketed_paste {
        b"\x1b[?2004h"
    } else {
        b"\x1b[?2004l"
    });
    seq.extend_from_slice(if modes.reverse_video {
        b"\x1b[?5h"
    } else {
        b"\x1b[?5l"
    });
    seq.extend_from_slice(if modes.report_focus {
        b"\x1b[?1004h"
    } else {
        b"\x1b[?1004l"
    });
    seq.extend_from_slice(if modes.cursor_visible {
        b"\x1b[?25h"
    } else {
        b"\x1b[?25l"
    });
    if modes.cursor_style <= 6 {
        seq.extend_from_slice(b"\x1b[");
        seq.push(b'0' + modes.cursor_style);
        seq.extend_from_slice(b" q");
    }
    seq.extend_from_slice(b"\x1b[?9;1000;1002;1003l");
    match modes.mouse_mode {
        1 => seq.extend_from_slice(b"\x1b[?9h"),
        2 => seq.extend_from_slice(b"\x1b[?1000h"),
        3 => seq.extend_from_slice(b"\x1b[?1002h"),
        4 => seq.extend_from_slice(b"\x1b[?1003h"),
        _ => {}
    }
    seq.extend_from_slice(b"\x1b[?1005;1006;1015;1016l");
    match modes.mouse_report_mode {
        1 => seq.extend_from_slice(b"\x1b[?1005h"),
        2 => seq.extend_from_slice(b"\x1b[?1006h"),
        3 => seq.extend_from_slice(b"\x1b[?1015h"),
        4 => seq.extend_from_slice(b"\x1b[?1016h"),
        _ => {}
    }
    terminal.advance_bytes(&seq);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AltScreenTransition {
    Entered,
    Exited,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InferredInitialReplayModes {
    pub in_alt_screen: bool,
    pub first_alt_exit_offset: Option<usize>,
    pub auto_wrap: bool,
    pub origin_mode: bool,
    first_auto_wrap_enabled: Option<bool>,
    auto_wrap_before_alt_transition: bool,
    saw_reset_before_auto_wrap: bool,
    end_auto_wrap: bool,
    first_origin_enabled: Option<bool>,
    origin_before_alt_transition: bool,
    saw_reset_or_restore_before_origin: bool,
    saw_alt_exit_1049_before_origin: bool,
    end_origin_mode: bool,
}

impl InferredInitialReplayModes {
    /// Resolves `(auto_wrap, origin_mode)` for `effective_alt_screen`, allowing
    /// callers to override `in_alt_screen` using external scrollback evidence.
    pub fn modes_for_screen(&self, effective_alt_screen: bool) -> (bool, bool) {
        let auto_wrap = match self.first_auto_wrap_enabled {
            Some(false) => true,
            Some(true) => !(effective_alt_screen && self.auto_wrap_before_alt_transition),
            None if self.saw_reset_before_auto_wrap => true,
            None => self.end_auto_wrap,
        };
        let origin_mode = match self.first_origin_enabled {
            Some(true) => false,
            Some(false) => effective_alt_screen && self.origin_before_alt_transition,
            None if self.saw_reset_or_restore_before_origin
                || (effective_alt_screen && self.saw_alt_exit_1049_before_origin) =>
            {
                false
            }
            None => self.end_origin_mode,
        };
        (auto_wrap, origin_mode)
    }
}

/// Scans `bytes` with the VT sideband lexer and returns the direction of the
/// first alternate-screen transition (`?47`, `?1047`, or `?1049`), if any.
pub fn first_alt_screen_transition_in_raw_stream(bytes: &[u8]) -> Option<AltScreenTransition> {
    let mut tracker = TerminalModeTracker::new();
    tracker.scan_for_first_alt_transition(bytes)
}

/// Infers initial screen, auto-wrap (`?7`), and origin (`?6`) modes at the start
/// of a truncated replay tail whose post-replay state is `end_modes`.
pub fn infer_initial_replay_modes(
    bytes: &[u8],
    end_modes: &HandoverTerminalModes,
) -> InferredInitialReplayModes {
    let mut tracker = TerminalModeTracker::new();
    tracker.scan_initial_replay_modes(bytes, end_modes)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EscapeScanState {
    Ground,
    Escape { has_intermediate: bool },
    Csi,
    Osc,
    StString,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Utf8ScanState {
    Ground,
    Tail1,
    Tail1C2,
    Tail2,
    E0,
    Ed,
    Tail3,
    F0,
    F4,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct ModeStack4 {
    entries: [u8; 4],
    len: u8,
}

impl ModeStack4 {
    fn clear(&mut self) {
        self.entries = [0; 4];
        self.len = 0;
    }

    fn set_only(&mut self, mode: u32) {
        self.clear();
        if (1..=4).contains(&mode) {
            self.entries[0] = mode as u8;
            self.len = 1;
        }
    }

    fn apply(&mut self, mode: u8, enabled: bool) {
        let mut write = 0usize;
        for idx in 0..(self.len as usize) {
            if self.entries[idx] != mode {
                self.entries[write] = self.entries[idx];
                write += 1;
            }
        }
        if enabled && write < 4 {
            self.entries[write] = mode;
            write += 1;
        }
        for slot in &mut self.entries[write..] {
            *slot = 0;
        }
        self.len = write as u8;
    }

    fn current(&self) -> u32 {
        if self.len == 0 {
            0
        } else {
            u32::from(self.entries[(self.len - 1) as usize])
        }
    }
}

/// Streaming sideband tracker for DEC private modes, bell, erase-scrollback,
/// erase-display, Kitty keyboard protocol stack, and DEC Mode 2026 synchronized
/// output frames that are not publicly exposed by `tattoy_wezterm_term::Terminal`.
///
/// Uses monotonic `u64` generation counters rather than clear-on-read booleans
/// so 0..N concurrent WebSocket subscribers can independently observe transient
/// events (`bell`, `CSI 2J`, `CSI 3J`, title updates).
#[derive(Debug, Clone)]
pub struct TerminalModeTracker {
    app_cursor_keys: bool,
    app_keypad: bool,
    origin_mode: bool,
    primary_saved_origin: Option<bool>,
    alt_saved_origin: Option<bool>,
    declrmm_69: bool,
    auto_wrap: bool,
    report_focus: bool,
    mouse_mode: u32,
    mouse_report_mode: u32,
    mouse_mode_stack: ModeStack4,
    mouse_report_mode_stack: ModeStack4,
    in_alt_screen: bool,
    primary_kitty_stack: Vec<u32>,
    alt_kitty_stack: Vec<u32>,
    erase_scrollback_gen: u64,
    erase_display_gen: u64,
    bell_gen: u64,
    title_gen: u64,
    handover_title: Option<String>,
    saw_title_osc: bool,
    in_tmux_title: bool,
    last_observed_title: String,
    sync_update_started_at: Option<Instant>,
    scan_state: EscapeScanState,
    utf8_state: Utf8ScanState,
    osc_head_len: u8,
    osc_head: [u8; 3],
    csi_buf: Vec<u8>,
    csi_private_prefix: Option<u8>,
    csi_has_params: bool,
    csi_has_intermediate: bool,
    csi_single_intermediate: Option<u8>,
    csi_ignore: bool,
    csi_tab_cur_param: Option<u64>,
    csi_tab_invalid: bool,
    csi_tab_saw_oversized: bool,
    sanitize_scratch: Vec<u8>,
}

impl Default for TerminalModeTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl TerminalModeTracker {
    pub fn new() -> Self {
        Self {
            app_cursor_keys: false,
            app_keypad: false,
            origin_mode: false,
            primary_saved_origin: None,
            alt_saved_origin: None,
            declrmm_69: false,
            auto_wrap: true,
            report_focus: false,
            mouse_mode: 0,
            mouse_report_mode: 0,
            mouse_mode_stack: ModeStack4::default(),
            mouse_report_mode_stack: ModeStack4::default(),
            in_alt_screen: false,
            primary_kitty_stack: Vec::new(),
            alt_kitty_stack: Vec::new(),
            erase_scrollback_gen: 0,
            erase_display_gen: 0,
            bell_gen: 0,
            title_gen: 0,
            handover_title: None,
            saw_title_osc: false,
            in_tmux_title: false,
            last_observed_title: String::new(),
            sync_update_started_at: None,
            scan_state: EscapeScanState::Ground,
            utf8_state: Utf8ScanState::Ground,
            osc_head_len: 0,
            osc_head: [0; 3],
            csi_buf: Vec::with_capacity(64),
            csi_private_prefix: None,
            csi_has_params: false,
            csi_has_intermediate: false,
            csi_single_intermediate: None,
            csi_ignore: false,
            csi_tab_cur_param: None,
            csi_tab_invalid: false,
            csi_tab_saw_oversized: false,
            sanitize_scratch: Vec::new(),
        }
    }

    /// Exports current mode state for zero-downtime daemon handover.
    pub fn export_handover_modes(&self, terminal: &Terminal) -> HandoverTerminalModes {
        let term_title = terminal.get_title();
        let effective_title = if term_title == "wezterm" {
            self.handover_title.as_deref().unwrap_or(term_title)
        } else {
            term_title
        };
        let has_custom_title =
            term_title != "wezterm" || self.handover_title.is_some() || self.saw_title_osc;
        let cursor = terminal.cursor_pos();
        let cursor_style = match cursor.shape {
            CursorShape::Default => 0u8,
            CursorShape::BlinkingBlock => 1,
            CursorShape::SteadyBlock => 2,
            CursorShape::BlinkingUnderline => 3,
            CursorShape::SteadyUnderline => 4,
            CursorShape::BlinkingBar => 5,
            CursorShape::SteadyBar => 6,
        };
        let in_alt_screen = terminal.is_alt_screen_active();
        HandoverTerminalModes {
            app_cursor_keys: self.app_cursor_keys,
            app_keypad: self.app_keypad,
            origin_mode: self.origin_mode,
            auto_wrap: self.auto_wrap,
            report_focus: self.report_focus,
            mouse_mode: self.mouse_mode,
            mouse_report_mode: self.mouse_report_mode,
            kitty_keyboard_flags: self.kitty_keyboard_flags(in_alt_screen),
            in_alt_screen,
            primary_kitty_stack: self.primary_kitty_stack.clone(),
            alt_kitty_stack: self.alt_kitty_stack.clone(),
            bracketed_paste: terminal.bracketed_paste_enabled(),
            reverse_video: terminal.get_reverse_video(),
            cursor_visible: cursor.visibility == CursorVisibility::Visible,
            cursor_style,
            title: effective_title.to_owned(),
            has_custom_title,
            erase_scrollback_gen: self.erase_scrollback_gen,
            journal_clear_floor: 0,
            unjournaled_trimmed_top_rows: 0,
        }
    }

    /// Seeds initial screen state before replaying a truncated tail log.
    pub fn set_in_alt_screen(&mut self, in_alt_screen: bool) {
        self.in_alt_screen = in_alt_screen;
    }

    /// Restores authoritative mode state captured at handover completion.
    pub fn restore_handover_modes(&mut self, modes: &HandoverTerminalModes) {
        self.app_cursor_keys = modes.app_cursor_keys;
        self.app_keypad = modes.app_keypad;
        self.origin_mode = modes.origin_mode;
        self.auto_wrap = modes.auto_wrap;
        self.report_focus = modes.report_focus;
        self.mouse_mode = if (1..=4).contains(&modes.mouse_mode) {
            modes.mouse_mode
        } else {
            0
        };
        self.mouse_report_mode = if (1..=4).contains(&modes.mouse_report_mode) {
            modes.mouse_report_mode
        } else {
            0
        };
        self.mouse_mode_stack.set_only(self.mouse_mode);
        self.mouse_report_mode_stack
            .set_only(self.mouse_report_mode);
        self.in_alt_screen = modes.in_alt_screen;
        self.erase_scrollback_gen = self.erase_scrollback_gen.max(modes.erase_scrollback_gen);
        if !modes.primary_kitty_stack.is_empty() || !modes.alt_kitty_stack.is_empty() {
            let p_start = modes.primary_kitty_stack.len().saturating_sub(128);
            self.primary_kitty_stack.clear();
            self.primary_kitty_stack.extend(
                modes.primary_kitty_stack[p_start..]
                    .iter()
                    .map(|&f| f & 0x1f),
            );
            let a_start = modes.alt_kitty_stack.len().saturating_sub(128);
            self.alt_kitty_stack.clear();
            self.alt_kitty_stack
                .extend(modes.alt_kitty_stack[a_start..].iter().map(|&f| f & 0x1f));
        } else {
            self.primary_kitty_stack.clear();
            self.alt_kitty_stack.clear();
            let masked = modes.kitty_keyboard_flags & 0x1f;
            if masked != 0 {
                if self.in_alt_screen {
                    self.alt_kitty_stack.push(masked);
                } else {
                    self.primary_kitty_stack.push(masked);
                }
            }
        }
        if modes.has_custom_title || (!modes.title.is_empty() && modes.title != "wezterm") {
            self.handover_title = Some(modes.title.clone());
            self.saw_title_osc = true;
            self.last_observed_title.clone_from(&modes.title);
            self.title_gen = self.title_gen.wrapping_add(1);
        } else {
            self.handover_title = None;
        }
    }

    pub fn kitty_keyboard_flags(&self, is_alt_screen: bool) -> u32 {
        let stack = if is_alt_screen {
            &self.alt_kitty_stack
        } else {
            &self.primary_kitty_stack
        };
        stack.last().copied().unwrap_or(0)
    }

    pub fn erase_scrollback_gen(&self) -> u64 {
        self.erase_scrollback_gen
    }

    pub fn erase_display_gen(&self) -> u64 {
        self.erase_display_gen
    }

    pub fn bell_gen(&self) -> u64 {
        self.bell_gen
    }

    pub fn mouse_mode(&self) -> u32 {
        self.mouse_mode
    }

    pub fn mouse_report_mode(&self) -> u32 {
        self.mouse_report_mode
    }

    pub fn in_alt_screen(&self) -> bool {
        self.in_alt_screen
    }

    /// Returns whether DEC Mode 2026 (`\x1b[?2026h` without matching `\x1b[?2026l`)
    /// is currently open and has been active for less than `max_hold`.
    pub fn is_in_synchronized_update(&self, now: Instant, max_hold: Duration) -> bool {
        self.sync_update_started_at
            .is_some_and(|started| now.saturating_duration_since(started) < max_hold)
    }

    /// Syncs `last_observed_title` against `terminal.get_title()` (falling back
    /// to a handover-restored title only until the session updates or resets its
    /// title) and returns `(effective_title, title_gen)`.
    pub fn observe_terminal_title<'a>(&'a mut self, terminal: &'a Terminal) -> (&'a str, u64) {
        let term_title = terminal.get_title();
        if term_title != "wezterm" {
            self.handover_title = None;
        }
        let effective = if term_title == "wezterm"
            && let Some(ref h_title) = self.handover_title
        {
            h_title.as_str()
        } else {
            term_title
        };
        if effective != self.last_observed_title {
            let owned = effective.to_owned();
            self.last_observed_title = owned;
            self.title_gen = self.title_gen.wrapping_add(1);
        }
        (self.last_observed_title.as_str(), self.title_gen)
    }

    /// Scans `bytes` for control / CSI / DEC private mode sequences, updates
    /// sideband mode state across arbitrary chunk boundaries, and clamps
    /// oversized `CHT` (`CSI Ps I`) / `CBT` (`CSI Ps Z`) repeat counts to `cols`.
    ///
    /// Returns a slice to pass to `terminal.advance_bytes(...)`: either `bytes`
    /// directly (zero-copy common case) or `self.sanitize_scratch` when clamping
    /// rewrote an oversized tab repeat count.
    pub fn observe_and_sanitize<'a>(&'a mut self, bytes: &'a [u8], cols: usize) -> &'a [u8] {
        let (slice, _, _) = self.scan_slice(bytes, cols, false);
        slice
    }

    /// Like [`Self::observe_and_sanitize`], but stops immediately after the first
    /// primary-screen scrollback clear (`CSI ... 3 ... J` outside alt-screen, or
    /// `ESC c`), returning `(sanitized_prefix, raw_bytes_consumed, cleared_scrollback)`.
    pub fn observe_and_sanitize_until_scrollback_clear<'a>(
        &'a mut self,
        bytes: &'a [u8],
        cols: usize,
    ) -> (&'a [u8], usize, bool) {
        self.scan_slice(bytes, cols, true)
    }

    /// Scans `bytes` starting from a clone of `self`'s current mode state and
    /// returns the raw byte offset immediately after the last primary-screen
    /// scrollback clear (`CSI ... 3 ... J` outside alt-screen, or `ESC c`).
    pub fn last_scrollback_clear_end_in_raw_stream(&self, bytes: &[u8]) -> Option<usize> {
        let mut clone = self.clone();
        let mut pos = 0usize;
        let mut last_clear_end = None;
        while pos < bytes.len() {
            let (_, consumed, cleared) =
                clone.observe_and_sanitize_until_scrollback_clear(&bytes[pos..], 80);
            if consumed == 0 {
                break;
            }
            pos += consumed;
            if cleared {
                last_clear_end = Some(pos);
            }
        }
        last_clear_end
    }

    fn begin_utf8_lead(&mut self, b: u8) {
        self.utf8_state = match b {
            0xc2 => Utf8ScanState::Tail1C2,
            0xc3..=0xdf => Utf8ScanState::Tail1,
            0xe0 => Utf8ScanState::E0,
            0xe1..=0xec | 0xee..=0xef => Utf8ScanState::Tail2,
            0xed => Utf8ScanState::Ed,
            0xf0 => Utf8ScanState::F0,
            0xf1..=0xf3 => Utf8ScanState::Tail3,
            0xf4 => Utf8ScanState::F4,
            _ => Utf8ScanState::Ground,
        };
    }

    fn scan_slice<'a>(
        &'a mut self,
        bytes: &'a [u8],
        cols: usize,
        stop_on_scrollback_clear: bool,
    ) -> (&'a [u8], usize, bool) {
        let cols = cols.max(1);
        if bytes.is_empty() {
            return (bytes, 0, false);
        }
        if self.scan_state == EscapeScanState::Ground
            && self.utf8_state == Utf8ScanState::Ground
            && bytes.iter().all(|&b| b < 0x80 && b != 0x1b && b != 0x07)
        {
            return (bytes, bytes.len(), false);
        }

        let start_erase_gen = self.erase_scrollback_gen;
        let mut modified = false;
        let mut copied_up_to = 0usize;
        let mut consumed = bytes.len();

        for (i, &b) in bytes.iter().enumerate() {
            let iter_prev_alt = self.in_alt_screen;
            if self.utf8_state != Utf8ScanState::Ground {
                match self.utf8_state {
                    Utf8ScanState::Ground => unreachable!(),
                    Utf8ScanState::Tail1C2 => {
                        self.utf8_state = Utf8ScanState::Ground;
                        if !(0x80..=0x9f).contains(&b) {
                            // Either valid non-C1 (`U+00A0..U+00BF`) or invalid
                            // continuation (`U+FFFD` in vtparse/utf8parse); both
                            // consume `b` without dispatching a VT transition.
                            continue;
                        }
                        // UTF-8 encoded C1 control (`U+0080..U+009F`): vtparse
                        // dispatches this against the underlying Ground/Osc state.
                    }
                    Utf8ScanState::Tail1 => {
                        self.utf8_state = Utf8ScanState::Ground;
                        continue;
                    }
                    Utf8ScanState::Tail2 => {
                        self.utf8_state = if (0x80..=0xbf).contains(&b) {
                            Utf8ScanState::Tail1
                        } else {
                            Utf8ScanState::Ground
                        };
                        continue;
                    }
                    Utf8ScanState::E0 => {
                        self.utf8_state = if (0xa0..=0xbf).contains(&b) {
                            Utf8ScanState::Tail1
                        } else {
                            Utf8ScanState::Ground
                        };
                        continue;
                    }
                    Utf8ScanState::Ed => {
                        self.utf8_state = if (0x80..=0x9f).contains(&b) {
                            Utf8ScanState::Tail1
                        } else {
                            Utf8ScanState::Ground
                        };
                        continue;
                    }
                    Utf8ScanState::Tail3 => {
                        self.utf8_state = if (0x80..=0xbf).contains(&b) {
                            Utf8ScanState::Tail2
                        } else {
                            Utf8ScanState::Ground
                        };
                        continue;
                    }
                    Utf8ScanState::F0 => {
                        self.utf8_state = if (0x90..=0xbf).contains(&b) {
                            Utf8ScanState::Tail2
                        } else {
                            Utf8ScanState::Ground
                        };
                        continue;
                    }
                    Utf8ScanState::F4 => {
                        self.utf8_state = if (0x80..=0x8f).contains(&b) {
                            Utf8ScanState::Tail2
                        } else {
                            Utf8ScanState::Ground
                        };
                        continue;
                    }
                }
            }

            // `Anywhere` transitions from vtparse (`CAN`, `SUB`, `ESC`, and 8-bit C1).
            match b {
                0x18 | 0x1a => {
                    if self.scan_state == EscapeScanState::Osc {
                        self.finish_osc();
                    }
                    self.in_tmux_title = false;
                    self.scan_state = EscapeScanState::Ground;
                    continue;
                }
                0x1b => {
                    if self.scan_state == EscapeScanState::Osc {
                        self.finish_osc();
                    }
                    if self.scan_state != EscapeScanState::StString {
                        self.in_tmux_title = false;
                    }
                    self.scan_state = EscapeScanState::Escape {
                        has_intermediate: false,
                    };
                    continue;
                }
                0x9c => {
                    if self.scan_state == EscapeScanState::Osc {
                        self.finish_osc();
                    } else if self.scan_state == EscapeScanState::StString && self.in_tmux_title {
                        self.handover_title = None;
                        self.saw_title_osc = true;
                    }
                    self.in_tmux_title = false;
                    self.scan_state = EscapeScanState::Ground;
                    continue;
                }
                0x90 | 0x98 | 0x9e | 0x9f
                    if matches!(
                        self.scan_state,
                        EscapeScanState::Ground
                            | EscapeScanState::Escape { .. }
                            | EscapeScanState::Csi
                            | EscapeScanState::Osc
                            | EscapeScanState::StString
                    ) =>
                {
                    if self.scan_state == EscapeScanState::Osc {
                        self.finish_osc();
                    }
                    self.in_tmux_title = false;
                    self.scan_state = EscapeScanState::StString;
                    continue;
                }
                0x9d => {
                    if self.scan_state == EscapeScanState::Osc {
                        self.finish_osc();
                    }
                    self.in_tmux_title = false;
                    self.enter_osc();
                    continue;
                }
                0x9b => {
                    if self.scan_state == EscapeScanState::Osc {
                        self.finish_osc();
                    }
                    self.in_tmux_title = false;
                    self.enter_csi();
                    continue;
                }
                0x80..=0x8f | 0x91..=0x97 | 0x99 | 0x9a => {
                    if self.scan_state == EscapeScanState::Osc {
                        self.finish_osc();
                    }
                    self.in_tmux_title = false;
                    self.scan_state = EscapeScanState::Ground;
                    continue;
                }
                _ => {}
            }

            match self.scan_state {
                EscapeScanState::Ground => match b {
                    0x07 => {
                        self.bell_gen = self.bell_gen.wrapping_add(1);
                    }
                    0xc2..=0xf4 => {
                        self.begin_utf8_lead(b);
                    }
                    _ => {}
                },
                EscapeScanState::Escape { has_intermediate } => match b {
                    0x7f => {}
                    0x00..=0x17 | 0x19 | 0x1c..=0x1f => {
                        if b == 0x07 {
                            self.bell_gen = self.bell_gen.wrapping_add(1);
                        }
                    }
                    0x20..=0x2f => {
                        self.in_tmux_title = false;
                        self.scan_state = EscapeScanState::Escape {
                            has_intermediate: true,
                        };
                    }
                    b'\\' if !has_intermediate => {
                        if self.in_tmux_title {
                            self.handover_title = None;
                            self.saw_title_osc = true;
                            self.in_tmux_title = false;
                        }
                        self.scan_state = EscapeScanState::Ground;
                    }
                    b'[' if !has_intermediate => {
                        self.in_tmux_title = false;
                        self.enter_csi();
                    }
                    b']' if !has_intermediate => {
                        self.in_tmux_title = false;
                        self.enter_osc();
                    }
                    b'k' if !has_intermediate => {
                        self.in_tmux_title = true;
                        self.scan_state = EscapeScanState::StString;
                    }
                    b'P' | b'X' | b'^' | b'_' if !has_intermediate => {
                        self.in_tmux_title = false;
                        self.scan_state = EscapeScanState::StString;
                    }
                    b'7' if !has_intermediate => {
                        self.in_tmux_title = false;
                        self.save_cursor_origin();
                        self.scan_state = EscapeScanState::Ground;
                    }
                    b'8' if !has_intermediate => {
                        self.in_tmux_title = false;
                        self.restore_cursor_origin();
                        self.scan_state = EscapeScanState::Ground;
                    }
                    b'=' if !has_intermediate => {
                        self.in_tmux_title = false;
                        self.app_keypad = true;
                        self.scan_state = EscapeScanState::Ground;
                    }
                    b'>' if !has_intermediate => {
                        self.in_tmux_title = false;
                        self.app_keypad = false;
                        self.scan_state = EscapeScanState::Ground;
                    }
                    b'c' if !has_intermediate => {
                        self.in_tmux_title = false;
                        self.reset_modes();
                        self.scan_state = EscapeScanState::Ground;
                    }
                    0x30..=0x7e => {
                        self.in_tmux_title = false;
                        self.scan_state = EscapeScanState::Ground;
                    }
                    _ => {}
                },
                EscapeScanState::Osc => match b {
                    0x07 => {
                        self.finish_osc();
                        self.scan_state = EscapeScanState::Ground;
                    }
                    0x20..=0x7e => {
                        if (self.osc_head_len as usize) < self.osc_head.len() {
                            self.osc_head[self.osc_head_len as usize] = b;
                            self.osc_head_len += 1;
                        }
                    }
                    0xc2..=0xf4 => {
                        self.begin_utf8_lead(b);
                    }
                    _ => {}
                },
                EscapeScanState::StString => {
                    // DCS, SOS, PM, APC, and TmuxTitle ignore 0x07 (BEL) and remain
                    // open until ST (`ESC \` or `0x9c`), `CAN` (`0x18`), `SUB` (`0x1a`),
                    // or a new `ESC` (`0x1b`), all handled by the Anywhere match above.
                }
                EscapeScanState::Csi => match b {
                    0x7f => {}
                    0x00..=0x17 | 0x19 | 0x1c..=0x1f => {
                        if b == 0x07 {
                            self.bell_gen = self.bell_gen.wrapping_add(1);
                        }
                    }
                    0x3c..=0x3f => {
                        if !self.csi_has_params
                            && !self.csi_has_intermediate
                            && self.csi_private_prefix.is_none()
                        {
                            self.csi_private_prefix = Some(b);
                            if self.csi_buf.len() < 4096 {
                                self.csi_buf.push(b);
                            }
                        } else {
                            self.csi_ignore = true;
                        }
                    }
                    0x30..=0x3b => {
                        if self.csi_has_intermediate
                            || (!self.csi_has_params
                                && self.csi_private_prefix.is_none()
                                && b == b':')
                        {
                            self.csi_ignore = true;
                        } else {
                            self.csi_has_params = true;
                            if self.csi_buf.len() < 4096 {
                                self.csi_buf.push(b);
                            }
                            if !self.csi_ignore && self.csi_private_prefix.is_none() {
                                if b == b';' || b == b':' {
                                    // Multi-parameter or subparameter CHT/CBT is
                                    // rejected as Unspecified by wezterm-escape-parser.
                                    self.csi_tab_invalid = true;
                                } else if !self.csi_tab_invalid && b.is_ascii_digit() {
                                    let next = self
                                        .csi_tab_cur_param
                                        .unwrap_or(0)
                                        .saturating_mul(10)
                                        .saturating_add(u64::from(b - b'0'));
                                    if next > cols as u64 {
                                        self.csi_tab_saw_oversized = true;
                                    }
                                    self.csi_tab_cur_param = Some(next);
                                }
                            }
                        }
                    }
                    0x20..=0x2f => {
                        if !self.csi_has_intermediate {
                            self.csi_has_intermediate = true;
                            self.csi_single_intermediate = Some(b);
                        } else {
                            self.csi_single_intermediate = None;
                        }
                    }
                    0x40..=0x7e => {
                        let final_byte = b;
                        self.scan_state = EscapeScanState::Ground;

                        if !self.csi_ignore
                            && final_byte == b'p'
                            && self.csi_private_prefix.is_none()
                            && !self.csi_has_params
                            && self.csi_single_intermediate == Some(b'!')
                        {
                            self.apply_soft_reset();
                        } else if !self.csi_ignore && !self.csi_has_intermediate {
                            if self.csi_private_prefix.is_none() && !self.csi_has_params {
                                if final_byte == b's' && !self.declrmm_69 {
                                    self.save_cursor_origin();
                                } else if final_byte == b'u' {
                                    self.restore_cursor_origin();
                                }
                            }
                            self.inspect_csi_buf(final_byte);

                            if (final_byte == b'I' || final_byte == b'Z')
                                && self.csi_private_prefix.is_none()
                                && !self.csi_tab_invalid
                            {
                                let step = self.csi_tab_cur_param.take().unwrap_or(1).max(1);
                                if step <= u64::from(u32::MAX) && self.csi_tab_saw_oversized {
                                    let clamped = (step as usize).min(cols);
                                    // Replace the final `I`/`Z` byte with `\x1b[<clamped>I/Z`.
                                    // Leading `0x1b` causes vtparse in `Terminal` to discard
                                    // the in-flight oversized CSI (including split-chunk or
                                    // C1 `0x9b` prefixes) without dispatching it, then run
                                    // the clamped tabulation immediately.
                                    if !modified {
                                        self.sanitize_scratch.clear();
                                        self.sanitize_scratch.reserve(bytes.len() + 16);
                                        modified = true;
                                    }
                                    self.sanitize_scratch
                                        .extend_from_slice(&bytes[copied_up_to..i]);
                                    self.sanitize_scratch.extend_from_slice(b"\x1b[");
                                    let mut num_buf = [0u8; 16];
                                    let num_len = write_usize_ascii(clamped, &mut num_buf);
                                    self.sanitize_scratch.extend_from_slice(&num_buf[..num_len]);
                                    self.sanitize_scratch.push(final_byte);
                                    copied_up_to = i + 1;
                                }
                            }
                        }
                        self.csi_buf.clear();
                    }
                    _ => {}
                },
            }

            let alt_changed = iter_prev_alt != self.in_alt_screen;
            if stop_on_scrollback_clear
                && (self.erase_scrollback_gen != start_erase_gen || alt_changed)
            {
                consumed = i + 1;
                break;
            }
        }

        let cleared = self.erase_scrollback_gen != start_erase_gen;
        if modified {
            if copied_up_to < consumed {
                self.sanitize_scratch
                    .extend_from_slice(&bytes[copied_up_to..consumed]);
            }
            (&self.sanitize_scratch, consumed, cleared)
        } else {
            (&bytes[..consumed], consumed, cleared)
        }
    }

    fn scan_for_first_alt_transition(&mut self, bytes: &[u8]) -> Option<AltScreenTransition> {
        let mut first_alt = None;
        for (idx, &b) in bytes.iter().enumerate() {
            let was_esc = self.utf8_state == Utf8ScanState::Ground
                && matches!(
                    self.scan_state,
                    EscapeScanState::Escape {
                        has_intermediate: false
                    }
                );
            let was_decstr = self.utf8_state == Utf8ScanState::Ground
                && self.scan_state == EscapeScanState::Csi
                && !self.csi_ignore
                && self.csi_private_prefix.is_none()
                && !self.csi_has_params
                && self.csi_single_intermediate == Some(b'!')
                && b == b'p';
            let was_csi = self.utf8_state == Utf8ScanState::Ground
                && self.scan_state == EscapeScanState::Csi
                && !self.csi_ignore
                && !self.csi_has_intermediate
                && self.csi_private_prefix == Some(b'?');
            let csi_snapshot = if was_csi && (b == b'h' || b == b'l') {
                Some((self.csi_buf.clone(), b == b'h'))
            } else {
                None
            };
            let single = [b];
            let _ = self.scan_slice(&single, 80, false);
            if (was_esc && b == b'c') || was_decstr {
                break;
            }
            if let Some((buf, enabled)) = csi_snapshot {
                let body = buf.strip_prefix(b"?").unwrap_or(&buf);
                for_each_wezterm_dec_private_mode(body, |code| {
                    if first_alt.is_none() && matches!(code, 47 | 1047 | 1049) {
                        first_alt = Some((
                            idx,
                            if enabled {
                                AltScreenTransition::Entered
                            } else {
                                AltScreenTransition::Exited
                            },
                        ));
                    }
                });
                if first_alt.is_some() {
                    break;
                }
            }
        }
        first_alt.map(|(_, t)| t)
    }

    fn scan_initial_replay_modes(
        &mut self,
        bytes: &[u8],
        end_modes: &HandoverTerminalModes,
    ) -> InferredInitialReplayModes {
        let mut first_alt: Option<(usize, AltScreenTransition)> = None;
        let mut cur_in_alt: Option<bool> = None;
        let mut saw_reset_before_alt = false;
        let mut first_auto_wrap_enabled: Option<bool> = None;
        let mut auto_wrap_before_alt_transition = false;
        let mut saw_reset_before_auto_wrap = false;
        let mut first_origin_enabled: Option<bool> = None;
        let mut origin_before_alt_transition = false;
        let mut saw_reset_or_restore_before_origin = false;
        let mut saw_alt_exit_1049_before_origin = false;
        let mut saved_initial_m0 = false;
        let mut saved_primary_m0 = false;
        let mut saved_alt_m0 = false;
        let mut declrmm_active = false;

        for (idx, &b) in bytes.iter().enumerate() {
            let was_esc = self.utf8_state == Utf8ScanState::Ground
                && matches!(
                    self.scan_state,
                    EscapeScanState::Escape {
                        has_intermediate: false
                    }
                );
            let was_decstr = self.utf8_state == Utf8ScanState::Ground
                && self.scan_state == EscapeScanState::Csi
                && !self.csi_ignore
                && self.csi_private_prefix.is_none()
                && !self.csi_has_params
                && self.csi_single_intermediate == Some(b'!')
                && b == b'p';
            let was_plain_csi_no_params = self.utf8_state == Utf8ScanState::Ground
                && self.scan_state == EscapeScanState::Csi
                && !self.csi_ignore
                && !self.csi_has_intermediate
                && !self.csi_has_params
                && self.csi_private_prefix.is_none();
            let was_csi = self.utf8_state == Utf8ScanState::Ground
                && self.scan_state == EscapeScanState::Csi
                && !self.csi_ignore
                && !self.csi_has_intermediate
                && self.csi_private_prefix == Some(b'?');
            let csi_snapshot = if was_csi && (b == b'h' || b == b'l') {
                Some((self.csi_buf.clone(), b == b'h'))
            } else {
                None
            };
            let single = [b];
            let _ = self.scan_slice(&single, 80, false);

            if (was_esc && b == b'c') || was_decstr {
                if first_alt.is_none() {
                    saw_reset_before_alt = true;
                }
                if first_auto_wrap_enabled.is_none() {
                    saw_reset_before_auto_wrap = true;
                }
                if first_origin_enabled.is_none() {
                    saw_reset_or_restore_before_origin = true;
                }
                break;
            }

            let origin_still_m0 =
                first_origin_enabled.is_none() && !saw_reset_or_restore_before_origin;
            if origin_still_m0
                && ((was_esc && b == b'7')
                    || (was_plain_csi_no_params && b == b's' && !declrmm_active))
            {
                match cur_in_alt {
                    None => saved_initial_m0 = true,
                    Some(true) => saved_alt_m0 = true,
                    Some(false) => saved_primary_m0 = true,
                }
            } else if origin_still_m0
                && ((was_esc && b == b'8') || (was_plain_csi_no_params && b == b'u'))
            {
                let has_m0 = match cur_in_alt {
                    None => saved_initial_m0,
                    Some(true) => saved_alt_m0,
                    Some(false) => saved_primary_m0,
                };
                if !has_m0 {
                    saw_reset_or_restore_before_origin = true;
                }
            }

            if let Some((buf, enabled)) = csi_snapshot {
                let body = buf.strip_prefix(b"?").unwrap_or(&buf);
                for_each_wezterm_dec_private_mode(body, |code| match code {
                    69 => {
                        declrmm_active = enabled;
                    }
                    47 | 1047 | 1049 => {
                        let origin_still_m0 =
                            first_origin_enabled.is_none() && !saw_reset_or_restore_before_origin;
                        if first_alt.is_none() && !saw_reset_before_alt {
                            first_alt = Some((
                                idx,
                                if enabled {
                                    AltScreenTransition::Entered
                                } else {
                                    AltScreenTransition::Exited
                                },
                            ));
                            if enabled {
                                cur_in_alt = Some(true);
                                saved_primary_m0 =
                                    saved_initial_m0 || (code == 1049 && origin_still_m0);
                                saved_alt_m0 = false;
                            } else {
                                cur_in_alt = Some(false);
                                saved_primary_m0 = false;
                                saved_alt_m0 = saved_initial_m0;
                                if code == 1049 && origin_still_m0 {
                                    saw_alt_exit_1049_before_origin = true;
                                }
                            }
                        } else if let Some(in_alt) = cur_in_alt {
                            if code == 1049 {
                                if enabled && !in_alt {
                                    if origin_still_m0 {
                                        saved_primary_m0 = true;
                                    }
                                    cur_in_alt = Some(true);
                                } else if !enabled && in_alt {
                                    cur_in_alt = Some(false);
                                    if origin_still_m0 && !saved_primary_m0 {
                                        saw_reset_or_restore_before_origin = true;
                                    }
                                }
                            } else {
                                cur_in_alt = Some(enabled);
                            }
                        }
                    }
                    1048 if first_origin_enabled.is_none()
                        && !saw_reset_or_restore_before_origin =>
                    {
                        if enabled {
                            match cur_in_alt {
                                None => saved_initial_m0 = true,
                                Some(true) => saved_alt_m0 = true,
                                Some(false) => saved_primary_m0 = true,
                            }
                        } else {
                            let has_m0 = match cur_in_alt {
                                None => saved_initial_m0,
                                Some(true) => saved_alt_m0,
                                Some(false) => saved_primary_m0,
                            };
                            if !has_m0 {
                                saw_reset_or_restore_before_origin = true;
                            }
                        }
                    }
                    7 if first_auto_wrap_enabled.is_none() && !saw_reset_before_auto_wrap => {
                        auto_wrap_before_alt_transition = first_alt.is_none();
                        first_auto_wrap_enabled = Some(enabled);
                    }
                    6 if first_origin_enabled.is_none() && !saw_reset_or_restore_before_origin => {
                        origin_before_alt_transition = first_alt.is_none();
                        first_origin_enabled = Some(enabled);
                    }
                    _ => {}
                });
            }
            if (first_alt.is_some() || saw_reset_before_alt)
                && (first_auto_wrap_enabled.is_some() || saw_reset_before_auto_wrap)
                && (first_origin_enabled.is_some() || saw_reset_or_restore_before_origin)
            {
                break;
            }
        }

        let (in_alt_screen, first_alt_exit_offset) = match first_alt {
            Some((_, AltScreenTransition::Entered)) => (false, None),
            Some((off, AltScreenTransition::Exited)) => (true, Some(off)),
            None if saw_reset_before_alt => (false, None),
            None => (end_modes.in_alt_screen, None),
        };
        let mut inferred = InferredInitialReplayModes {
            in_alt_screen,
            first_alt_exit_offset,
            auto_wrap: true,
            origin_mode: false,
            first_auto_wrap_enabled,
            auto_wrap_before_alt_transition,
            saw_reset_before_auto_wrap,
            end_auto_wrap: end_modes.auto_wrap,
            first_origin_enabled,
            origin_before_alt_transition,
            saw_reset_or_restore_before_origin,
            saw_alt_exit_1049_before_origin,
            end_origin_mode: end_modes.origin_mode,
        };
        let (auto_wrap, origin_mode) = inferred.modes_for_screen(in_alt_screen);
        inferred.auto_wrap = auto_wrap;
        inferred.origin_mode = origin_mode;
        inferred
    }

    fn save_cursor_origin(&mut self) {
        if self.in_alt_screen {
            self.alt_saved_origin = Some(self.origin_mode);
        } else {
            self.primary_saved_origin = Some(self.origin_mode);
        }
    }

    fn restore_cursor_origin(&mut self) {
        self.origin_mode = if self.in_alt_screen {
            self.alt_saved_origin.unwrap_or(false)
        } else {
            self.primary_saved_origin.unwrap_or(false)
        };
    }

    fn enter_csi(&mut self) {
        self.csi_buf.clear();
        self.csi_private_prefix = None;
        self.csi_has_params = false;
        self.csi_has_intermediate = false;
        self.csi_single_intermediate = None;
        self.csi_ignore = false;
        self.csi_tab_cur_param = None;
        self.csi_tab_invalid = false;
        self.csi_tab_saw_oversized = false;
        self.scan_state = EscapeScanState::Csi;
    }

    fn apply_soft_reset(&mut self) {
        self.app_cursor_keys = false;
        self.app_keypad = false;
        self.origin_mode = false;
        self.primary_saved_origin = None;
        self.alt_saved_origin = None;
        self.declrmm_69 = false;
        self.auto_wrap = true;
        self.in_alt_screen = false;
    }

    fn enter_osc(&mut self) {
        self.osc_head_len = 0;
        self.osc_head = [0; 3];
        self.scan_state = EscapeScanState::Osc;
    }

    fn finish_osc(&mut self) {
        let head = &self.osc_head[..self.osc_head_len as usize];
        // OSC 0 (`0;...`), OSC 2 (`2;...`), empty selector (`;...`), or Sun
        // window title (`l...`) sets the window title in wezterm-term,
        // superseding any handover fallback.
        if head.starts_with(b"0;")
            || head.starts_with(b"2;")
            || head.starts_with(b";")
            || head.starts_with(b"l")
        {
            self.handover_title = None;
            self.saw_title_osc = true;
        }
        self.osc_head_len = 0;
    }

    fn reset_modes(&mut self) {
        self.app_cursor_keys = false;
        self.app_keypad = false;
        self.origin_mode = false;
        self.primary_saved_origin = None;
        self.alt_saved_origin = None;
        self.declrmm_69 = false;
        self.auto_wrap = true;
        self.report_focus = false;
        self.mouse_mode = 0;
        self.mouse_report_mode = 0;
        self.mouse_mode_stack.clear();
        self.mouse_report_mode_stack.clear();
        self.in_alt_screen = false;
        self.primary_kitty_stack.clear();
        self.alt_kitty_stack.clear();
        self.handover_title = None;
        self.saw_title_osc = false;
        self.in_tmux_title = false;
        self.sync_update_started_at = None;
        self.erase_display_gen = self.erase_display_gen.wrapping_add(1);
        self.erase_scrollback_gen = self.erase_scrollback_gen.wrapping_add(1);
    }

    fn active_kitty_stack_mut(&mut self) -> &mut Vec<u32> {
        if self.in_alt_screen {
            &mut self.alt_kitty_stack
        } else {
            &mut self.primary_kitty_stack
        }
    }

    fn inspect_csi_buf(&mut self, final_byte: u8) {
        if self.csi_private_prefix.is_some() && !matches!(final_byte, b'u' | b'h' | b'l') {
            return;
        }
        let buf = std::mem::take(&mut self.csi_buf);
        match final_byte {
            b'J' if self.csi_private_prefix.is_none() => {
                // `wezterm-escape-parser` only accepts 0 or 1 integer param for `J`.
                if !buf.contains(&b';') && !buf.contains(&b':') {
                    let code = if buf.is_empty() {
                        Some(0)
                    } else {
                        parse_u32_strict_ascii(&buf)
                    };
                    if code == Some(2) {
                        self.erase_display_gen = self.erase_display_gen.wrapping_add(1);
                    } else if code == Some(3) && !self.in_alt_screen {
                        self.erase_scrollback_gen = self.erase_scrollback_gen.wrapping_add(1);
                    }
                }
            }
            b'u' => {
                match buf.first().copied() {
                    Some(b'>') if !buf[1..].contains(&b':') => {
                        let parts: Vec<&[u8]> = buf[1..].split(|&c| c == b';').collect();
                        let parsed = match parts.as_slice() {
                            [b""] => Some((0u32, 1u32)),
                            [f] => parse_u16_strict_ascii(f)
                                .map(|flags| (u32::from(flags) & 0x1f, 1u32)),
                            [f, m] => match (
                                if f.is_empty() {
                                    Some(0u16)
                                } else {
                                    parse_u16_strict_ascii(f)
                                },
                                parse_u16_strict_ascii(m),
                            ) {
                                (Some(flags), Some(mode @ 1..=3)) => {
                                    Some((u32::from(flags) & 0x1f, u32::from(mode)))
                                }
                                _ => None,
                            },
                            _ => None,
                        };
                        if let Some((flags, mode)) = parsed {
                            let stack = self.active_kitty_stack_mut();
                            let current = stack.last().copied().unwrap_or(0);
                            let pushed = match mode {
                                2 => current | flags,
                                3 => current & !flags,
                                _ => flags,
                            };
                            if stack.len() >= 128 {
                                stack.remove(0);
                            }
                            stack.push(pushed);
                        }
                    }
                    Some(b'<') if !buf[1..].contains(&b';') && !buf[1..].contains(&b':') => {
                        let parsed = if buf[1..].is_empty() {
                            Some(1usize)
                        } else {
                            parse_u32_strict_ascii(&buf[1..]).map(|n| n as usize)
                        };
                        if let Some(pop_count) = parsed {
                            let stack = self.active_kitty_stack_mut();
                            let new_len = stack.len().saturating_sub(pop_count);
                            stack.truncate(new_len);
                        }
                    }
                    Some(b'=') if !buf[1..].contains(&b':') => {
                        let parts: Vec<&[u8]> = buf[1..].split(|&c| c == b';').collect();
                        let parsed = match parts.as_slice() {
                            [f] if !f.is_empty() => parse_u16_strict_ascii(f)
                                .map(|flags| (u32::from(flags) & 0x1f, 1u32)),
                            [f, m] if !f.is_empty() => {
                                match (parse_u16_strict_ascii(f), parse_u16_strict_ascii(m)) {
                                    (Some(flags), Some(mode @ 1..=3)) => {
                                        Some((u32::from(flags) & 0x1f, u32::from(mode)))
                                    }
                                    _ => None,
                                }
                            }
                            _ => None,
                        };
                        if let Some((flags, mode)) = parsed {
                            let stack = self.active_kitty_stack_mut();
                            let current = stack.last().copied().unwrap_or(0);
                            let updated = match mode {
                                2 => current | flags,
                                3 => current & !flags,
                                _ => flags,
                            };
                            if let Some(top) = stack.last_mut() {
                                *top = updated;
                            } else {
                                stack.push(updated);
                            }
                        }
                    }
                    _ => {}
                }
            }
            b'h' | b'l' if buf.first() == Some(&b'?') => {
                let enabled = final_byte == b'h';
                for_each_wezterm_dec_private_mode(&buf[1..], |code| {
                    self.apply_dec_private_mode(u32::from(code), enabled);
                });
            }
            _ => {}
        }
        self.csi_buf = buf;
    }

    fn apply_dec_private_mode(&mut self, code: u32, enabled: bool) {
        match code {
            1 => self.app_cursor_keys = enabled,
            6 => self.origin_mode = enabled,
            7 => self.auto_wrap = enabled,
            47 | 1047 => {
                self.in_alt_screen = enabled;
            }
            1048 => {
                if enabled {
                    self.save_cursor_origin();
                } else {
                    self.restore_cursor_origin();
                }
            }
            1049 => {
                if enabled {
                    if !self.in_alt_screen {
                        self.primary_saved_origin = Some(self.origin_mode);
                        self.in_alt_screen = true;
                    }
                } else if self.in_alt_screen {
                    self.in_alt_screen = false;
                    self.origin_mode = self.primary_saved_origin.unwrap_or(false);
                }
            }
            66 => self.app_keypad = enabled,
            69 => self.declrmm_69 = enabled,
            9 => {
                self.mouse_mode_stack.apply(1, enabled);
                self.mouse_mode = self.mouse_mode_stack.current();
            }
            1000 => {
                self.mouse_mode_stack.apply(2, enabled);
                self.mouse_mode = self.mouse_mode_stack.current();
            }
            1002 => {
                self.mouse_mode_stack.apply(3, enabled);
                self.mouse_mode = self.mouse_mode_stack.current();
            }
            1003 => {
                self.mouse_mode_stack.apply(4, enabled);
                self.mouse_mode = self.mouse_mode_stack.current();
            }
            1004 => self.report_focus = enabled,
            1005 => {
                self.mouse_report_mode_stack.apply(1, enabled);
                self.mouse_report_mode = self.mouse_report_mode_stack.current();
            }
            1006 => {
                self.mouse_report_mode_stack.apply(2, enabled);
                self.mouse_report_mode = self.mouse_report_mode_stack.current();
            }
            1015 => {
                self.mouse_report_mode_stack.apply(3, enabled);
                self.mouse_report_mode = self.mouse_report_mode_stack.current();
            }
            1016 => {
                self.mouse_report_mode_stack.apply(4, enabled);
                self.mouse_report_mode = self.mouse_report_mode_stack.current();
            }
            2026 => {
                if enabled {
                    if self.sync_update_started_at.is_none() {
                        self.sync_update_started_at = Some(Instant::now());
                    }
                } else {
                    self.sync_update_started_at = None;
                }
            }
            _ => {}
        }
    }
}

/// Before `Screen::resize` runs `rewrap_lines`, it pops trailing whitespace
/// lines after the cursor. If the last surviving line still has
/// `last_cell_was_wrapped() == true`, `rewrap_lines` holds it in `logical_line`
/// waiting for a continuation line and drops it at loop end.
pub fn prevent_trailing_wrapped_line_drop_on_resize(terminal: &mut Terminal) {
    if terminal.is_alt_screen_active() {
        return;
    }
    let seqno = terminal.current_seqno();
    let cursor_y = terminal.cursor_pos().y;
    let screen = terminal.screen_mut();
    let total = screen.scrollback_rows();
    if total == 0 {
        return;
    }
    let cursor_phys = screen.phys_row(cursor_y);
    let mut last_surviving = total - 1;
    while last_surviving > cursor_phys {
        if screen.line_mut(last_surviving).is_whitespace() {
            last_surviving -= 1;
        } else {
            break;
        }
    }
    let last_line = screen.line_mut(last_surviving);
    if last_line.last_cell_was_wrapped() {
        last_line.set_last_cell_was_wrapped(false, seqno);
    }
}

/// Compressed or raw `TCG1` binary cell batch ready for transport.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EncodedCellBatch {
    pub compression: u8,
    pub payload: Vec<u8>,
    pub row_count: u32,
}

/// Builder for a `TCG1` binary cell batch (`viewport` dirty rows, inline pushed
/// scrollback rows, or random-access `FetchTerminalRows` pages).
#[derive(Debug, Default)]
pub struct Tcg1BatchBuilder {
    line_headers: Vec<u32>,
    cell_words: Vec<u32>,
    combining_words: Vec<u32>,
    row_scratch: Vec<u32>,
    combining_scratch: Vec<(u32, u32)>,
}

impl Tcg1BatchBuilder {
    pub fn with_row_capacity(rows: usize, cols: usize) -> Self {
        Self {
            line_headers: Vec::with_capacity(rows * 2),
            cell_words: Vec::with_capacity(rows * cols.min(64) * CELL_WORDS),
            combining_words: Vec::new(),
            row_scratch: Vec::with_capacity(cols * CELL_WORDS),
            combining_scratch: Vec::new(),
        }
    }

    pub fn clear(&mut self) {
        self.line_headers.clear();
        self.cell_words.clear();
        self.combining_words.clear();
    }

    pub fn row_count(&self) -> u32 {
        (self.line_headers.len() / 2) as u32
    }

    pub fn is_empty(&self) -> bool {
        self.line_headers.is_empty()
    }

    /// Appends a `tattoy_wezterm_surface::Line` at `row_index` (relative to the
    /// batch's base row) with logical width `logical_cols`.
    pub fn push_wezterm_line(&mut self, row_index: u32, line: &Line, logical_cols: usize) {
        let clamped_cols = logical_cols.clamp(1, MAX_ENCODED_COLS);
        let line_entry_idx = self.row_count();
        self.row_scratch.clear();
        self.row_scratch.resize(clamped_cols * CELL_WORDS, 0);
        self.combining_scratch.clear();

        let wraps_next = line.last_cell_was_wrapped();
        let mut stored_cols = 0usize;

        if line.len() > 0 {
            let blank_attrs = CellAttributes::blank();
            for cell in line.visible_cells() {
                let col = cell.cell_index();
                if col >= clamped_cols {
                    continue;
                }
                let attrs = cell.attrs();
                let text = cell.str();
                let raw_width = cell.width().clamp(1, 2);
                let width = if raw_width == 2 && col + 1 < clamped_cols {
                    2
                } else {
                    1
                };
                let is_default_space = text == " " && attrs == &blank_attrs && width == 1;

                let fg = encode_color(attrs.foreground());
                let bg = encode_color(attrs.background());
                let attr_flags = encode_attrs(attrs);
                let mut chars = text.chars();
                let first_char = chars.next().unwrap_or(' ');
                let cp = (first_char as u32) & CONTENT_CODEPOINT_MASK;
                let content = cp | ((width as u32) << CONTENT_WIDTH_SHIFT);

                let word_idx = col * CELL_WORDS;
                self.row_scratch[word_idx] = fg;
                self.row_scratch[word_idx + 1] = bg;
                self.row_scratch[word_idx + 2] = attr_flags;
                self.row_scratch[word_idx + 3] = content;

                let mut cell_end = col + 1;
                if width == 2 {
                    let trail_idx = (col + 1) * CELL_WORDS;
                    self.row_scratch[trail_idx] = fg;
                    self.row_scratch[trail_idx + 1] = bg;
                    self.row_scratch[trail_idx + 2] = attr_flags;
                    self.row_scratch[trail_idx + 3] = 0;
                    cell_end = col + 2;
                }

                let mut cell_has_combining = false;
                for extra in chars {
                    cell_has_combining = true;
                    self.combining_scratch.push((col as u32, extra as u32));
                }

                if !is_default_space || cell_has_combining || wraps_next {
                    stored_cols = stored_cols.max(cell_end);
                }
            }
        }

        let mut has_combining = false;
        for &(col, cp) in &self.combining_scratch {
            if (col as usize) < stored_cols {
                self.combining_words.push(line_entry_idx);
                self.combining_words.push(col);
                self.combining_words.push(cp);
                has_combining = true;
            }
        }

        let mut flags = 0u8;
        if wraps_next {
            flags |= LINE_FLAG_WRAPS_NEXT;
        }
        if has_combining {
            flags |= LINE_FLAG_HAS_COMBINING;
        }
        let meta_word =
            (stored_cols as u32) | ((clamped_cols as u32) << 12) | ((flags as u32) << 24);
        self.line_headers.push(row_index);
        self.line_headers.push(meta_word);
        self.cell_words
            .extend_from_slice(&self.row_scratch[..stored_cols * CELL_WORDS]);
    }

    /// Appends an SGR-encoded `ScrollbackJournal` record (`encode_line` output)
    /// at `row_index` without spinning up a full VT emulator.
    pub fn push_sgr_journal_record(
        &mut self,
        row_index: u32,
        record_bytes: &[u8],
        fallback_cols: usize,
    ) {
        let wraps_next = !record_bytes.is_empty() && !record_bytes.ends_with(b"\r\n");
        let body = if !record_bytes.is_empty() && record_bytes.ends_with(b"\r\n") {
            &record_bytes[..record_bytes.len() - 2]
        } else if let Some(stripped) = record_bytes.strip_suffix(b"\n") {
            stripped
        } else {
            record_bytes
        };

        let line_entry_idx = self.row_count();
        self.row_scratch.clear();
        self.combining_scratch.clear();

        let mut fg = COLOR_NORMAL;
        let mut bg = COLOR_NORMAL;
        let mut attr_flags = 0u32;
        let mut col = 0usize;
        let mut last_cell_col: Option<usize> = None;
        let mut after_zwj = false;
        let mut prev_was_unpaired_ri = false;

        let mut i = 0usize;
        while i < body.len() {
            if body[i] == 0x1b && i + 1 < body.len() && body[i + 1] == b'[' {
                let mut j = i + 2;
                while j < body.len() && (0x20..=0x3f).contains(&body[j]) {
                    j += 1;
                }
                if j < body.len() {
                    if body[j] == b'm' {
                        apply_sgr_params(&body[i + 2..j], &mut fg, &mut bg, &mut attr_flags);
                    }
                    after_zwj = false;
                    prev_was_unpaired_ri = false;
                    i = j + 1;
                    continue;
                }
                break;
            }

            let ch = if body[i] < 0x80 {
                let c = body[i] as char;
                i += 1;
                c
            } else {
                let window = &body[i..(i + 4).min(body.len())];
                match std::str::from_utf8(window) {
                    Ok(s) => {
                        let c = s.chars().next().unwrap_or('\u{FFFD}');
                        i += c.len_utf8();
                        c
                    }
                    Err(err) => {
                        let valid_len = err.valid_up_to();
                        if valid_len > 0 {
                            let c = std::str::from_utf8(&window[..valid_len])
                                .ok()
                                .and_then(|s| s.chars().next())
                                .unwrap_or('\u{FFFD}');
                            i += c.len_utf8();
                            c
                        } else {
                            i += err.error_len().unwrap_or(1).max(1);
                            '\u{FFFD}'
                        }
                    }
                }
            };

            if ch.is_control() {
                after_zwj = false;
                prev_was_unpaired_ri = false;
                continue;
            }

            let raw_width = UnicodeWidthChar::width(ch).unwrap_or(0);
            let is_fitzpatrick = ('\u{1F3FB}'..='\u{1F3FF}').contains(&ch);
            let is_ri = ('\u{1F1E6}'..='\u{1F1FF}').contains(&ch);
            let was_after_zwj = after_zwj;
            let is_second_ri = is_ri && prev_was_unpaired_ri;

            let attach_to_prev = if let Some(prev_col) = last_cell_col {
                let prev_cp = self.row_scratch[prev_col * CELL_WORDS + 3] & CONTENT_CODEPOINT_MASK;
                raw_width == 0
                    || was_after_zwj
                    || is_second_ri
                    || (is_fitzpatrick && prev_cp >= 0x80)
            } else {
                raw_width == 0
            };

            if attach_to_prev {
                after_zwj = ch == '\u{200D}';
                prev_was_unpaired_ri = false;
                if let Some(prev_col) = last_cell_col {
                    self.combining_scratch.push((prev_col as u32, ch as u32));
                    let widens_cluster = ch == '\u{FE0F}'
                        || (was_after_zwj && raw_width >= 2)
                        || is_fitzpatrick
                        || is_second_ri;
                    if widens_cluster && prev_col + 1 == col && prev_col + 1 < MAX_ENCODED_COLS {
                        let prev_word_idx = prev_col * CELL_WORDS;
                        let prev_content = self.row_scratch[prev_word_idx + 3];
                        let prev_width = (prev_content >> CONTENT_WIDTH_SHIFT) & 0x3;
                        if prev_width == 1 {
                            let needed = (prev_col + 2) * CELL_WORDS;
                            if self.row_scratch.len() < needed {
                                self.row_scratch.resize(needed, 0);
                            }
                            let base_fg = self.row_scratch[prev_word_idx];
                            let base_bg = self.row_scratch[prev_word_idx + 1];
                            let base_attr = self.row_scratch[prev_word_idx + 2];
                            let base_cp = prev_content & CONTENT_CODEPOINT_MASK;
                            self.row_scratch[prev_word_idx + 3] =
                                base_cp | (2u32 << CONTENT_WIDTH_SHIFT);
                            let trail_idx = (prev_col + 1) * CELL_WORDS;
                            self.row_scratch[trail_idx] = base_fg;
                            self.row_scratch[trail_idx + 1] = base_bg;
                            self.row_scratch[trail_idx + 2] = base_attr;
                            self.row_scratch[trail_idx + 3] = 0;
                            col = prev_col + 2;
                        }
                    }
                }
                continue;
            }

            after_zwj = false;
            prev_was_unpaired_ri = is_ri;

            if col >= MAX_ENCODED_COLS {
                last_cell_col = None;
                prev_was_unpaired_ri = false;
                continue;
            }
            let width = if raw_width >= 2 && col + 1 < MAX_ENCODED_COLS {
                2
            } else {
                1
            };
            let needed_cols = (col + width).min(MAX_ENCODED_COLS);
            if self.row_scratch.len() < needed_cols * CELL_WORDS {
                self.row_scratch.resize(needed_cols * CELL_WORDS, 0);
            }

            let cp = (ch as u32) & CONTENT_CODEPOINT_MASK;
            let content = cp | ((width as u32) << CONTENT_WIDTH_SHIFT);
            let word_idx = col * CELL_WORDS;
            self.row_scratch[word_idx] = fg;
            self.row_scratch[word_idx + 1] = bg;
            self.row_scratch[word_idx + 2] = attr_flags;
            self.row_scratch[word_idx + 3] = content;
            last_cell_col = Some(col);

            if width == 2 {
                let trail_idx = (col + 1) * CELL_WORDS;
                self.row_scratch[trail_idx] = fg;
                self.row_scratch[trail_idx + 1] = bg;
                self.row_scratch[trail_idx + 2] = attr_flags;
                self.row_scratch[trail_idx + 3] = 0;
            }
            col = needed_cols;
        }

        let stored_cols = col.min(MAX_ENCODED_COLS);
        let logical_cols = fallback_cols.max(stored_cols).clamp(1, MAX_ENCODED_COLS);
        let mut has_combining = false;
        for &(c_col, cp) in &self.combining_scratch {
            if (c_col as usize) < stored_cols {
                self.combining_words.push(line_entry_idx);
                self.combining_words.push(c_col);
                self.combining_words.push(cp);
                has_combining = true;
            }
        }

        let mut flags = 0u8;
        if wraps_next {
            flags |= LINE_FLAG_WRAPS_NEXT;
        }
        if has_combining {
            flags |= LINE_FLAG_HAS_COMBINING;
        }
        let meta_word =
            (stored_cols as u32) | ((logical_cols as u32) << 12) | ((flags as u32) << 24);
        self.line_headers.push(row_index);
        self.line_headers.push(meta_word);
        self.cell_words
            .extend_from_slice(&self.row_scratch[..stored_cols * CELL_WORDS]);
    }

    /// Serializes the batch into `TCG1` little-endian bytes and compresses with
    /// fast zlib when compression reduces payload size.
    pub fn finish_encoded(&self) -> EncodedCellBatch {
        let row_count = self.row_count();
        if row_count == 0 {
            return EncodedCellBatch {
                compression: CELL_COMPRESSION_NONE,
                payload: Vec::new(),
                row_count: 0,
            };
        }

        let combining_count = (self.combining_words.len() / 3) as u32;
        let total_words =
            3 + self.line_headers.len() + self.cell_words.len() + self.combining_words.len();
        let mut raw = Vec::with_capacity(total_words * 4);
        push_u32_le(&mut raw, TCG1_MAGIC);
        push_u32_le(&mut raw, row_count);
        push_u32_le(&mut raw, combining_count);
        for &w in &self.line_headers {
            push_u32_le(&mut raw, w);
        }
        for &w in &self.cell_words {
            push_u32_le(&mut raw, w);
        }
        for &w in &self.combining_words {
            push_u32_le(&mut raw, w);
        }

        if raw.len() >= 128 {
            let mut encoder =
                ZlibEncoder::new(Vec::with_capacity(raw.len() / 2), Compression::fast());
            if encoder.write_all(&raw).is_ok()
                && let Ok(compressed) = encoder.finish()
                && compressed.len() < raw.len()
            {
                return EncodedCellBatch {
                    compression: CELL_COMPRESSION_ZLIB,
                    payload: compressed,
                    row_count,
                };
            }
        }

        EncodedCellBatch {
            compression: CELL_COMPRESSION_NONE,
            payload: raw,
            row_count,
        }
    }
}

/// Decoded representation of a single row in a `TCG1` batch (used in tests and
/// server-side verification).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedCellRow {
    pub row_index: u32,
    pub stored_cols: usize,
    pub logical_cols: usize,
    pub flags: u8,
    pub cell_words: Vec<u32>,
    pub combining: Vec<(u32, u32)>,
}

/// Decodes an `EncodedCellBatch` back into structured rows.
pub fn decode_tcg1_batch(compression: u8, payload: &[u8]) -> Result<Vec<DecodedCellRow>, String> {
    if payload.is_empty() {
        return Ok(Vec::new());
    }
    let raw_cow: Cow<'_, [u8]> = match compression {
        CELL_COMPRESSION_NONE => {
            if payload.len() > MAX_DECOMPRESSED_TCG1_BYTES {
                return Err(format!(
                    "TCG1 payload exceeds maximum size: {}",
                    payload.len()
                ));
            }
            Cow::Borrowed(payload)
        }
        CELL_COMPRESSION_ZLIB => {
            let decoder = ZlibDecoder::new(payload);
            let mut limited = decoder.take((MAX_DECOMPRESSED_TCG1_BYTES as u64) + 1);
            let mut out = Vec::new();
            limited
                .read_to_end(&mut out)
                .map_err(|e| format!("zlib decode failed: {e}"))?;
            if out.len() > MAX_DECOMPRESSED_TCG1_BYTES {
                return Err(format!(
                    "decompressed TCG1 payload exceeds maximum size ({MAX_DECOMPRESSED_TCG1_BYTES} bytes)"
                ));
            }
            Cow::Owned(out)
        }
        other => return Err(format!("unsupported cell compression code: {other}")),
    };

    if raw_cow.len() < 12 || !raw_cow.len().is_multiple_of(4) {
        return Err(format!("invalid TCG1 byte length: {}", raw_cow.len()));
    }

    let word_at = |idx: usize| -> u32 {
        let base = idx * 4;
        u32::from_le_bytes([
            raw_cow[base],
            raw_cow[base + 1],
            raw_cow[base + 2],
            raw_cow[base + 3],
        ])
    };
    let total_words = raw_cow.len() / 4;
    if word_at(0) != TCG1_MAGIC {
        return Err("invalid TCG1 magic".to_owned());
    }
    let line_count = word_at(1) as usize;
    let combining_count = word_at(2) as usize;
    if line_count > 0x10000 {
        return Err(format!("TCG1 line_count exceeds 65536: {line_count}"));
    }
    let headers_end = 3usize
        .checked_add(line_count.checked_mul(2).ok_or("line_count overflow")?)
        .ok_or("headers_end overflow")?;
    if headers_end > total_words {
        return Err("TCG1 truncated in line headers".to_owned());
    }

    let sanitize_cp = |cp: u32| -> u32 {
        if cp == 0 {
            0
        } else if char::from_u32(cp).is_none() {
            0xFFFD
        } else {
            cp
        }
    };

    let mut rows = Vec::with_capacity(line_count);
    let mut cell_cursor = headers_end;
    for i in 0..line_count {
        let row_index = word_at(3 + i * 2);
        let meta = word_at(3 + i * 2 + 1);
        let stored_cols = (meta & 0x0FFF) as usize;
        let logical_cols = ((meta >> 12) & 0x0FFF) as usize;
        let flags = ((meta >> 24) & 0xFF) as u8;
        if row_index >= 0x10000 {
            return Err(format!("TCG1 row_index out of bounds: {row_index}"));
        }
        if stored_cols > logical_cols {
            return Err(format!(
                "TCG1 stored_cols ({stored_cols}) exceeds logical_cols ({logical_cols})"
            ));
        }
        let words_len = stored_cols * CELL_WORDS;
        if cell_cursor + words_len > total_words {
            return Err("TCG1 truncated in cell words".to_owned());
        }
        let mut cell_words = Vec::with_capacity(words_len);
        for w_idx in cell_cursor..cell_cursor + words_len {
            cell_words.push(word_at(w_idx));
        }
        for col in 0..stored_cols {
            let content_idx = col * CELL_WORDS + 3;
            let content = cell_words[content_idx];
            let cp = content & CONTENT_CODEPOINT_MASK;
            if cp != 0 {
                let safe_cp = sanitize_cp(cp);
                if safe_cp != cp {
                    cell_words[content_idx] = (content & !CONTENT_CODEPOINT_MASK) | safe_cp;
                }
            }
        }
        cell_cursor += words_len;
        rows.push(DecodedCellRow {
            row_index,
            stored_cols,
            logical_cols,
            flags,
            cell_words,
            combining: Vec::new(),
        });
    }

    let comb_words = combining_count
        .checked_mul(3)
        .ok_or("combining_count overflow")?;
    if cell_cursor + comb_words != total_words {
        return Err("TCG1 word count mismatch".to_owned());
    }
    for c_idx in 0..combining_count {
        let base = cell_cursor + c_idx * 3;
        let line_idx = word_at(base) as usize;
        let col = word_at(base + 1);
        let cp = word_at(base + 2);
        let Some(row) = rows.get_mut(line_idx) else {
            return Err(format!(
                "TCG1 combining entry references out-of-bounds line_idx {line_idx} (line_count={line_count})"
            ));
        };
        if (col as usize) >= row.stored_cols {
            return Err(format!(
                "TCG1 combining entry references out-of-bounds col {col} (stored_cols={})",
                row.stored_cols
            ));
        }
        let safe_cp = sanitize_cp(if cp == 0 { 0xFFFD } else { cp });
        if (row.flags & LINE_FLAG_HAS_COMBINING) != 0 {
            row.combining.push((col, safe_cp));
        }
    }

    Ok(rows)
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ScreenBaseline {
    pub initialized: bool,
    pub synced_seqno: SequenceNo,
    pub first_visible_stable: StableRowIndex,
    pub physical_rows: usize,
    pub physical_cols: usize,
}

/// Per-client synchronization baseline for computing minimal binary diffs
/// against a shared `Terminal` + `TerminalModeTracker`.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ClientSyncBaseline {
    pub primary: ScreenBaseline,
    pub alt: ScreenBaseline,
    pub last_alt_screen: Option<bool>,
    pub last_erase_scrollback_gen: u64,
    pub last_erase_display_gen: u64,
    pub last_bell_gen: u64,
    pub last_title_gen: u64,
    pub last_mode_flags: u32,
    pub last_mouse_mode: u32,
    pub last_mouse_report_mode: u32,
    pub last_kitty_flags: u32,
    pub last_cursor_x: u32,
    pub last_cursor_y: u32,
    pub last_cursor_style: u32,
    pub last_total_scrollback_rows: u64,
    pub last_trimmed_top_rows: u64,
    pub next_frame_seq: u64,
}

/// Server-computed viewport + boundary-scrollback diff for a single client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalSyncPatch {
    pub frame_seq: u64,
    pub rows: u16,
    pub cols: u16,
    pub total_scrollback_rows: u64,
    pub trimmed_top_rows: u64,
    pub erase_scrollback_gen: u64,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub cursor_style: u8,
    pub mode_flags: u32,
    pub mouse_mode: u8,
    pub mouse_report_mode: u8,
    pub kitty_keyboard_flags: u32,
    pub title: Option<String>,
    pub viewport_batch: EncodedCellBatch,
    pub pushed_scrollback_start_row: u64,
    pub pushed_scrollback_batch: EncodedCellBatch,
}

/// Scrollback coordinates passed from `OutputState` when building a client diff.
#[derive(Debug, Clone, Copy)]
pub struct VirtualScrollbackMetrics {
    /// Total scrollable rows above the primary viewport (`0` on alt screen).
    pub total_scrollback_rows: u64,
    /// Cumulative count of oldest rows pruned by retention since session open.
    pub trimmed_top_rows: u64,
}

impl ClientSyncBaseline {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn last_sent_frame_seq(&self) -> u64 {
        self.next_frame_seq
    }

    /// Resets the baseline so the next `diff_terminal` call emits a complete
    /// full-viewport snapshot.
    pub fn reset(&mut self) {
        let next_seq = self.next_frame_seq;
        *self = Self::default();
        self.next_frame_seq = next_seq;
    }

    /// Computes a full or incremental `TerminalSyncPatch` against `terminal`
    /// and advances this client's baseline. Returns `None` when `force_full` is
    /// `false` and neither viewport cells, scrollback metrics, cursor, modes,
    /// nor transient generations changed since the previous frame.
    pub fn diff_terminal(
        &mut self,
        terminal: &Terminal,
        mode_tracker: &mut TerminalModeTracker,
        scrollback_metrics: VirtualScrollbackMetrics,
        force_full: bool,
    ) -> Option<TerminalSyncPatch> {
        let current_seqno = terminal.current_seqno();
        let is_alt = terminal.is_alt_screen_active();
        let cursor = terminal.cursor_pos();
        let bracketed_paste = terminal.bracketed_paste_enabled();
        let reverse_video = terminal.get_reverse_video();
        let kitty_flags = mode_tracker.kitty_keyboard_flags(is_alt);
        let (current_title, current_title_gen) = mode_tracker.observe_terminal_title(terminal);
        let current_title_owned = current_title.to_owned();

        let screen = terminal.screen();
        let physical_rows = screen.physical_rows.max(1);
        let physical_cols = screen.physical_cols.max(1);
        let total_screen_rows = screen.scrollback_rows();
        let viewport_phys_start = total_screen_rows.saturating_sub(physical_rows);
        let first_visible_stable = screen.visible_row_to_stable_row(0);

        let erase_scrollback_gen = mode_tracker.erase_scrollback_gen();
        let erase_display_gen = mode_tracker.erase_display_gen();
        let bell_gen = mode_tracker.bell_gen();

        let saw_erase_scrollback = self.last_alt_screen.is_some()
            && erase_scrollback_gen != self.last_erase_scrollback_gen;
        let saw_erase_display =
            self.last_alt_screen.is_some() && erase_display_gen != self.last_erase_display_gen;
        let bell_rang = self.last_alt_screen.is_some() && bell_gen != self.last_bell_gen;
        let title_changed = force_full
            || self.last_alt_screen.is_none()
            || current_title_gen != self.last_title_gen;

        let alt_switched = self.last_alt_screen != Some(is_alt);
        let screen_baseline = if is_alt {
            &mut self.alt
        } else {
            &mut self.primary
        };

        let size_changed = !screen_baseline.initialized
            || screen_baseline.physical_rows != physical_rows
            || screen_baseline.physical_cols != physical_cols;
        let full_viewport = force_full
            || !screen_baseline.initialized
            || alt_switched
            || size_changed
            || saw_erase_scrollback
            || saw_erase_display;

        let effective_scrollback_rows = if is_alt {
            0
        } else {
            scrollback_metrics.total_scrollback_rows
        };

        // Pack newly scrolled boundary rows (up to MAX_INLINE_PUSHED_SCROLLBACK_ROWS)
        // plus dirty (or full) viewport rows `0..physical_rows` in a single pass.
        let mut pushed_builder =
            Tcg1BatchBuilder::with_row_capacity(MAX_INLINE_PUSHED_SCROLLBACK_ROWS, physical_cols);
        let mut pushed_start_row = effective_scrollback_rows;
        let mut push_phys_range: Option<(usize, usize)> = None;
        let can_push_boundary_scrollback = !is_alt
            && !force_full
            && screen_baseline.initialized
            && !alt_switched
            && screen_baseline.physical_cols == physical_cols
            && !saw_erase_scrollback;
        if can_push_boundary_scrollback
            && first_visible_stable > screen_baseline.first_visible_stable
        {
            let raw_delta = (first_visible_stable - screen_baseline.first_visible_stable) as usize;
            let push_count = raw_delta
                .min(MAX_INLINE_PUSHED_SCROLLBACK_ROWS)
                .min(viewport_phys_start)
                .min(effective_scrollback_rows as usize);
            if push_count > 0 {
                let push_phys_start = viewport_phys_start - push_count;
                pushed_start_row = effective_scrollback_rows - (push_count as u64);
                push_phys_range = Some((push_phys_start, viewport_phys_start));
            }
        }

        let mut viewport_builder =
            Tcg1BatchBuilder::with_row_capacity(physical_rows, physical_cols);
        let scrolled_since_sync = first_visible_stable != screen_baseline.first_visible_stable;
        if full_viewport
            || scrolled_since_sync
            || current_seqno > screen_baseline.synced_seqno
            || push_phys_range.is_some()
        {
            let baseline_seqno = screen_baseline.synced_seqno;
            let min_phys = push_phys_range.map_or(viewport_phys_start, |(s, _)| s);
            screen.for_each_phys_line(|phys_idx, line| {
                if phys_idx < min_phys || phys_idx >= total_screen_rows {
                    return;
                }
                if let Some((push_start, push_end)) = push_phys_range
                    && phys_idx >= push_start
                    && phys_idx < push_end
                {
                    let rel = (phys_idx - push_start) as u32;
                    pushed_builder.push_wezterm_line(rel, line, physical_cols);
                    return;
                }
                if phys_idx < viewport_phys_start {
                    return;
                }
                let viewport_row = phys_idx - viewport_phys_start;
                if viewport_row >= physical_rows {
                    return;
                }
                // When scrolling occurred, row indices inside the viewport shifted
                // relative to the client's previous viewport, so send every viewport
                // row (only `physical_rows` lines, e.g. 24-50 rows). When stationary,
                // send only rows whose `seqno` advanced past `baseline_seqno`.
                if full_viewport || scrolled_since_sync || line.changed_since(baseline_seqno) {
                    viewport_builder.push_wezterm_line(viewport_row as u32, line, physical_cols);
                }
            });
        }

        let cursor_style = match cursor.shape {
            CursorShape::Default => 0u8,
            CursorShape::BlinkingBlock => 1,
            CursorShape::SteadyBlock => 2,
            CursorShape::BlinkingUnderline => 3,
            CursorShape::SteadyUnderline => 4,
            CursorShape::BlinkingBar => 5,
            CursorShape::SteadyBar => 6,
        };
        let clamped_cursor_x = cursor.x.min(physical_cols.saturating_sub(1)) as u32;
        let clamped_cursor_y =
            (cursor.y.max(0) as usize).min(physical_rows.saturating_sub(1)) as u32;

        let mut persistent_modes = 0u32;
        if is_alt {
            persistent_modes |= MODE_ALT_SCREEN;
        }
        if cursor.visibility == CursorVisibility::Visible {
            persistent_modes |= MODE_CURSOR_VISIBLE;
        }
        if bracketed_paste {
            persistent_modes |= MODE_BRACKETED_PASTE;
        }
        if mode_tracker.app_cursor_keys {
            persistent_modes |= MODE_APP_CURSOR_KEYS;
        }
        if mode_tracker.app_keypad {
            persistent_modes |= MODE_APP_KEYPAD;
        }
        if mode_tracker.origin_mode {
            persistent_modes |= MODE_ORIGIN;
        }
        if mode_tracker.auto_wrap {
            persistent_modes |= MODE_AUTO_WRAP;
        }
        if mode_tracker.report_focus {
            persistent_modes |= MODE_REPORT_FOCUS;
        }
        if reverse_video {
            persistent_modes |= MODE_REVERSE_VIDEO;
        }

        let mouse_mode = mode_tracker.mouse_mode();
        let mouse_report_mode = mode_tracker.mouse_report_mode();

        let metadata_changed = persistent_modes != self.last_mode_flags
            || mouse_mode != self.last_mouse_mode
            || mouse_report_mode != self.last_mouse_report_mode
            || kitty_flags != self.last_kitty_flags
            || clamped_cursor_x != self.last_cursor_x
            || clamped_cursor_y != self.last_cursor_y
            || u32::from(cursor_style) != self.last_cursor_style
            || effective_scrollback_rows != self.last_total_scrollback_rows
            || scrollback_metrics.trimmed_top_rows != self.last_trimmed_top_rows
            || saw_erase_scrollback
            || saw_erase_display
            || bell_rang
            || title_changed;

        if !full_viewport
            && viewport_builder.is_empty()
            && pushed_builder.is_empty()
            && !metadata_changed
        {
            screen_baseline.synced_seqno = current_seqno;
            return None;
        }

        let mut mode_flags = persistent_modes;
        if saw_erase_scrollback {
            mode_flags |= MODE_SAW_ERASE_SCROLLBACK;
        }
        if saw_erase_display {
            mode_flags |= MODE_SAW_ERASE_DISPLAY;
        }
        if bell_rang {
            mode_flags |= MODE_BELL_RANG;
        }
        if title_changed {
            mode_flags |= MODE_TITLE_CHANGED;
        }
        if full_viewport || scrolled_since_sync {
            mode_flags |= MODE_FULL_VIEWPORT;
        }

        screen_baseline.initialized = true;
        screen_baseline.synced_seqno = current_seqno;
        screen_baseline.first_visible_stable = first_visible_stable;
        screen_baseline.physical_rows = physical_rows;
        screen_baseline.physical_cols = physical_cols;

        self.last_alt_screen = Some(is_alt);
        self.last_erase_scrollback_gen = erase_scrollback_gen;
        self.last_erase_display_gen = erase_display_gen;
        self.last_bell_gen = bell_gen;
        self.last_title_gen = current_title_gen;
        self.last_mode_flags = persistent_modes;
        self.last_mouse_mode = mouse_mode;
        self.last_mouse_report_mode = mouse_report_mode;
        self.last_kitty_flags = kitty_flags;
        self.last_cursor_x = clamped_cursor_x;
        self.last_cursor_y = clamped_cursor_y;
        self.last_cursor_style = u32::from(cursor_style);
        self.last_total_scrollback_rows = effective_scrollback_rows;
        self.last_trimmed_top_rows = scrollback_metrics.trimmed_top_rows;
        self.next_frame_seq = self.next_frame_seq.wrapping_add(1);

        Some(TerminalSyncPatch {
            frame_seq: self.next_frame_seq,
            rows: physical_rows.min(u16::MAX as usize) as u16,
            cols: physical_cols.min(u16::MAX as usize) as u16,
            total_scrollback_rows: effective_scrollback_rows,
            trimmed_top_rows: scrollback_metrics.trimmed_top_rows,
            erase_scrollback_gen,
            cursor_x: clamped_cursor_x.min(u16::MAX as u32) as u16,
            cursor_y: clamped_cursor_y.min(u16::MAX as u32) as u16,
            cursor_style,
            mode_flags,
            mouse_mode: mouse_mode as u8,
            mouse_report_mode: mouse_report_mode as u8,
            kitty_keyboard_flags: kitty_flags,
            title: if title_changed {
                Some(current_title_owned)
            } else {
                None
            },
            viewport_batch: viewport_builder.finish_encoded(),
            pushed_scrollback_start_row: pushed_start_row,
            pushed_scrollback_batch: pushed_builder.finish_encoded(),
        })
    }
}

#[inline]
fn push_u32_le(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}

#[inline]
fn encode_color(attr: ColorAttribute) -> u32 {
    match attr {
        ColorAttribute::Default => COLOR_NORMAL,
        ColorAttribute::PaletteIndex(idx) => {
            if idx < 16 {
                COLOR_NAMED | u32::from(idx)
            } else {
                COLOR_PALETTE | u32::from(idx)
            }
        }
        ColorAttribute::TrueColorWithDefaultFallback(srgba)
        | ColorAttribute::TrueColorWithPaletteFallback(srgba, _) => {
            let (r, g, b, _) = srgba.to_srgb_u8();
            COLOR_RGB | (u32::from(r) << 16) | (u32::from(g) << 8) | u32::from(b)
        }
    }
}

#[inline]
fn encode_attrs(attrs: &CellAttributes) -> u32 {
    let mut flags = 0u32;
    match attrs.intensity() {
        Intensity::Bold => flags |= ATTR_BOLD,
        Intensity::Half => flags |= ATTR_FAINT,
        Intensity::Normal => {}
    }
    if attrs.italic() {
        flags |= ATTR_ITALIC;
    }
    match attrs.underline() {
        Underline::None => {}
        Underline::Single => flags |= ATTR_UNDERLINE,
        Underline::Double => flags |= ATTR_UNDERLINE | ATTR_DOUBLE_UNDERLINE,
        Underline::Curly => flags |= ATTR_UNDERLINE | ATTR_UNDERCURL,
        Underline::Dotted => flags |= ATTR_UNDERLINE | ATTR_DOTTED_UNDERLINE,
        Underline::Dashed => flags |= ATTR_UNDERLINE | ATTR_DASHED_UNDERLINE,
    }
    if attrs.blink() != Blink::None {
        flags |= ATTR_BLINK;
    }
    if attrs.reverse() {
        flags |= ATTR_INVERSE;
    }
    if attrs.invisible() {
        flags |= ATTR_INVISIBLE;
    }
    if attrs.strikethrough() {
        flags |= ATTR_STRIKETHROUGH;
    }
    if attrs.overline() {
        flags |= ATTR_OVERLINE;
    }
    flags
}

const ALL_UNDERLINE_FLAGS: u32 = ATTR_UNDERLINE
    | ATTR_DOUBLE_UNDERLINE
    | ATTR_UNDERCURL
    | ATTR_DOTTED_UNDERLINE
    | ATTR_DASHED_UNDERLINE;

fn apply_extended_color_colon(subparams: &[u8], out: &mut u32) {
    let mut iter = subparams.split(|&b| b == b':');
    let _ = iter.next(); // 38 or 48
    match iter.next().and_then(parse_u32_ascii) {
        Some(5) => {
            if let Some(raw_c) = iter.next().and_then(parse_u32_ascii) {
                let c = raw_c & 0xFF;
                *out = if c < 16 {
                    COLOR_NAMED | c
                } else {
                    COLOR_PALETTE | c
                };
            }
        }
        Some(2) => {
            // Both `38:2:cs:r:g:b` (ITU T.416) and `38:2:r:g:b` appear in the wild.
            let rem: Vec<Option<u32>> = iter.take(5).map(parse_u32_ascii).collect();
            let rgb = if rem.len() >= 4 {
                (rem[1], rem[2], rem[3])
            } else if rem.len() == 3 {
                (rem[0], rem[1], rem[2])
            } else {
                (None, None, None)
            };
            if let (Some(r), Some(g), Some(b)) = rgb {
                *out = COLOR_RGB | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);
            }
        }
        _ => {}
    }
}

fn apply_sgr_params(params: &[u8], fg: &mut u32, bg: &mut u32, attrs: &mut u32) {
    if params.is_empty() {
        *fg = COLOR_NORMAL;
        *bg = COLOR_NORMAL;
        *attrs = 0;
        return;
    }
    let mut parts = params.split(|&b| b == b';').peekable();
    while let Some(part) = parts.next() {
        if part.contains(&b':') {
            let mut sub = part.split(|&b| b == b':');
            let code = sub.next().and_then(parse_u32_ascii).unwrap_or(0);
            match code {
                4 => {
                    *attrs &= !ALL_UNDERLINE_FLAGS;
                    match sub.next().and_then(parse_u32_ascii).unwrap_or(1) {
                        0 => {}
                        1 => *attrs |= ATTR_UNDERLINE,
                        2 => *attrs |= ATTR_UNDERLINE | ATTR_DOUBLE_UNDERLINE,
                        3 => *attrs |= ATTR_UNDERLINE | ATTR_UNDERCURL,
                        4 => *attrs |= ATTR_UNDERLINE | ATTR_DOTTED_UNDERLINE,
                        5 => *attrs |= ATTR_UNDERLINE | ATTR_DASHED_UNDERLINE,
                        _ => *attrs |= ATTR_UNDERLINE,
                    }
                }
                38 => apply_extended_color_colon(part, fg),
                48 => apply_extended_color_colon(part, bg),
                58 => {}
                0 => {
                    *fg = COLOR_NORMAL;
                    *bg = COLOR_NORMAL;
                    *attrs = 0;
                }
                _ => {}
            }
            continue;
        }

        let code = parse_u32_ascii(part).unwrap_or(0);
        match code {
            0 => {
                *fg = COLOR_NORMAL;
                *bg = COLOR_NORMAL;
                *attrs = 0;
            }
            1 => *attrs = (*attrs & !ATTR_FAINT) | ATTR_BOLD,
            2 => *attrs = (*attrs & !ATTR_BOLD) | ATTR_FAINT,
            3 => *attrs |= ATTR_ITALIC,
            4 => {
                *attrs = (*attrs & !ALL_UNDERLINE_FLAGS) | ATTR_UNDERLINE;
            }
            5 | 6 => *attrs |= ATTR_BLINK,
            7 => *attrs |= ATTR_INVERSE,
            8 => *attrs |= ATTR_INVISIBLE,
            9 => *attrs |= ATTR_STRIKETHROUGH,
            21 => {
                *attrs = (*attrs & !ALL_UNDERLINE_FLAGS) | ATTR_UNDERLINE | ATTR_DOUBLE_UNDERLINE;
            }
            22 => *attrs &= !(ATTR_BOLD | ATTR_FAINT),
            23 => *attrs &= !ATTR_ITALIC,
            24 => *attrs &= !ALL_UNDERLINE_FLAGS,
            25 => *attrs &= !ATTR_BLINK,
            27 => *attrs &= !ATTR_INVERSE,
            28 => *attrs &= !ATTR_INVISIBLE,
            29 => *attrs &= !ATTR_STRIKETHROUGH,
            30..=37 => *fg = COLOR_NAMED | (code - 30),
            39 => *fg = COLOR_NORMAL,
            40..=47 => *bg = COLOR_NAMED | (code - 40),
            49 => *bg = COLOR_NORMAL,
            90..=97 => *fg = COLOR_NAMED | (code - 90 + 8),
            100..=107 => *bg = COLOR_NAMED | (code - 100 + 8),
            38 | 48 | 58 => {
                let Some(mode_part) = parts.next() else {
                    break;
                };
                match parse_u32_ascii(mode_part) {
                    Some(5) => {
                        if let Some(c_part) = parts.next()
                            && let Some(raw_c) = parse_u32_ascii(c_part)
                        {
                            let c = raw_c & 0xFF;
                            let encoded = if c < 16 {
                                COLOR_NAMED | c
                            } else {
                                COLOR_PALETTE | c
                            };
                            if code == 38 {
                                *fg = encoded;
                            } else if code == 48 {
                                *bg = encoded;
                            }
                        }
                    }
                    Some(2) => {
                        let r = parts.next().and_then(parse_u32_ascii);
                        let g = parts.next().and_then(parse_u32_ascii);
                        let b = parts.next().and_then(parse_u32_ascii);
                        if let (Some(r), Some(g), Some(b)) = (r, g, b) {
                            let encoded =
                                COLOR_RGB | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);
                            if code == 38 {
                                *fg = encoded;
                            } else if code == 48 {
                                *bg = encoded;
                            }
                        }
                    }
                    _ => {}
                }
            }
            53 => *attrs |= ATTR_OVERLINE,
            55 => *attrs &= !ATTR_OVERLINE,
            _ => {}
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum WeztermCsiToken {
    Int(i64),
    Punct(u8),
}

/// Mirrors `vtparse` (`MAX_PARAMS = 32`, with slot 0 occupied by `?`) followed
/// by `wezterm_escape_parser::csi::CSIParser`'s DECSET/DECRST parameter walk.
fn for_each_wezterm_dec_private_mode(body: &[u8], mut f: impl FnMut(u16)) {
    let mut tokens = [WeztermCsiToken::Punct(0); 31];
    let mut token_len = 0usize;
    let mut cur_int: Option<i64> = None;

    for &b in body {
        if b.is_ascii_digit() {
            let next = cur_int
                .unwrap_or(0)
                .saturating_mul(10)
                .saturating_add(i64::from(b - b'0'));
            cur_int = Some(next);
        } else if b == b';' || b == b':' {
            if let Some(val) = cur_int.take()
                && token_len < tokens.len()
            {
                tokens[token_len] = WeztermCsiToken::Int(val);
                token_len += 1;
            }
            if token_len < tokens.len() {
                tokens[token_len] = WeztermCsiToken::Punct(b);
                token_len += 1;
            }
        } else {
            return;
        }
    }
    if let Some(val) = cur_int.take()
        && token_len < tokens.len()
    {
        tokens[token_len] = WeztermCsiToken::Int(val);
        token_len += 1;
    }

    let mut slice = &tokens[..token_len];
    while !slice.is_empty() {
        let WeztermCsiToken::Int(v) = slice[0] else {
            break;
        };
        let Ok(code) = u16::try_from(v) else {
            break;
        };
        f(code);
        if slice.get(1) == Some(&WeztermCsiToken::Punct(b';')) {
            slice = &slice[2..];
        } else {
            slice = &slice[1..];
        }
    }
}

fn parse_u16_strict_ascii(bytes: &[u8]) -> Option<u16> {
    let val = parse_u32_strict_ascii(bytes)?;
    u16::try_from(val).ok()
}

fn parse_u32_strict_ascii(bytes: &[u8]) -> Option<u32> {
    if bytes.is_empty() {
        return None;
    }
    let mut acc = 0u32;
    for &b in bytes {
        if !b.is_ascii_digit() {
            return None;
        }
        acc = acc.checked_mul(10)?.checked_add(u32::from(b - b'0'))?;
    }
    Some(acc)
}

fn parse_u32_ascii(bytes: &[u8]) -> Option<u32> {
    if bytes.is_empty() {
        return None;
    }
    let mut acc = 0u32;
    for &b in bytes {
        if !b.is_ascii_digit() {
            return None;
        }
        acc = acc.saturating_mul(10).saturating_add(u32::from(b - b'0'));
    }
    Some(acc)
}

fn write_usize_ascii(mut value: usize, out: &mut [u8; 16]) -> usize {
    if value == 0 {
        out[0] = b'0';
        return 1;
    }
    let mut idx = 16usize;
    while value > 0 && idx > 0 {
        idx -= 1;
        out[idx] = b'0' + (value % 10) as u8;
        value /= 10;
    }
    let len = 16 - idx;
    out.copy_within(idx..16, 0);
    len
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use tattoy_wezterm_term::color::ColorPalette;
    use tattoy_wezterm_term::{TerminalConfiguration, TerminalSize};

    use super::*;

    #[derive(Debug)]
    struct TestConfig;

    impl TerminalConfiguration for TestConfig {
        fn color_palette(&self) -> ColorPalette {
            ColorPalette::default()
        }

        fn enable_kitty_keyboard(&self) -> bool {
            true
        }
    }

    fn make_terminal(cols: usize, rows: usize) -> Terminal {
        Terminal::new(
            TerminalSize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
                dpi: 96,
            },
            Arc::new(TestConfig),
            "Triage",
            "0.3.0",
            Box::new(std::io::sink()),
        )
    }

    fn feed(term: &mut Terminal, tracker: &mut TerminalModeTracker, bytes: &[u8]) {
        let cols = term.screen().physical_cols;
        let sanitized = tracker.observe_and_sanitize(bytes, cols);
        term.advance_bytes(sanitized);
    }

    #[test]
    fn tcg1_round_trip_with_sgr_wide_and_combining() {
        let mut term = make_terminal(20, 5);
        let mut tracker = TerminalModeTracker::new();
        feed(
            &mut term,
            &mut tracker,
            "\x1b[1;31;48;2;10;20;30mHi中文e\u{0301}\x1b[0m".as_bytes(),
        );

        let mut client = ClientSyncBaseline::new();
        let patch = client
            .diff_terminal(
                &term,
                &mut tracker,
                VirtualScrollbackMetrics {
                    total_scrollback_rows: 0,
                    trimmed_top_rows: 0,
                },
                true,
            )
            .expect("initial patch");

        assert_eq!(patch.rows, 5);
        assert_eq!(patch.cols, 20);
        assert_ne!(patch.mode_flags & MODE_FULL_VIEWPORT, 0);
        let rows = decode_tcg1_batch(
            patch.viewport_batch.compression,
            &patch.viewport_batch.payload,
        )
        .expect("decode viewport");
        assert_eq!(rows.len(), 5);

        let r0 = &rows[0];
        assert_eq!(r0.row_index, 0);
        assert_eq!(r0.logical_cols, 20);
        // 'H' (1) + 'i' (1) + '中' (2) + '文' (2) + 'e\u{0301}' (1) = 7 stored cols
        assert_eq!(r0.stored_cols, 7);
        assert_ne!(r0.flags & LINE_FLAG_HAS_COMBINING, 0);
        assert_eq!(r0.combining, vec![(6, 0x0301)]);

        // Cell 0 ('H')
        assert_eq!(r0.cell_words[0], COLOR_NAMED | 1);
        assert_eq!(r0.cell_words[1], COLOR_RGB | (10 << 16) | (20 << 8) | 30);
        assert_eq!(r0.cell_words[2], ATTR_BOLD);
        assert_eq!(
            r0.cell_words[3],
            (u32::from(b'H')) | (1 << CONTENT_WIDTH_SHIFT)
        );

        // Cell 2 ('中', width 2) and trailing continuation cell 3 (`content == 0`)
        assert_eq!(
            r0.cell_words[2 * CELL_WORDS + 3],
            ('中' as u32) | (2 << CONTENT_WIDTH_SHIFT)
        );
        assert_eq!(r0.cell_words[3 * CELL_WORDS + 3], 0);

        // Blank rows 1..5 have stored_cols == 0!
        for blank_row in &rows[1..] {
            assert_eq!(blank_row.stored_cols, 0);
            assert!(blank_row.cell_words.is_empty());
        }
    }

    #[test]
    fn stationary_diff_sends_only_changed_row_and_supports_multiple_clients() {
        let mut term = make_terminal(40, 10);
        let mut tracker = TerminalModeTracker::new();
        feed(&mut term, &mut tracker, b"row0\r\nrow1\r\nrow2");

        let metrics = VirtualScrollbackMetrics {
            total_scrollback_rows: 0,
            trimmed_top_rows: 0,
        };
        let mut fast_client = ClientSyncBaseline::new();
        let mut slow_client = ClientSyncBaseline::new();

        let _ = fast_client.diff_terminal(&term, &mut tracker, metrics, true);
        let _ = slow_client.diff_terminal(&term, &mut tracker, metrics, true);

        // Stationary edit on row 1 (`\x1b[2;1Hupdated1`).
        feed(&mut term, &mut tracker, b"\x1b[2;1Hupdated1");
        let p_fast_1 = fast_client
            .diff_terminal(&term, &mut tracker, metrics, false)
            .expect("fast diff 1");
        assert_eq!(p_fast_1.mode_flags & MODE_FULL_VIEWPORT, 0);
        let decoded_1 = decode_tcg1_batch(
            p_fast_1.viewport_batch.compression,
            &p_fast_1.viewport_batch.payload,
        )
        .expect("decode");
        assert_eq!(decoded_1.len(), 1);
        assert_eq!(decoded_1[0].row_index, 1);

        // Stationary edit on row 1 again (`\x1b[2;1Hfinal1`) + bell: `slow_client`
        // skipped `updated1` and receives a single coalesced diff + bell flag.
        feed(&mut term, &mut tracker, b"\x1b[2;1Hfinal1  \x07");
        let p_slow = slow_client
            .diff_terminal(&term, &mut tracker, metrics, false)
            .expect("slow coalesced diff");
        assert_ne!(p_slow.mode_flags & MODE_BELL_RANG, 0);
        let slow_rows = decode_tcg1_batch(
            p_slow.viewport_batch.compression,
            &p_slow.viewport_batch.payload,
        )
        .expect("decode slow");
        assert_eq!(slow_rows.len(), 1);
        assert_eq!(slow_rows[0].row_index, 1);
        assert_eq!(
            slow_rows[0].cell_words[3],
            u32::from(b'f') | (1 << CONTENT_WIDTH_SHIFT)
        );

        // No further changes -> returns `None`.
        assert!(
            slow_client
                .diff_terminal(&term, &mut tracker, metrics, false)
                .is_none()
        );
    }

    #[test]
    fn incremental_scroll_pushes_boundary_scrollback_rows_inline() {
        let mut term = make_terminal(20, 4);
        let mut tracker = TerminalModeTracker::new();
        let mut client = ClientSyncBaseline::new();
        let _ = client.diff_terminal(
            &term,
            &mut tracker,
            VirtualScrollbackMetrics {
                total_scrollback_rows: 0,
                trimmed_top_rows: 0,
            },
            true,
        );

        feed(&mut term, &mut tracker, b"L0\r\nL1\r\nL2\r\nL3\r\nL4\r\nL5");
        // 6 lines on a 4-row screen -> 2 lines scrolled into scrollback.
        let patch = client
            .diff_terminal(
                &term,
                &mut tracker,
                VirtualScrollbackMetrics {
                    total_scrollback_rows: 2,
                    trimmed_top_rows: 0,
                },
                false,
            )
            .expect("scroll patch");
        assert_eq!(patch.pushed_scrollback_start_row, 0);
        assert_eq!(patch.pushed_scrollback_batch.row_count, 2);
        let pushed = decode_tcg1_batch(
            patch.pushed_scrollback_batch.compression,
            &patch.pushed_scrollback_batch.payload,
        )
        .expect("decode pushed");
        assert_eq!(
            pushed[0].cell_words[3],
            u32::from(b'L') | (1 << CONTENT_WIDTH_SHIFT)
        );
        assert_eq!(
            pushed[0].cell_words[CELL_WORDS + 3],
            u32::from(b'0') | (1 << CONTENT_WIDTH_SHIFT)
        );
    }

    #[test]
    fn streaming_escape_scanner_handles_split_chunks_mode_2026_and_cht_clamp() {
        let mut term = make_terminal(30, 5);
        let mut tracker = TerminalModeTracker::new();

        // Split `\x1b[?1002;1006;2026h` across three chunks.
        feed(&mut term, &mut tracker, b"\x1b[?10");
        feed(&mut term, &mut tracker, b"02;1006;");
        feed(&mut term, &mut tracker, b"2026h");
        assert_eq!(tracker.mouse_mode(), 3);
        assert_eq!(tracker.mouse_report_mode(), 2);
        assert!(tracker.is_in_synchronized_update(Instant::now(), Duration::from_millis(50)));

        feed(&mut term, &mut tracker, b"\x1b[?2026l");
        assert!(!tracker.is_in_synchronized_update(Instant::now(), Duration::from_millis(50)));

        // Oversized CHT clamps to `cols - 1` (29).
        feed(&mut term, &mut tracker, b"\r\x1b[999999I");
        assert_eq!(term.cursor_pos().x, 29);
    }

    #[test]
    fn sgr_journal_record_packs_styles_wrap_and_combining() {
        let mut builder = Tcg1BatchBuilder::with_row_capacity(2, 40);
        // Hard-newline record with bold RGB fg + inverse
        builder.push_sgr_journal_record(0, b"\x1b[0m\x1b[1;7;38;2;200;100;50mHello\r\n", 80);
        // Soft-wrapped record (no `\r\n`) with wide glyph + combining mark
        builder.push_sgr_journal_record(1, "\x1b[0m中a\u{0300}".as_bytes(), 80);

        let batch = builder.finish_encoded();
        let rows = decode_tcg1_batch(batch.compression, &batch.payload).expect("decode");
        assert_eq!(rows.len(), 2);

        assert_eq!(rows[0].flags & LINE_FLAG_WRAPS_NEXT, 0);
        assert_eq!(rows[0].stored_cols, 5);
        assert_eq!(rows[0].logical_cols, 80);
        assert_eq!(
            rows[0].cell_words[0],
            COLOR_RGB | (200 << 16) | (100 << 8) | 50
        );
        assert_eq!(rows[0].cell_words[2], ATTR_BOLD | ATTR_INVERSE);

        assert_ne!(rows[1].flags & LINE_FLAG_WRAPS_NEXT, 0);
        assert_ne!(rows[1].flags & LINE_FLAG_HAS_COMBINING, 0);
        assert_eq!(rows[1].stored_cols, 3); // '中' (cols 0,1) + 'a' (col 2)
        assert_eq!(rows[1].combining, vec![(2, 0x0300)]);
    }

    #[test]
    fn handover_modes_preserve_stacks_alt_screen_and_allow_live_title_resets() {
        let mut term1 = make_terminal(40, 10);
        let mut tracker1 = TerminalModeTracker::new();
        feed(
            &mut term1,
            &mut tracker1,
            b"\x1b]0;Adopted TUI\x07\x1b[>1u\x1b[?1049h\x1b[>5u\x1b[?2004;5;1002;1006h",
        );

        let exported = tracker1.export_handover_modes(&term1);
        assert!(exported.in_alt_screen);
        assert_eq!(exported.primary_kitty_stack, vec![1]);
        assert_eq!(exported.alt_kitty_stack, vec![5]);
        assert_eq!(exported.kitty_keyboard_flags, 5);
        assert!(exported.bracketed_paste);
        assert!(exported.reverse_video);
        assert_eq!(exported.title, "Adopted TUI");

        // Adopt onto a second daemon whose replay tail did not include the old OSC/mode setup.
        let mut term2 = make_terminal(40, 10);
        let mut tracker2 = TerminalModeTracker::new();
        tracker2.restore_handover_modes(&exported);
        apply_handover_modes_to_terminal(&mut term2, &exported);

        assert!(term2.is_alt_screen_active());
        assert!(term2.bracketed_paste_enabled());
        assert!(term2.get_reverse_video());
        assert!(term2.is_mouse_grabbed());
        assert_eq!(tracker2.kitty_keyboard_flags(true), 5);
        assert_eq!(tracker2.kitty_keyboard_flags(false), 1);

        // A second handover before any new OSC title must still preserve "Adopted TUI".
        let exported2 = tracker2.export_handover_modes(&term2);
        assert_eq!(exported2.title, "Adopted TUI");

        // Leaving alt screen restores primary Kitty stack (`1`) while preserving
        // alt screen's Kitty stack (`5`), matching wezterm-term (`Screen::keyboard_stack`).
        feed(&mut term2, &mut tracker2, b"\x1b[?1049l");
        assert_eq!(tracker2.kitty_keyboard_flags(false), 1);
        assert_eq!(tracker2.kitty_keyboard_flags(true), 5);

        // Live ESC c (`RIS`) resets modes, clears both Kitty stacks, bumps erase gens,
        // and clears handover title fallback.
        let pre_erase_sb = tracker2.erase_scrollback_gen();
        let pre_erase_disp = tracker2.erase_display_gen();
        feed(&mut term2, &mut tracker2, b"\x1bc");
        assert_eq!(tracker2.kitty_keyboard_flags(false), 0);
        assert_eq!(tracker2.kitty_keyboard_flags(true), 0);
        assert_eq!(tracker2.erase_scrollback_gen(), pre_erase_sb + 1);
        assert_eq!(tracker2.erase_display_gen(), pre_erase_disp + 1);
        let (title_after_ris, _) = tracker2.observe_terminal_title(&term2);
        assert_eq!(title_after_ris, "wezterm");
    }

    #[test]
    fn sideband_lexer_matches_vtparse_on_osc_dcs_utf8_intermediates_and_split_cht() {
        let mut term = make_terminal(25, 5);
        let mut tracker = TerminalModeTracker::new();

        // 1. Unterminated OSC aborted by ESC + `[?1049h` enters alt-screen just like vtparse.
        feed(&mut term, &mut tracker, b"\x1b]0;unterminated\x1b[?1049h");
        assert!(term.is_alt_screen_active());
        assert!(tracker.in_alt_screen());

        // 2. CSI 3J inside alt-screen does NOT increment primary erase_scrollback_gen.
        let sb_gen = tracker.erase_scrollback_gen();
        feed(&mut term, &mut tracker, b"\x1b[3J");
        assert_eq!(tracker.erase_scrollback_gen(), sb_gen);

        // Exit alt screen; `\x1b[2J\x1b[3J` on primary screen increments both gens,
        // while multi-param `\x1b[2;3J` is ignored to match wezterm-escape-parser.
        feed(&mut term, &mut tracker, b"\x1b[?1049l\x1b[2;3J");
        assert_eq!(tracker.erase_scrollback_gen(), sb_gen);
        feed(&mut term, &mut tracker, b"\x1b[2J\x1b[3J");
        assert_eq!(tracker.erase_scrollback_gen(), sb_gen + 1);

        // 3. CSI with space intermediate (`\x1b[3 J`) must NOT increment erase_scrollback_gen.
        feed(&mut term, &mut tracker, b"\x1b[3 J");
        assert_eq!(tracker.erase_scrollback_gen(), sb_gen + 1);

        // 4. DCS/APC ignore embedded BEL (`0x07`) until ST (`ESC \`).
        let bell_before = tracker.bell_gen();
        feed(&mut term, &mut tracker, b"\x1bP1$r\x07payload\x1b\\");
        feed(&mut term, &mut tracker, b"\x1b_Gi=1;\x07\x1b\\");
        assert_eq!(tracker.bell_gen(), bell_before);

        // 5. UTF-8 smart quotes (`0xe2 0x80 0x9c` / `0x9d`) inside OSC do not terminate OSC early.
        feed(&mut term, &mut tracker, "\x1b]0;build “ok”\x07".as_bytes());
        assert_eq!(term.get_title(), "build “ok”");
        assert_eq!(tracker.bell_gen(), bell_before);

        // 6. Up to 16 DEC private mode params (vtparse MAX_PARAMS=32 including `?` and `;`)
        // are all applied, while params past slot 32 are ignored in lockstep with vtparse.
        feed(
            &mut term,
            &mut tracker,
            b"\x1b[?1;1;1;1;1;1;1;1;1;1;1;1;1;1;1004;2026h",
        );
        assert!(tracker.is_in_synchronized_update(Instant::now(), Duration::from_millis(50)));
        assert!(tracker.export_handover_modes(&term).report_focus);
        feed(&mut term, &mut tracker, b"\x1b[?2026l");
        feed(
            &mut term,
            &mut tracker,
            b"\x1b[?1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;2026h",
        );
        assert!(!tracker.is_in_synchronized_update(Instant::now(), Duration::from_millis(50)));

        // 7. Split, zero-padded, DEL-embedded, and C1 `0x9b` CHT/CBT clamp cleanly,
        // while multi-param `\x1b[2;999999I` stays a no-op matching wezterm-escape-parser.
        feed(&mut term, &mut tracker, b"\r\x1b[2;999999I");
        assert_eq!(term.cursor_pos().x, 0);

        let zeros = vec![b'0'; 400];
        feed(&mut term, &mut tracker, b"\r\x1b[");
        feed(&mut term, &mut tracker, &zeros);
        feed(&mut term, &mut tracker, b"9999\x7f9999I");
        assert_eq!(term.cursor_pos().x, 24);

        feed(&mut term, &mut tracker, b"\x9b999999999Z");
        assert_eq!(term.cursor_pos().x, 0);
    }

    #[test]
    fn sgr_journal_truncation_extended_params_zlib_cap_and_force_full_transients() {
        // 1. Journal record > MAX_ENCODED_COLS drops post-limit combining marks instead of
        // attaching them to column 4094, and handles >16 SGR params + colon undercurl/RGB.
        let mut rec = Vec::from(&b"\x1b[0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;4:3;38:2::12:34:56m"[..]);
        rec.resize(rec.len() + MAX_ENCODED_COLS, b'x');
        rec.extend_from_slice("y\u{0301}\r\n".as_bytes());

        let mut builder = Tcg1BatchBuilder::with_row_capacity(1, 80);
        builder.push_sgr_journal_record(0, &rec, 80);
        let batch = builder.finish_encoded();
        let rows = decode_tcg1_batch(batch.compression, &batch.payload).expect("decode long row");
        assert_eq!(rows[0].stored_cols, MAX_ENCODED_COLS);
        assert_eq!(rows[0].flags & LINE_FLAG_HAS_COMBINING, 0);
        assert!(rows[0].combining.is_empty());
        assert_eq!(
            rows[0].cell_words[0],
            COLOR_RGB | (12 << 16) | (34 << 8) | 56
        );
        assert_eq!(rows[0].cell_words[2], ATTR_UNDERLINE | ATTR_UNDERCURL);

        // 2. Zlib bomb > MAX_DECOMPRESSED_TCG1_BYTES is rejected cleanly.
        let mut z_enc = ZlibEncoder::new(Vec::new(), Compression::fast());
        let zeros = vec![0u8; 64 * 1024];
        for _ in 0..((MAX_DECOMPRESSED_TCG1_BYTES / zeros.len()) + 2) {
            z_enc.write_all(&zeros).unwrap();
        }
        let bomb = z_enc.finish().unwrap();
        let err = decode_tcg1_batch(CELL_COMPRESSION_ZLIB, &bomb).unwrap_err();
        assert!(
            err.contains("exceeds maximum size"),
            "unexpected err: {err}"
        );

        // 3. Out-of-bounds combining `line_idx` is rejected cleanly.
        let mut bad_raw = Vec::new();
        push_u32_le(&mut bad_raw, TCG1_MAGIC);
        push_u32_le(&mut bad_raw, 1); // 1 row
        push_u32_le(&mut bad_raw, 1); // 1 combining entry
        push_u32_le(&mut bad_raw, 0); // row_index = 0
        push_u32_le(&mut bad_raw, 80 << 12); // stored_cols = 0, logical_cols = 80
        push_u32_le(&mut bad_raw, 5); // line_idx = 5 (out of bounds!)
        push_u32_le(&mut bad_raw, 0);
        push_u32_le(&mut bad_raw, 0x0301);
        assert!(decode_tcg1_batch(CELL_COMPRESSION_NONE, &bad_raw).is_err());

        // 4. `force_full = true` on an initialized baseline still reports transient flags.
        let mut term = make_terminal(20, 4);
        let mut tracker = TerminalModeTracker::new();
        let mut baseline = ClientSyncBaseline::new();
        let metrics = VirtualScrollbackMetrics {
            total_scrollback_rows: 0,
            trimmed_top_rows: 0,
        };
        let _ = baseline.diff_terminal(&term, &mut tracker, metrics, true);
        feed(&mut term, &mut tracker, b"\x07\x1b[2J\x1b[3J");
        let forced = baseline
            .diff_terminal(&term, &mut tracker, metrics, true)
            .expect("forced full patch");
        assert_ne!(forced.mode_flags & MODE_BELL_RANG, 0);
        assert_ne!(forced.mode_flags & MODE_SAW_ERASE_DISPLAY, 0);
        assert_ne!(forced.mode_flags & MODE_SAW_ERASE_SCROLLBACK, 0);
    }

    #[test]
    fn utf8_rfc3629_kitty_handover_mouse_stack_and_tcg1_parity() {
        let mut term = make_terminal(25, 5);
        let mut tracker = TerminalModeTracker::new();

        // 1. Truncated UTF-8 lead byte (`0xe2`) consumes an immediately-following
        // `0x1b` as an invalid sequence (`U+FFFD`) in `vtparse`/`utf8parse`, so
        // `\xe2\x1b[?1049h` does NOT enter alt-screen in either `Terminal` or tracker.
        feed(&mut term, &mut tracker, b"\xe2\x1b[?1049h");
        assert_eq!(term.is_alt_screen_active(), tracker.in_alt_screen());
        assert!(!tracker.in_alt_screen());

        // 2. Trailing UTF-8 lead byte in an otherwise-ASCII chunk inside OSC must not
        // be bypassed by the Ground/ASCII fast path across chunk boundaries.
        feed(&mut term, &mut tracker, b"\x1b]0;hi");
        feed(&mut term, &mut tracker, b"\xe2");
        feed(&mut term, &mut tracker, b"\x80\x9c\x07");
        assert_eq!(term.get_title(), "hi\u{201c}");

        // 3. Surrogate second byte (`0xed 0xa0`) resets UTF-8 state on `0xa0`, so a
        // third byte `\x1b[?1049h` IS recognized as ESC by both `Terminal` and tracker.
        feed(&mut term, &mut tracker, b"\xed\xa0\x1b[?1049h");
        assert_eq!(term.is_alt_screen_active(), tracker.in_alt_screen());
        assert!(tracker.in_alt_screen());
        feed(&mut term, &mut tracker, b"\x1b[?1049l");

        // 4. DEC mouse tracking & encoding stacks preserve remaining active modes on
        // sibling disable (`?1006h?1015l?1005l` and `?1002h?1000h?1003l?1000l`).
        feed(
            &mut term,
            &mut tracker,
            b"\x1b[?1002h\x1b[?1000h\x1b[?1003l\x1b[?1006h\x1b[?1015l\x1b[?1005l",
        );
        assert_eq!(tracker.mouse_mode(), 2);
        assert_eq!(tracker.mouse_report_mode(), 2);
        feed(&mut term, &mut tracker, b"\x1b[?1000l");
        assert_eq!(tracker.mouse_mode(), 3);

        // 5. `apply_handover_modes_to_terminal` restores both primary and alt Kitty
        // keyboard stacks onto `Terminal`.
        feed(&mut term, &mut tracker, b"\x1b[>1;1u\x1b[?1049h\x1b[>11;1u");
        let exported = tracker.export_handover_modes(&term);
        let mut adopted = make_terminal(25, 5);
        apply_handover_modes_to_terminal(&mut adopted, &exported);
        assert!(adopted.is_alt_screen_active());
        assert_eq!(
            adopted.get_keyboard_encoding(),
            term.get_keyboard_encoding()
        );
        adopted.advance_bytes(b"\x1b[?1049l");
        term.advance_bytes(b"\x1b[?1049l");
        assert_eq!(
            adopted.get_keyboard_encoding(),
            term.get_keyboard_encoding()
        );

        // 6. `decode_tcg1_batch` enforces Dart-parity header caps, codepoint sanitization,
        // and `LINE_FLAG_HAS_COMBINING` gating.
        let mut row_oob = Vec::new();
        push_u32_le(&mut row_oob, TCG1_MAGIC);
        push_u32_le(&mut row_oob, 1);
        push_u32_le(&mut row_oob, 0);
        push_u32_le(&mut row_oob, 0x10000); // row_index out of bounds
        push_u32_le(&mut row_oob, 80 << 12);
        assert!(decode_tcg1_batch(CELL_COMPRESSION_NONE, &row_oob).is_err());

        let mut cols_oob = Vec::new();
        push_u32_le(&mut cols_oob, TCG1_MAGIC);
        push_u32_le(&mut cols_oob, 1);
        push_u32_le(&mut cols_oob, 0);
        push_u32_le(&mut cols_oob, 0);
        push_u32_le(&mut cols_oob, 10 | (5 << 12)); // stored_cols (10) > logical_cols (5)
        for _ in 0..(10 * CELL_WORDS) {
            push_u32_le(&mut cols_oob, 0);
        }
        assert!(decode_tcg1_batch(CELL_COMPRESSION_NONE, &cols_oob).is_err());

        let mut surrogate_raw = Vec::new();
        push_u32_le(&mut surrogate_raw, TCG1_MAGIC);
        push_u32_le(&mut surrogate_raw, 1);
        push_u32_le(&mut surrogate_raw, 1);
        push_u32_le(&mut surrogate_raw, 0);
        push_u32_le(&mut surrogate_raw, 1 | (80 << 12)); // no LINE_FLAG_HAS_COMBINING
        push_u32_le(&mut surrogate_raw, 0);
        push_u32_le(&mut surrogate_raw, 0);
        push_u32_le(&mut surrogate_raw, 0);
        push_u32_le(&mut surrogate_raw, 0xD800 | (1 << CONTENT_WIDTH_SHIFT));
        push_u32_le(&mut surrogate_raw, 0);
        push_u32_le(&mut surrogate_raw, 0);
        push_u32_le(&mut surrogate_raw, 0);
        let decoded = decode_tcg1_batch(CELL_COMPRESSION_NONE, &surrogate_raw).expect("sanitized");
        assert_eq!(decoded[0].cell_words[3] & CONTENT_CODEPOINT_MASK, 0xFFFD);
        assert!(decoded[0].combining.is_empty());
    }

    #[test]
    fn infer_initial_replay_modes_respects_primary_vs_alt_screen_defaults() {
        let primary_end = HandoverTerminalModes {
            in_alt_screen: false,
            auto_wrap: true,
            origin_mode: false,
            ..Default::default()
        };

        // 1. Primary-screen tail with routine shell/CLI defensive `?7h` and `?6l`
        // keeps primary defaults (`auto_wrap == true`, `origin_mode == false`).
        let primary_defensive =
            infer_initial_replay_modes(b"long wrapped line\r\n\x1b[?7h\x1b[?6l$ ", &primary_end);
        assert!(!primary_defensive.in_alt_screen);
        assert!(primary_defensive.auto_wrap);
        assert!(!primary_defensive.origin_mode);

        // 2. Alt-screen tail (`?1049l` seen first) with `?7h` and `?6l` infers
        // TUI modes (`auto_wrap == false`, `origin_mode == true`), while
        // `modes_for_screen(false)` resolves to `(true, false)` when external
        // scrollback evidence overrides `initial_alt = false`.
        let alt_tail =
            infer_initial_replay_modes(b"status bar\x1b[?7h\x1b[?6l\x1b[?1049l$ ", &primary_end);
        assert!(alt_tail.in_alt_screen);
        assert!(!alt_tail.auto_wrap);
        assert!(alt_tail.origin_mode);
        assert_eq!(alt_tail.modes_for_screen(false), (true, false));

        // 3. Explicit `?7l` and `?6h` as first transitions resolve to `(true, false)`
        // regardless of initial screen.
        let explicit_disable =
            infer_initial_replay_modes(b"wrapped\r\n\x1b[?7l\x1b[?6h\x1b[?1049l", &primary_end);
        assert!(explicit_disable.in_alt_screen);
        assert!(explicit_disable.auto_wrap);
        assert!(!explicit_disable.origin_mode);

        // 4. Alt-screen tail exiting via `?1049l` or `?47l` without touching `?7`/`?6`,
        // followed by wrapped primary-screen output and a later shell defensive
        // `\x1b[?7h\x1b[?6l$ `, must NOT invert post-exit primary-screen modes onto
        // the initial replay epoch.
        let post_exit_1049_defensive = infer_initial_replay_modes(
            b"tui frame\x1b[?1049lwrapped primary line\r\n\x1b[?7h\x1b[?6l$ ",
            &primary_end,
        );
        assert!(post_exit_1049_defensive.in_alt_screen);
        assert_eq!(
            post_exit_1049_defensive.modes_for_screen(true),
            (true, false)
        );
        assert_eq!(
            post_exit_1049_defensive.modes_for_screen(false),
            (true, false)
        );

        let post_exit_47_defensive = infer_initial_replay_modes(
            b"tui frame\x1b[?47lwrapped primary line\r\n\x1b[?7h\x1b[?6l$ ",
            &primary_end,
        );
        assert!(post_exit_47_defensive.in_alt_screen);
        assert_eq!(post_exit_47_defensive.modes_for_screen(true), (true, false));

        // 5. Alt-screen tail exiting via `?1049l`, printing wrapped primary output,
        // and entering a second alt-screen (`?1049h\x1b[?7l`) keeps `auto_wrap == true`
        // for the initial replay epoch even when `end_modes.auto_wrap == false`.
        let second_alt_end = HandoverTerminalModes {
            in_alt_screen: true,
            auto_wrap: false,
            origin_mode: false,
            ..Default::default()
        };
        let multi_epoch = infer_initial_replay_modes(
            b"tui1\x1b[?1049lwrapped primary\r\n\x1b[?1049h\x1b[?7l",
            &second_alt_end,
        );
        assert!(multi_epoch.in_alt_screen);
        assert_eq!(multi_epoch.modes_for_screen(true), (true, false));

        // 6. Unmatched cursor restore (`ESC 8`, `CSI u`, `?1048l`, or `?1049l`) before
        // any `?6` severs `end_modes.origin_mode` from t=0, whereas a matched in-tail
        // save/restore (`ESC 7 ... ESC 8`) preserves `end_modes.origin_mode`.
        let origin_end = HandoverTerminalModes {
            in_alt_screen: false,
            auto_wrap: true,
            origin_mode: true,
            ..Default::default()
        };
        let unmatched_decrc = infer_initial_replay_modes(b"body\x1b8tail", &origin_end);
        assert_eq!(unmatched_decrc.modes_for_screen(false), (true, false));

        let unmatched_1049l = infer_initial_replay_modes(b"tui\x1b[?1049ltail", &origin_end);
        assert_eq!(unmatched_1049l.modes_for_screen(true), (true, false));
        assert_eq!(unmatched_1049l.modes_for_screen(false), (true, true));

        let matched_save_restore = infer_initial_replay_modes(b"\x1b7status\x1b8body", &origin_end);
        assert_eq!(matched_save_restore.modes_for_screen(false), (true, true));

        // 7. Soft reset (`CSI ! p`, DECSTR) resets tracked modes and severs backward
        // inference just like `ESC c` (`RIS`).
        let mut tracker = TerminalModeTracker::new();
        let _ = tracker.observe_and_sanitize(b"\x1b[?1;6;66;1049h\x1b[?7l", 80);
        assert!(tracker.in_alt_screen());
        let _ = tracker.observe_and_sanitize(b"\x1b[!p", 80);
        assert!(!tracker.in_alt_screen());
        let decstr_inferred = infer_initial_replay_modes(
            b"before\x1b[!p\x1b[?1049h\x1b[?7l\x1b[?6h",
            &HandoverTerminalModes {
                in_alt_screen: true,
                auto_wrap: false,
                origin_mode: true,
                ..Default::default()
            },
        );
        assert!(!decstr_inferred.in_alt_screen);
        assert_eq!(decstr_inferred.modes_for_screen(false), (true, false));
    }

    #[test]
    fn mode_tracker_handles_compound_decset_kitty_cap_screen_title_and_journal_graphemes() {
        let mut term = make_terminal(80, 24);
        let mut tracker = TerminalModeTracker::new();
        // Compound DECSET up to vtparse's 16-param (31-token) window applies every mode,
        // a 17th param beyond vtparse's window is ignored in lockstep with wezterm, and a
        // colon subparam stops subsequent params just like wezterm_escape_parser.
        let mut max_decset = String::from("\x1b[?");
        for idx in 1..=14 {
            max_decset.push_str(&format!("{};", 2000 + idx));
        }
        max_decset.push_str("1002;1006h");
        feed(&mut term, &mut tracker, max_decset.as_bytes());
        assert!(term.is_mouse_grabbed());
        let modes1 = tracker.export_handover_modes(&term);
        assert_eq!(modes1.mouse_mode, 3);
        assert_eq!(modes1.mouse_report_mode, 2);

        let mut overflow_decset = String::from("\x1b[?");
        for idx in 1..=16 {
            overflow_decset.push_str(&format!("{};", 2000 + idx));
        }
        overflow_decset.push_str("1049h");
        feed(&mut term, &mut tracker, overflow_decset.as_bytes());
        assert!(!term.is_alt_screen_active());
        assert!(!tracker.in_alt_screen());

        feed(&mut term, &mut tracker, b"\x1b[?1003:1;1005h");
        let modes_colon = tracker.export_handover_modes(&term);
        assert_eq!(modes_colon.mouse_mode, 4);
        assert_eq!(modes_colon.mouse_report_mode, 2);

        // Kitty keyboard push caps at 128 entries, masks flags to 5 bits, and preserves
        // alt_kitty_stack across ?1049l alt-screen exit.
        feed(&mut term, &mut tracker, b"\x1b[?1049h");
        for _ in 0..140 {
            feed(&mut term, &mut tracker, b"\x1b[>63u");
        }
        let modes_alt = tracker.export_handover_modes(&term);
        assert_eq!(modes_alt.kitty_keyboard_flags, 0x1f);
        assert_eq!(modes_alt.alt_kitty_stack.len(), 128);
        feed(&mut term, &mut tracker, b"\x1b[?1049l");
        let modes_after_exit = tracker.export_handover_modes(&term);
        assert_eq!(modes_after_exit.alt_kitty_stack.len(), 128);
        assert_eq!(modes_after_exit.kitty_keyboard_flags, 0);

        // GNU screen / tmux `ESC k ... ST` records custom titles (including explicit empty `""`
        // so handover clears `"wezterm"` default), and `ESC c` (`RIS`) resets `has_custom_title`.
        feed(&mut term, &mut tracker, b"\x1bkmy-window\x1b\\");
        let modes_titled = tracker.export_handover_modes(&term);
        assert!(modes_titled.has_custom_title);
        assert_eq!(modes_titled.title, "my-window");
        feed(&mut term, &mut tracker, b"\x1bk\x1b\\");
        let modes_cleared = tracker.export_handover_modes(&term);
        assert!(modes_cleared.has_custom_title);
        assert!(modes_cleared.title.is_empty());
        feed(&mut term, &mut tracker, b"\x1bc");
        let fresh_term = make_terminal(80, 24);
        assert!(!tracker.export_handover_modes(&fresh_term).has_custom_title);

        // `push_sgr_journal_record` keeps empty `b""` non-wrapping and promotes VS16,
        // ZWJ sequences, and Regional Indicator pairs to width-2 lead + spacer cells.
        let mut builder = Tcg1BatchBuilder::with_row_capacity(4, 16);
        builder.push_sgr_journal_record(0, b"", 8);
        builder.push_sgr_journal_record(
            1,
            "\u{2764}\u{FE0F}\u{1F468}\u{200D}\u{1F4BB}\u{1F1FA}\u{1F1F8}\r\n".as_bytes(),
            8,
        );
        let batch = builder.finish_encoded();
        let rows = decode_tcg1_batch(batch.compression, &batch.payload).expect("decode batch");
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].flags & LINE_FLAG_WRAPS_NEXT, 0);
        assert_eq!(rows[1].flags & LINE_FLAG_WRAPS_NEXT, 0);
        assert_eq!(rows[1].stored_cols, 6);
        let cell_cp =
            |col: usize| rows[1].cell_words[col * CELL_WORDS + 3] & CONTENT_CODEPOINT_MASK;
        let cell_w =
            |col: usize| (rows[1].cell_words[col * CELL_WORDS + 3] >> CONTENT_WIDTH_SHIFT) & 0x3;
        assert_eq!(cell_cp(0), 0x2764);
        assert_eq!(cell_w(0), 2);
        assert_eq!(cell_w(1), 0);
        assert_eq!(cell_cp(2), 0x1F468);
        assert_eq!(cell_w(2), 2);
        assert_eq!(cell_w(3), 0);
        assert_eq!(cell_cp(4), 0x1F1FA);
        assert_eq!(cell_w(4), 2);
        assert_eq!(cell_w(5), 0);
        assert!(rows[1].combining.contains(&(0, 0xFE0F)));
        assert!(rows[1].combining.contains(&(2, 0x200D)));
        assert!(rows[1].combining.contains(&(2, 0x1F4BB)));
        assert!(rows[1].combining.contains(&(4, 0x1F1F8)));
    }
}
