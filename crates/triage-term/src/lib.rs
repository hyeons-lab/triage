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
    pub title: String,
}

fn default_auto_wrap() -> bool {
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
            title: String::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EscapeScanState {
    Ground,
    Escape,
    Csi,
    Osc,
    OscEscape,
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
    auto_wrap: bool,
    report_focus: bool,
    mouse_mode: u32,
    mouse_report_mode: u32,
    in_alt_screen: bool,
    primary_kitty_stack: Vec<u32>,
    alt_kitty_stack: Vec<u32>,
    erase_scrollback_gen: u64,
    erase_display_gen: u64,
    bell_gen: u64,
    title_gen: u64,
    last_observed_title: String,
    sync_update_started_at: Option<Instant>,
    scan_state: EscapeScanState,
    csi_buf: Vec<u8>,
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
            auto_wrap: true,
            report_focus: false,
            mouse_mode: 0,
            mouse_report_mode: 0,
            in_alt_screen: false,
            primary_kitty_stack: Vec::new(),
            alt_kitty_stack: Vec::new(),
            erase_scrollback_gen: 0,
            erase_display_gen: 0,
            bell_gen: 0,
            title_gen: 0,
            last_observed_title: String::new(),
            sync_update_started_at: None,
            scan_state: EscapeScanState::Ground,
            csi_buf: Vec::with_capacity(64),
            sanitize_scratch: Vec::new(),
        }
    }

    /// Exports current mode state for zero-downtime daemon handover.
    pub fn export_handover_modes(&self, current_title: &str) -> HandoverTerminalModes {
        HandoverTerminalModes {
            app_cursor_keys: self.app_cursor_keys,
            app_keypad: self.app_keypad,
            origin_mode: self.origin_mode,
            auto_wrap: self.auto_wrap,
            report_focus: self.report_focus,
            mouse_mode: self.mouse_mode,
            mouse_report_mode: self.mouse_report_mode,
            kitty_keyboard_flags: self.kitty_keyboard_flags(self.in_alt_screen),
            title: current_title.to_owned(),
        }
    }

    /// Seeds initial mode state prior to replaying the recent raw log tail on
    /// handover adoption, so modes entered before the 16 MiB tail survive while
    /// any newer mode transitions inside the tail override them naturally.
    pub fn restore_handover_modes(&mut self, modes: &HandoverTerminalModes) {
        self.app_cursor_keys = modes.app_cursor_keys;
        self.app_keypad = modes.app_keypad;
        self.origin_mode = modes.origin_mode;
        self.auto_wrap = modes.auto_wrap;
        self.report_focus = modes.report_focus;
        self.mouse_mode = modes.mouse_mode;
        self.mouse_report_mode = modes.mouse_report_mode;
        if modes.kitty_keyboard_flags != 0 {
            self.primary_kitty_stack = vec![modes.kitty_keyboard_flags];
            self.alt_kitty_stack = vec![modes.kitty_keyboard_flags];
        }
        if !modes.title.is_empty() && modes.title != self.last_observed_title {
            self.last_observed_title.clone_from(&modes.title);
            self.title_gen = self.title_gen.wrapping_add(1);
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

    /// Returns whether DEC Mode 2026 (`\x1b[?2026h` without matching `\x1b[?2026l`)
    /// is currently open and has been active for less than `max_hold`.
    pub fn is_in_synchronized_update(&self, now: Instant, max_hold: Duration) -> bool {
        self.sync_update_started_at
            .is_some_and(|started| now.saturating_duration_since(started) < max_hold)
    }

    /// Syncs `last_observed_title` against `terminal.get_title()` (falling back
    /// to a handover-restored title when `terminal.get_title()` is still at its
    /// default `"wezterm"` value) and returns `(effective_title, title_gen)`.
    pub fn observe_terminal_title<'a>(&'a mut self, terminal: &'a Terminal) -> (&'a str, u64) {
        let term_title = terminal.get_title();
        let effective = if term_title == "wezterm" && !self.last_observed_title.is_empty() {
            self.last_observed_title.as_str()
        } else {
            if term_title != self.last_observed_title {
                self.last_observed_title.clear();
                self.last_observed_title.push_str(term_title);
                self.title_gen = self.title_gen.wrapping_add(1);
            }
            self.last_observed_title.as_str()
        };
        (effective, self.title_gen)
    }

    /// Scans `bytes` for control / CSI / DEC private mode sequences, updates
    /// sideband mode state across arbitrary chunk boundaries, and clamps
    /// oversized `CHT` (`CSI Ps I`) / `CBT` (`CSI Ps Z`) repeat counts to `cols`.
    ///
    /// Returns a slice to pass to `terminal.advance_bytes(...)`: either `bytes`
    /// directly (zero-copy common case) or `self.sanitize_scratch` when clamping
    /// rewrote an oversized tab repeat count.
    pub fn observe_and_sanitize<'a>(&'a mut self, bytes: &'a [u8], cols: usize) -> &'a [u8] {
        let cols = cols.max(1);
        if self.scan_state == EscapeScanState::Ground
            && !bytes.contains(&0x1b)
            && !bytes.contains(&0x07)
        {
            return bytes;
        }

        let mut modified = false;
        let mut copied_up_to = 0usize;

        for (i, &b) in bytes.iter().enumerate() {
            match self.scan_state {
                EscapeScanState::Ground => {
                    if b == 0x07 {
                        self.bell_gen = self.bell_gen.wrapping_add(1);
                    } else if b == 0x1b {
                        self.scan_state = EscapeScanState::Escape;
                    }
                }
                EscapeScanState::Escape => match b {
                    b'[' => {
                        self.csi_buf.clear();
                        self.scan_state = EscapeScanState::Csi;
                    }
                    b']' => {
                        self.scan_state = EscapeScanState::Osc;
                    }
                    b'=' => {
                        self.app_keypad = true;
                        self.scan_state = EscapeScanState::Ground;
                    }
                    b'>' => {
                        self.app_keypad = false;
                        self.scan_state = EscapeScanState::Ground;
                    }
                    b'c' => {
                        self.reset_modes();
                        self.scan_state = EscapeScanState::Ground;
                    }
                    0x1b => {
                        self.scan_state = EscapeScanState::Escape;
                    }
                    _ => {
                        self.scan_state = EscapeScanState::Ground;
                    }
                },
                EscapeScanState::Osc => {
                    if b == 0x07 {
                        self.scan_state = EscapeScanState::Ground;
                    } else if b == 0x1b {
                        self.scan_state = EscapeScanState::OscEscape;
                    }
                }
                EscapeScanState::OscEscape => {
                    if b == b'\\' || b == 0x07 {
                        self.scan_state = EscapeScanState::Ground;
                    } else if b == 0x1b {
                        self.scan_state = EscapeScanState::OscEscape;
                    } else {
                        self.scan_state = EscapeScanState::Osc;
                    }
                }
                EscapeScanState::Csi => {
                    if (0x20..=0x3f).contains(&b) {
                        if self.csi_buf.len() < 256 {
                            self.csi_buf.push(b);
                        }
                    } else {
                        let final_byte = b;
                        self.scan_state = EscapeScanState::Ground;
                        let params_len = self.csi_buf.len();
                        self.inspect_csi_buf(final_byte);

                        // Clamp single-chunk oversized CHT/CBT sequences (`\x1b[<N>I` or `\x1b[<N>Z`).
                        if (final_byte == b'I' || final_byte == b'Z')
                            && params_len > 0
                            && self.csi_buf.iter().all(|c| c.is_ascii_digit())
                            && let Some(val) = parse_u32_ascii(&self.csi_buf)
                            && (val as usize) > cols
                            && i >= params_len + 2
                            && bytes[i - params_len - 2] == 0x1b
                            && bytes[i - params_len - 1] == b'['
                        {
                            let param_start = i - params_len;
                            if !modified {
                                self.sanitize_scratch.clear();
                                self.sanitize_scratch.reserve(bytes.len());
                                modified = true;
                            }
                            self.sanitize_scratch
                                .extend_from_slice(&bytes[copied_up_to..param_start]);
                            let mut num_buf = [0u8; 16];
                            let num_len = write_usize_ascii(cols, &mut num_buf);
                            self.sanitize_scratch.extend_from_slice(&num_buf[..num_len]);
                            self.sanitize_scratch.push(final_byte);
                            copied_up_to = i + 1;
                        }
                        self.csi_buf.clear();
                    }
                }
            }
        }

        if modified {
            if copied_up_to < bytes.len() {
                self.sanitize_scratch
                    .extend_from_slice(&bytes[copied_up_to..]);
            }
            &self.sanitize_scratch
        } else {
            bytes
        }
    }

    fn reset_modes(&mut self) {
        self.app_cursor_keys = false;
        self.app_keypad = false;
        self.origin_mode = false;
        self.auto_wrap = true;
        self.report_focus = false;
        self.mouse_mode = 0;
        self.mouse_report_mode = 0;
        self.in_alt_screen = false;
        self.primary_kitty_stack.clear();
        self.alt_kitty_stack.clear();
        self.sync_update_started_at = None;
    }

    fn active_kitty_stack_mut(&mut self) -> &mut Vec<u32> {
        if self.in_alt_screen {
            &mut self.alt_kitty_stack
        } else {
            &mut self.primary_kitty_stack
        }
    }

    fn inspect_csi_buf(&mut self, final_byte: u8) {
        match final_byte {
            b'J' => {
                let mut start = 0usize;
                let buf = &self.csi_buf;
                loop {
                    let end = buf[start..]
                        .iter()
                        .position(|&c| c == b';')
                        .map_or(buf.len(), |p| start + p);
                    let code = parse_u32_ascii(&buf[start..end]).unwrap_or(0);
                    if code == 2 {
                        self.erase_display_gen = self.erase_display_gen.wrapping_add(1);
                    } else if code == 3 {
                        self.erase_scrollback_gen = self.erase_scrollback_gen.wrapping_add(1);
                    }
                    if end >= buf.len() {
                        break;
                    }
                    start = end + 1;
                }
            }
            b'u' => match self.csi_buf.first().copied() {
                Some(b'>') => {
                    let flags = self.csi_buf[1..]
                        .split(|&c| c == b';')
                        .next()
                        .and_then(parse_u32_ascii)
                        .unwrap_or(0);
                    let stack = self.active_kitty_stack_mut();
                    if stack.len() >= 16 {
                        stack.remove(0);
                    }
                    stack.push(flags);
                }
                Some(b'<') => {
                    let pop_count = self.csi_buf[1..]
                        .split(|&c| c == b';')
                        .next()
                        .and_then(parse_u32_ascii)
                        .unwrap_or(1)
                        .max(1) as usize;
                    let stack = self.active_kitty_stack_mut();
                    let new_len = stack.len().saturating_sub(pop_count);
                    stack.truncate(new_len);
                }
                Some(b'=') => {
                    let mut parts = self.csi_buf[1..].split(|&c| c == b';');
                    let flags = parts.next().and_then(parse_u32_ascii).unwrap_or(0);
                    let mode = parts.next().and_then(parse_u32_ascii).unwrap_or(1);
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
                _ => {}
            },
            b'h' | b'l' if self.csi_buf.first() == Some(&b'?') => {
                let enabled = final_byte == b'h';
                let mut codes = [0u32; 16];
                let mut count = 0usize;
                for p in self.csi_buf[1..].split(|&c| c == b';') {
                    if let Some(code) = parse_u32_ascii(p)
                        && count < codes.len()
                    {
                        codes[count] = code;
                        count += 1;
                    }
                }
                for &code in &codes[..count] {
                    self.apply_dec_private_mode(code, enabled);
                }
            }
            _ => {}
        }
    }

    fn apply_dec_private_mode(&mut self, code: u32, enabled: bool) {
        match code {
            1 => self.app_cursor_keys = enabled,
            6 => self.origin_mode = enabled,
            7 => self.auto_wrap = enabled,
            47 | 1047 | 1049 => {
                self.in_alt_screen = enabled;
                if !enabled {
                    self.alt_kitty_stack.clear();
                }
            }
            66 => self.app_keypad = enabled,
            9 => {
                self.mouse_mode = if enabled { 1 } else { 0 };
            }
            1000 => {
                self.mouse_mode = if enabled { 2 } else { 0 };
            }
            1002 => {
                self.mouse_mode = if enabled { 3 } else { 0 };
            }
            1003 => {
                self.mouse_mode = if enabled { 4 } else { 0 };
            }
            1004 => self.report_focus = enabled,
            1005 => {
                self.mouse_report_mode = if enabled { 1 } else { 0 };
            }
            1006 => {
                self.mouse_report_mode = if enabled { 2 } else { 0 };
            }
            1015 => {
                self.mouse_report_mode = if enabled { 3 } else { 0 };
            }
            1016 => {
                self.mouse_report_mode = if enabled { 4 } else { 0 };
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
                let width = cell.width().clamp(1, 2);
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
                if width == 2 && col + 1 < clamped_cols {
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

        let has_combining = !self.combining_scratch.is_empty();
        for &(col, cp) in &self.combining_scratch {
            if (col as usize) < stored_cols {
                self.combining_words.push(line_entry_idx);
                self.combining_words.push(col);
                self.combining_words.push(cp);
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
        let wraps_next = !record_bytes.ends_with(b"\r\n");
        let body = if !wraps_next {
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
                    i = j + 1;
                    continue;
                }
                break;
            }

            let rest = &body[i..];
            let ch = match std::str::from_utf8(rest) {
                Ok(s) => s.chars().next().unwrap_or('\u{FFFD}'),
                Err(err) => {
                    let valid_len = err.valid_up_to();
                    if valid_len > 0 {
                        std::str::from_utf8(&rest[..valid_len])
                            .ok()
                            .and_then(|s| s.chars().next())
                            .unwrap_or('\u{FFFD}')
                    } else {
                        i += err.error_len().unwrap_or(1).max(1);
                        '\u{FFFD}'
                    }
                }
            };
            if rest[0] < 0x80 || std::str::from_utf8(&rest[..ch.len_utf8().min(rest.len())]).is_ok()
            {
                i += ch.len_utf8();
            }

            if ch.is_control() {
                continue;
            }

            let raw_width = UnicodeWidthChar::width(ch).unwrap_or(0);
            if raw_width == 0 {
                if let Some(prev_col) = last_cell_col {
                    self.combining_scratch.push((prev_col as u32, ch as u32));
                }
                continue;
            }

            if col >= MAX_ENCODED_COLS {
                continue;
            }
            let width = raw_width.clamp(1, 2);
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

            if width == 2 && col + 1 < MAX_ENCODED_COLS {
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
        let has_combining = !self.combining_scratch.is_empty();
        for &(c_col, cp) in &self.combining_scratch {
            self.combining_words.push(line_entry_idx);
            self.combining_words.push(c_col);
            self.combining_words.push(cp);
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
    let raw_cow: Vec<u8> = match compression {
        CELL_COMPRESSION_NONE => payload.to_vec(),
        CELL_COMPRESSION_ZLIB => {
            let mut decoder = ZlibDecoder::new(payload);
            let mut out = Vec::new();
            decoder
                .read_to_end(&mut out)
                .map_err(|e| format!("zlib decode failed: {e}"))?;
            out
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
    let headers_end = 3usize
        .checked_add(line_count.checked_mul(2).ok_or("line_count overflow")?)
        .ok_or("headers_end overflow")?;
    if headers_end > total_words {
        return Err("TCG1 truncated in line headers".to_owned());
    }

    let mut rows = Vec::with_capacity(line_count);
    let mut cell_cursor = headers_end;
    for i in 0..line_count {
        let row_index = word_at(3 + i * 2);
        let meta = word_at(3 + i * 2 + 1);
        let stored_cols = (meta & 0x0FFF) as usize;
        let logical_cols = ((meta >> 12) & 0x0FFF) as usize;
        let flags = ((meta >> 24) & 0xFF) as u8;
        let words_len = stored_cols * CELL_WORDS;
        if cell_cursor + words_len > total_words {
            return Err("TCG1 truncated in cell words".to_owned());
        }
        let mut cell_words = Vec::with_capacity(words_len);
        for w_idx in cell_cursor..cell_cursor + words_len {
            cell_words.push(word_at(w_idx));
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
        if let Some(row) = rows.get_mut(line_idx) {
            row.combining.push((col, cp));
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

        let saw_erase_scrollback = !force_full
            && self.last_alt_screen.is_some()
            && erase_scrollback_gen != self.last_erase_scrollback_gen;
        let saw_erase_display = !force_full
            && self.last_alt_screen.is_some()
            && erase_display_gen != self.last_erase_display_gen;
        let bell_rang =
            !force_full && self.last_alt_screen.is_some() && bell_gen != self.last_bell_gen;
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
        if !is_alt && !full_viewport && first_visible_stable > screen_baseline.first_visible_stable
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

fn apply_sgr_params(params: &[u8], fg: &mut u32, bg: &mut u32, attrs: &mut u32) {
    if params.is_empty() {
        *fg = COLOR_NORMAL;
        *bg = COLOR_NORMAL;
        *attrs = 0;
        return;
    }
    let mut nums = [0u32; 16];
    let mut count = 0usize;
    for part in params.split(|&b| b == b';') {
        if count >= nums.len() {
            break;
        }
        nums[count] = parse_u32_ascii(part).unwrap_or(0);
        count += 1;
    }
    let mut idx = 0usize;
    while idx < count {
        match nums[idx] {
            0 => {
                *fg = COLOR_NORMAL;
                *bg = COLOR_NORMAL;
                *attrs = 0;
            }
            1 => {
                *attrs = (*attrs & !ATTR_FAINT) | ATTR_BOLD;
            }
            2 => {
                *attrs = (*attrs & !ATTR_BOLD) | ATTR_FAINT;
            }
            3 => *attrs |= ATTR_ITALIC,
            4 => *attrs |= ATTR_UNDERLINE,
            5 | 6 => *attrs |= ATTR_BLINK,
            7 => *attrs |= ATTR_INVERSE,
            8 => *attrs |= ATTR_INVISIBLE,
            9 => *attrs |= ATTR_STRIKETHROUGH,
            22 => *attrs &= !(ATTR_BOLD | ATTR_FAINT),
            23 => *attrs &= !ATTR_ITALIC,
            24 => {
                *attrs &= !(ATTR_UNDERLINE
                    | ATTR_DOUBLE_UNDERLINE
                    | ATTR_UNDERCURL
                    | ATTR_DOTTED_UNDERLINE
                    | ATTR_DASHED_UNDERLINE);
            }
            25 => *attrs &= !ATTR_BLINK,
            27 => *attrs &= !ATTR_INVERSE,
            28 => *attrs &= !ATTR_INVISIBLE,
            29 => *attrs &= !ATTR_STRIKETHROUGH,
            30..=37 => *fg = COLOR_NAMED | (nums[idx] - 30),
            39 => *fg = COLOR_NORMAL,
            40..=47 => *bg = COLOR_NAMED | (nums[idx] - 40),
            49 => *bg = COLOR_NORMAL,
            90..=97 => *fg = COLOR_NAMED | (nums[idx] - 90 + 8),
            100..=107 => *bg = COLOR_NAMED | (nums[idx] - 100 + 8),
            38 if idx + 2 < count && nums[idx + 1] == 5 => {
                let c = nums[idx + 2] & 0xFF;
                *fg = if c < 16 {
                    COLOR_NAMED | c
                } else {
                    COLOR_PALETTE | c
                };
                idx += 2;
            }
            38 if idx + 4 < count && nums[idx + 1] == 2 => {
                let r = nums[idx + 2] & 0xFF;
                let g = nums[idx + 3] & 0xFF;
                let b = nums[idx + 4] & 0xFF;
                *fg = COLOR_RGB | (r << 16) | (g << 8) | b;
                idx += 4;
            }
            48 if idx + 2 < count && nums[idx + 1] == 5 => {
                let c = nums[idx + 2] & 0xFF;
                *bg = if c < 16 {
                    COLOR_NAMED | c
                } else {
                    COLOR_PALETTE | c
                };
                idx += 2;
            }
            48 if idx + 4 < count && nums[idx + 1] == 2 => {
                let r = nums[idx + 2] & 0xFF;
                let g = nums[idx + 3] & 0xFF;
                let b = nums[idx + 4] & 0xFF;
                *bg = COLOR_RGB | (r << 16) | (g << 8) | b;
                idx += 4;
            }
            53 => *attrs |= ATTR_OVERLINE,
            55 => *attrs &= !ATTR_OVERLINE,
            _ => {}
        }
        idx += 1;
    }
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
}
