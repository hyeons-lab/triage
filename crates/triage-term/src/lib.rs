#![allow(unsafe_code)]
#![allow(clippy::missing_safety_doc)]

use std::io::Write;
use std::slice;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use tattoy_wezterm_surface::{CursorShape, CursorVisibility, Line, SequenceNo};
use tattoy_wezterm_term::color::{ColorAttribute, ColorPalette};
use tattoy_wezterm_term::{
    Blink, CellAttributes, Intensity, Terminal, TerminalConfiguration, TerminalSize, Underline,
};

const CELL_WORDS: usize = 4;

// Mode flag bits in `TriageTermSyncHeader.mode_flags`.
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

// `xterm2_core` CellColor type encodings (shifted by 25).
const COLOR_NORMAL: u32 = 0;
const COLOR_NAMED: u32 = 1 << 25;
const COLOR_PALETTE: u32 = 2 << 25;
const COLOR_RGB: u32 = 3 << 25;

// `xterm2_core` CellAttr bit flags.
const ATTR_BOLD: u32 = 1 << 0;
const ATTR_FAINT: u32 = 1 << 1;
const ATTR_ITALIC: u32 = 1 << 2;
const ATTR_UNDERLINE: u32 = 1 << 3;
const ATTR_BLINK: u32 = 1 << 4;
const ATTR_INVERSE: u32 = 1 << 5;
const ATTR_INVISIBLE: u32 = 1 << 6;
const ATTR_STRIKETHROUGH: u32 = 1 << 7;
const ATTR_OVERLINE: u32 = 1 << 8;
const ATTR_DOUBLE_UNDERLINE: u32 = 1 << 9;
const ATTR_UNDERCURL: u32 = 1 << 10;
const ATTR_DOTTED_UNDERLINE: u32 = 1 << 11;
const ATTR_DASHED_UNDERLINE: u32 = 1 << 12;

// `xterm2_core` CellContent bit layout.
const CONTENT_CODEPOINT_MASK: u32 = 0x1f_ffff;
const CONTENT_WIDTH_SHIFT: u32 = 22;

#[derive(Debug)]
struct TriageTermConfig {
    max_lines: usize,
    physical_rows: AtomicUsize,
}

impl TerminalConfiguration for TriageTermConfig {
    fn scrollback_size(&self) -> usize {
        self.max_lines
            .saturating_sub(self.physical_rows.load(Ordering::Relaxed))
    }

    fn color_palette(&self) -> ColorPalette {
        ColorPalette::default()
    }
}

struct NullWriter;

impl Write for NullWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct TriageTermSyncHeader {
    pub total_lines: u32,
    pub physical_rows: u32,
    pub physical_cols: u32,
    pub cursor_x: u32,
    pub cursor_y: u32,
    pub cursor_style: u32,
    pub mode_flags: u32,
    pub mouse_mode: u32,
    pub mouse_report_mode: u32,
    pub explicit_trimmed_top: u32,
    pub pushed_bottom: u32,
    pub dirty_line_count: u32,
    pub cell_words_len: u32,
    pub combining_count: u32,
    pub title_utf8_len: u32,
}

#[derive(Default, Clone, Copy)]
struct ScreenSyncBaseline {
    synced_seqno: SequenceNo,
    stable_offset: usize,
    total_lines: usize,
    physical_rows: usize,
    physical_cols: usize,
}

pub struct TriageTermEngine {
    terminal: Terminal,
    config: Arc<TriageTermConfig>,
    max_lines: usize,
    primary_baseline: ScreenSyncBaseline,
    alt_baseline: ScreenSyncBaseline,
    last_alt_screen: bool,
    resized_since_sync: bool,
    saw_erase_scrollback: bool,
    saw_erase_display: bool,
    bell_rang: bool,
    app_cursor_keys: bool,
    app_keypad: bool,
    origin_mode: bool,
    auto_wrap: bool,
    report_focus: bool,
    mouse_mode: u32,
    mouse_report_mode: u32,
    last_title: String,
    sanitize_scratch: Vec<u8>,
    sync_header: TriageTermSyncHeader,
    // Pairs of `[row_index, flags]` where `flags & 1` = `is_wrapped`, `flags & 2` = `has_combining`.
    dirty_line_meta: Vec<u32>,
    // Packed 4-word (`fg`, `bg`, `attrs`, `content`) cells for all dirty lines in order.
    cell_words: Vec<u32>,
    // Triples of `[dirty_line_idx, col, codepoint]` for cells with extra grapheme codepoints.
    combining_meta: Vec<u32>,
    title_utf8: Vec<u8>,
}

impl TriageTermEngine {
    pub fn new(cols: u32, rows: u32, max_lines: u32) -> Self {
        let physical_cols = (cols as usize).max(1);
        let physical_rows = (rows as usize).max(1);
        let max_lines = (max_lines as usize).max(physical_rows);
        let config = Arc::new(TriageTermConfig {
            max_lines,
            physical_rows: AtomicUsize::new(physical_rows),
        });
        let size = TerminalSize {
            rows: physical_rows,
            cols: physical_cols,
            pixel_width: 0,
            pixel_height: 0,
            dpi: 96,
        };
        let terminal = Terminal::new(
            size,
            Arc::clone(&config) as Arc<dyn TerminalConfiguration + Send + Sync>,
            "Triage",
            env!("CARGO_PKG_VERSION"),
            Box::new(NullWriter),
        );
        let initial_title = terminal.get_title().to_owned();
        let init_baseline = ScreenSyncBaseline {
            synced_seqno: 0,
            stable_offset: 0,
            total_lines: physical_rows,
            physical_rows,
            physical_cols,
        };
        Self {
            terminal,
            config,
            max_lines,
            primary_baseline: init_baseline,
            alt_baseline: init_baseline,
            last_alt_screen: false,
            resized_since_sync: false,
            saw_erase_scrollback: false,
            saw_erase_display: false,
            bell_rang: false,
            app_cursor_keys: false,
            app_keypad: false,
            origin_mode: false,
            auto_wrap: true,
            report_focus: false,
            mouse_mode: 0,
            mouse_report_mode: 0,
            last_title: initial_title,
            sanitize_scratch: Vec::new(),
            sync_header: TriageTermSyncHeader::default(),
            dirty_line_meta: Vec::with_capacity(128),
            cell_words: Vec::with_capacity(physical_rows * physical_cols * CELL_WORDS),
            combining_meta: Vec::new(),
            title_utf8: Vec::new(),
        }
    }

    pub fn write_bytes(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        if !bytes.contains(&0x1b) && !bytes.contains(&0x07) {
            self.terminal.advance_bytes(bytes);
            return;
        }
        let cols = self.terminal.screen().physical_cols.max(1);
        if self.scan_and_clamp_escape_sequences(bytes, cols) {
            let scratch = std::mem::take(&mut self.sanitize_scratch);
            self.terminal.advance_bytes(&scratch);
            self.sanitize_scratch = scratch;
        } else {
            self.terminal.advance_bytes(bytes);
        }
    }

    pub fn resize(&mut self, cols: u32, rows: u32, pixel_width: u32, pixel_height: u32) {
        let physical_cols = (cols as usize).max(1);
        let physical_rows = (rows as usize).max(1);
        self.config
            .physical_rows
            .store(physical_rows, Ordering::Relaxed);
        self.prevent_trailing_wrapped_line_drop_on_resize();
        self.terminal.resize(TerminalSize {
            rows: physical_rows,
            cols: physical_cols,
            pixel_width: pixel_width as usize,
            pixel_height: pixel_height as usize,
            dpi: 96,
        });
        self.resized_since_sync = true;
    }

    /// Before `Screen::resize` runs `rewrap_lines`, it pops trailing whitespace
    /// lines after the cursor. If the last surviving line still has
    /// `last_cell_was_wrapped() == true`, `rewrap_lines` holds it in
    /// `logical_line` waiting for a continuation line and drops it at loop end.
    fn prevent_trailing_wrapped_line_drop_on_resize(&mut self) {
        if self.terminal.is_alt_screen_active() {
            return;
        }
        let seqno = self.terminal.current_seqno();
        let cursor_y = self.terminal.cursor_pos().y;
        let screen = self.terminal.screen_mut();
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

    pub fn clear(&mut self) {
        self.write_bytes(
            b"\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1015l\
              \x1b[?2004l\x1b[?1l\x1b[?6l\x1b[?7h\x1b[?25h\x1b[r\x1b[0m\x1b[H\x1b[2J\x1b[3J",
        );
        self.terminal.erase_scrollback_and_viewport();
        let screen = self.terminal.screen();
        let physical_rows = screen.physical_rows.max(1);
        let physical_cols = screen.physical_cols.max(1);
        let reset_baseline = ScreenSyncBaseline {
            synced_seqno: 0,
            stable_offset: 0,
            total_lines: physical_rows,
            physical_rows,
            physical_cols,
        };
        self.primary_baseline = reset_baseline;
        self.alt_baseline = reset_baseline;
        self.last_alt_screen = false;
        self.saw_erase_scrollback = true;
        self.saw_erase_display = true;
    }

    /// Scans `bytes` for control / CSI / DEC private mode sequences that need
    /// sideband tracking, and returns `true` if `self.sanitize_scratch` holds a
    /// rewritten stream (used when an oversized CHT `CSI Ps I` or CBT `CSI Ps Z`
    /// repeat count must be clamped to `cols`).
    fn scan_and_clamp_escape_sequences(&mut self, bytes: &[u8], cols: usize) -> bool {
        let mut modified = false;
        let mut copied_up_to = 0usize;
        let len = bytes.len();
        let mut i = 0usize;
        let mut in_osc = false;

        while i < len {
            let b = bytes[i];
            if in_osc {
                if b == 0x07 {
                    in_osc = false;
                } else if b == 0x1b && i + 1 < len && bytes[i + 1] == b'\\' {
                    in_osc = false;
                    i += 2;
                    continue;
                }
                i += 1;
                continue;
            }

            if b == 0x07 {
                self.bell_rang = true;
                i += 1;
                continue;
            }

            if b != 0x1b {
                i += 1;
                continue;
            }

            if i + 1 >= len {
                break;
            }

            let next = bytes[i + 1];
            match next {
                b']' => {
                    in_osc = true;
                    i += 2;
                }
                b'=' => {
                    self.app_keypad = true;
                    i += 2;
                }
                b'>' => {
                    self.app_keypad = false;
                    i += 2;
                }
                b'c' => {
                    self.app_cursor_keys = false;
                    self.app_keypad = false;
                    self.origin_mode = false;
                    self.auto_wrap = true;
                    self.report_focus = false;
                    self.mouse_mode = 0;
                    self.mouse_report_mode = 0;
                    i += 2;
                }
                b'[' => {
                    let csi_start = i + 2;
                    let mut j = csi_start;
                    while j < len && (0x20..=0x3f).contains(&bytes[j]) {
                        j += 1;
                    }
                    if j >= len {
                        break;
                    }
                    let final_byte = bytes[j];
                    let params = &bytes[csi_start..j];
                    self.inspect_csi(params, final_byte);

                    if (final_byte == b'I' || final_byte == b'Z')
                        && !params.is_empty()
                        && params.iter().all(|c| c.is_ascii_digit())
                        && let Some(val) = parse_u32_ascii(params)
                        && (val as usize) > cols
                    {
                        if !modified {
                            self.sanitize_scratch.clear();
                            self.sanitize_scratch.reserve(len);
                            modified = true;
                        }
                        self.sanitize_scratch
                            .extend_from_slice(&bytes[copied_up_to..csi_start]);
                        let mut num_buf = [0u8; 16];
                        let num_len = write_usize_ascii(cols, &mut num_buf);
                        self.sanitize_scratch.extend_from_slice(&num_buf[..num_len]);
                        self.sanitize_scratch.push(final_byte);
                        copied_up_to = j + 1;
                    }
                    i = j + 1;
                }
                _ => {
                    i += 2;
                }
            }
        }

        if modified && copied_up_to < len {
            self.sanitize_scratch
                .extend_from_slice(&bytes[copied_up_to..]);
        }
        modified
    }

    fn inspect_csi(&mut self, params: &[u8], final_byte: u8) {
        match final_byte {
            b'J' => {
                for p in params.split(|&b| b == b';') {
                    let code = parse_u32_ascii(p).unwrap_or(0);
                    if code == 2 {
                        self.saw_erase_display = true;
                    } else if code == 3 {
                        self.saw_erase_scrollback = true;
                    }
                }
            }
            b'h' | b'l' if params.first() == Some(&b'?') => {
                let enabled = final_byte == b'h';
                for p in params[1..].split(|&b| b == b';') {
                    if let Some(code) = parse_u32_ascii(p) {
                        self.apply_dec_private_mode(code, enabled);
                    }
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
            66 => self.app_keypad = enabled,
            9 | 1000 => {
                self.mouse_mode = if enabled { 1 } else { 0 };
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
            _ => {}
        }
    }

    pub fn sync(&mut self) -> &TriageTermSyncHeader {
        let current_seqno = self.terminal.current_seqno();
        let is_alt = self.terminal.is_alt_screen_active();
        let alt_switched = is_alt != self.last_alt_screen;
        self.last_alt_screen = is_alt;

        let cursor = self.terminal.cursor_pos();
        let bracketed_paste = self.terminal.bracketed_paste_enabled();
        let title_changed = self.terminal.get_title() != self.last_title;
        if title_changed {
            self.last_title.clear();
            self.last_title.push_str(self.terminal.get_title());
            self.title_utf8.clear();
            self.title_utf8
                .extend_from_slice(self.last_title.as_bytes());
        }

        let screen = self.terminal.screen();
        let physical_rows = screen.physical_rows.max(1);
        let physical_cols = screen.physical_cols.max(1);
        let raw_total_lines = screen.scrollback_rows().max(physical_rows);
        let max_allowed = if is_alt {
            physical_rows
        } else {
            self.max_lines.max(physical_rows)
        };
        let phys_offset = raw_total_lines.saturating_sub(max_allowed);
        let total_lines = raw_total_lines - phys_offset;
        let current_stable = screen.phys_to_stable_row_index(phys_offset).max(0) as usize;

        let baseline = if is_alt {
            &mut self.alt_baseline
        } else {
            &mut self.primary_baseline
        };

        let force_all_dirty = alt_switched
            || baseline.synced_seqno == 0
            || physical_cols != baseline.physical_cols
            || (self.resized_since_sync && (is_alt || current_stable != baseline.stable_offset))
            || self.saw_erase_scrollback
            || self.saw_erase_display;

        let (explicit_trimmed_top, pushed_bottom) =
            if is_alt || self.resized_since_sync || baseline.synced_seqno == 0 {
                (0usize, 0usize)
            } else {
                let old_end = baseline.stable_offset + baseline.total_lines;
                let new_end = current_stable + total_lines;
                let pushed = new_end.saturating_sub(old_end);
                let explicit_trim = if self.saw_erase_scrollback {
                    if total_lines < max_allowed {
                        current_stable.saturating_sub(baseline.stable_offset)
                    } else {
                        baseline.total_lines.saturating_sub(baseline.physical_rows)
                    }
                } else {
                    0
                };
                (explicit_trim, pushed)
            };

        let prev_scrollback_after_trim = baseline
            .total_lines
            .saturating_sub(explicit_trimmed_top)
            .saturating_sub(baseline.physical_rows);
        let curr_scrollback = total_lines.saturating_sub(physical_rows);
        let dirty_tail_start = prev_scrollback_after_trim.min(curr_scrollback);
        let last_seqno = baseline.synced_seqno;

        self.dirty_line_meta.clear();
        self.cell_words.clear();
        self.combining_meta.clear();

        if force_all_dirty
            || self.resized_since_sync
            || current_seqno > last_seqno
            || self.saw_erase_scrollback
            || self.saw_erase_display
        {
            let mut dirty_idx = 0usize;
            let mut prev_line_wrapped = false;
            let mut prev_line_changed = false;
            screen.for_each_phys_line(|phys_idx, line| {
                let line_wrapped = line.last_cell_was_wrapped();
                let line_changed = line.changed_since(last_seqno);
                if phys_idx < phys_offset {
                    prev_line_wrapped = line_wrapped;
                    prev_line_changed = line_changed;
                    return;
                }
                let rel_idx = phys_idx - phys_offset;
                if rel_idx >= total_lines {
                    return;
                }
                let is_wrapped = rel_idx > 0 && prev_line_wrapped;
                let is_dirty = force_all_dirty
                    || rel_idx >= dirty_tail_start
                    || line_changed
                    || prev_line_changed;
                prev_line_wrapped = line_wrapped;
                prev_line_changed = line_changed;
                if !is_dirty {
                    return;
                }
                let has_combining = pack_line_cells(
                    line,
                    physical_cols,
                    dirty_idx,
                    &mut self.cell_words,
                    &mut self.combining_meta,
                );
                let mut line_flags = 0u32;
                if is_wrapped {
                    line_flags |= 1;
                }
                if has_combining {
                    line_flags |= 2;
                }
                self.dirty_line_meta.push(rel_idx as u32);
                self.dirty_line_meta.push(line_flags);
                dirty_idx += 1;
            });
        }

        baseline.synced_seqno = current_seqno;
        baseline.stable_offset = current_stable;
        baseline.total_lines = total_lines;
        baseline.physical_rows = physical_rows;
        baseline.physical_cols = physical_cols;

        let mut mode_flags = 0u32;
        if is_alt {
            mode_flags |= MODE_ALT_SCREEN;
        }
        if cursor.visibility == CursorVisibility::Visible {
            mode_flags |= MODE_CURSOR_VISIBLE;
        }
        if bracketed_paste {
            mode_flags |= MODE_BRACKETED_PASTE;
        }
        if self.app_cursor_keys {
            mode_flags |= MODE_APP_CURSOR_KEYS;
        }
        if self.app_keypad {
            mode_flags |= MODE_APP_KEYPAD;
        }
        if self.origin_mode {
            mode_flags |= MODE_ORIGIN;
        }
        if self.auto_wrap {
            mode_flags |= MODE_AUTO_WRAP;
        }
        if self.report_focus {
            mode_flags |= MODE_REPORT_FOCUS;
        }
        if self.saw_erase_scrollback {
            mode_flags |= MODE_SAW_ERASE_SCROLLBACK;
        }
        if self.saw_erase_display {
            mode_flags |= MODE_SAW_ERASE_DISPLAY;
        }
        if self.bell_rang {
            mode_flags |= MODE_BELL_RANG;
        }
        if title_changed {
            mode_flags |= MODE_TITLE_CHANGED;
        }

        self.resized_since_sync = false;
        self.saw_erase_scrollback = false;
        self.saw_erase_display = false;
        self.bell_rang = false;

        let cursor_style = match cursor.shape {
            CursorShape::Default => 0,
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

        self.sync_header = TriageTermSyncHeader {
            total_lines: total_lines as u32,
            physical_rows: physical_rows as u32,
            physical_cols: physical_cols as u32,
            cursor_x: clamped_cursor_x,
            cursor_y: clamped_cursor_y,
            cursor_style,
            mode_flags,
            mouse_mode: self.mouse_mode,
            mouse_report_mode: self.mouse_report_mode,
            explicit_trimmed_top: explicit_trimmed_top as u32,
            pushed_bottom: pushed_bottom as u32,
            dirty_line_count: (self.dirty_line_meta.len() / 2) as u32,
            cell_words_len: self.cell_words.len() as u32,
            combining_count: (self.combining_meta.len() / 3) as u32,
            title_utf8_len: self.title_utf8.len() as u32,
        };

        &self.sync_header
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
        acc = acc.saturating_mul(10).saturating_add((b - b'0') as u32);
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

#[inline]
fn encode_color(attr: ColorAttribute) -> u32 {
    match attr {
        ColorAttribute::Default => COLOR_NORMAL,
        ColorAttribute::PaletteIndex(idx) => {
            if idx < 16 {
                COLOR_NAMED | (idx as u32)
            } else {
                COLOR_PALETTE | (idx as u32)
            }
        }
        ColorAttribute::TrueColorWithDefaultFallback(srgba)
        | ColorAttribute::TrueColorWithPaletteFallback(srgba, _) => {
            let (r, g, b, _) = srgba.to_srgb_u8();
            COLOR_RGB | ((r as u32) << 16) | ((g as u32) << 8) | (b as u32)
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

fn pack_line_cells(
    line: &Line,
    physical_cols: usize,
    dirty_line_idx: usize,
    cell_words: &mut Vec<u32>,
    combining_meta: &mut Vec<u32>,
) -> bool {
    let base_offset = cell_words.len();
    let row_words = physical_cols * CELL_WORDS;
    cell_words.resize(base_offset + row_words, 0);

    // When `fill_range` erases an entire VecStorage row to default blanks,
    // `prune_trailing_blanks` in `wezterm-surface` leaves `line.len() == physical_cols`
    // if every cell is blank. Keep all words zeroed in that case so `getText()`
    // treats the erased row as empty rather than `physical_cols` spaces.
    let blank_attrs = CellAttributes::blank();
    if line.len() >= physical_cols && !line.last_cell_was_wrapped() {
        let all_default_blank = line
            .visible_cells()
            .all(|c| c.str() == " " && c.attrs() == &blank_attrs);
        if all_default_blank {
            return false;
        }
    }

    let mut has_combining = false;
    for cell in line.visible_cells() {
        let col = cell.cell_index();
        if col >= physical_cols {
            break;
        }
        let attrs = cell.attrs();
        let fg = encode_color(attrs.foreground());
        let bg = encode_color(attrs.background());
        let attr_flags = encode_attrs(attrs);
        let width = cell.width().clamp(1, 2) as u32;
        let text = cell.str();
        let mut chars = text.chars();
        let first_char = chars.next().unwrap_or(' ');
        let cp = (first_char as u32) & CONTENT_CODEPOINT_MASK;
        let content = cp | (width << CONTENT_WIDTH_SHIFT);

        let word_idx = base_offset + col * CELL_WORDS;
        cell_words[word_idx] = fg;
        cell_words[word_idx + 1] = bg;
        cell_words[word_idx + 2] = attr_flags;
        cell_words[word_idx + 3] = content;

        if width == 2 && col + 1 < physical_cols {
            let trail_idx = base_offset + (col + 1) * CELL_WORDS;
            cell_words[trail_idx] = fg;
            cell_words[trail_idx + 1] = bg;
            cell_words[trail_idx + 2] = attr_flags;
            cell_words[trail_idx + 3] = 0;
        }

        for extra in chars {
            has_combining = true;
            combining_meta.push(dirty_line_idx as u32);
            combining_meta.push(col as u32);
            combining_meta.push(extra as u32);
        }
    }
    has_combining
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn triage_term_new(
    cols: u32,
    rows: u32,
    max_lines: u32,
) -> *mut TriageTermEngine {
    Box::into_raw(Box::new(TriageTermEngine::new(cols, rows, max_lines)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn triage_term_free(engine: *mut TriageTermEngine) {
    if !engine.is_null() {
        unsafe {
            drop(Box::from_raw(engine));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn triage_term_write(
    engine: *mut TriageTermEngine,
    data: *const u8,
    len: usize,
) {
    if engine.is_null() || (data.is_null() && len > 0) {
        return;
    }
    let engine = unsafe { &mut *engine };
    let bytes = if len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(data, len) }
    };
    engine.write_bytes(bytes);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn triage_term_resize(
    engine: *mut TriageTermEngine,
    cols: u32,
    rows: u32,
    pixel_width: u32,
    pixel_height: u32,
) {
    if engine.is_null() {
        return;
    }
    let engine = unsafe { &mut *engine };
    engine.resize(cols, rows, pixel_width, pixel_height);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn triage_term_clear(engine: *mut TriageTermEngine) {
    if engine.is_null() {
        return;
    }
    let engine = unsafe { &mut *engine };
    engine.clear();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn triage_term_sync(
    engine: *mut TriageTermEngine,
) -> *const TriageTermSyncHeader {
    if engine.is_null() {
        return std::ptr::null();
    }
    let engine = unsafe { &mut *engine };
    engine.sync() as *const TriageTermSyncHeader
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn triage_term_dirty_line_meta_ptr(
    engine: *const TriageTermEngine,
) -> *const u32 {
    if engine.is_null() {
        return std::ptr::null();
    }
    let engine = unsafe { &*engine };
    engine.dirty_line_meta.as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn triage_term_cell_words_ptr(engine: *const TriageTermEngine) -> *const u32 {
    if engine.is_null() {
        return std::ptr::null();
    }
    let engine = unsafe { &*engine };
    engine.cell_words.as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn triage_term_combining_meta_ptr(
    engine: *const TriageTermEngine,
) -> *const u32 {
    if engine.is_null() {
        return std::ptr::null();
    }
    let engine = unsafe { &*engine };
    engine.combining_meta.as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn triage_term_title_utf8_ptr(engine: *const TriageTermEngine) -> *const u8 {
    if engine.is_null() {
        return std::ptr::null();
    }
    let engine = unsafe { &*engine };
    engine.title_utf8.as_ptr()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_sgr_and_cell_packing() {
        let mut engine = TriageTermEngine::new(20, 5, 100);
        engine.write_bytes(b"\x1b[1;31;48;2;10;20;30mHi\x1b[0m");
        let header = *engine.sync();
        assert_eq!(header.total_lines, 5);
        assert_eq!(header.cursor_x, 2);
        assert_eq!(header.cursor_y, 0);
        assert!(header.dirty_line_count >= 1);

        // Cell 0 ('H'): bold, named red (1), RGB(10, 20, 30)
        assert_eq!(engine.cell_words[0], COLOR_NAMED | 1);
        assert_eq!(
            engine.cell_words[1],
            COLOR_RGB | (10 << 16) | (20 << 8) | 30
        );
        assert_eq!(engine.cell_words[2], ATTR_BOLD);
        assert_eq!(
            engine.cell_words[3],
            (b'H' as u32) | (1 << CONTENT_WIDTH_SHIFT)
        );

        // Unwritten cell 2 has codepoint 0
        assert_eq!(engine.cell_words[2 * CELL_WORDS + 3], 0);
    }

    #[test]
    fn wide_glyph_and_reflow_wrapping() {
        let mut engine = TriageTermEngine::new(10, 6, 100);
        engine.write_bytes(b"ABCDEFGHIJKLMNOP");
        let h1 = *engine.sync();
        assert_eq!(h1.total_lines, 6);
        // Row 0 is not wrapped; row 1 IS a continuation row (`is_wrapped == 1`).
        assert_eq!(engine.dirty_line_meta[0], 0);
        assert_eq!(engine.dirty_line_meta[1], 0);
        assert_eq!(engine.dirty_line_meta[2], 1);
        assert_eq!(engine.dirty_line_meta[3], 1);

        // Widen to 20 columns: soft-wrapped rows rejoin onto row 0.
        engine.resize(20, 6, 0, 0);
        let h2 = *engine.sync();
        assert_eq!(h2.physical_cols, 20);
        assert_eq!(engine.dirty_line_meta[3], 0);
        assert_eq!(
            engine.cell_words[15 * CELL_WORDS + 3],
            (b'P' as u32) | (1 << CONTENT_WIDTH_SHIFT)
        );
    }

    #[test]
    fn scrollback_clear_reports_explicit_trimmed_top() {
        let mut engine = TriageTermEngine::new(20, 5, 100);
        let _ = engine.sync();
        for i in 0..20 {
            engine.write_bytes(format!("line {i}\r\n").as_bytes());
        }
        let h1 = *engine.sync();
        assert_eq!(h1.total_lines, 21);
        assert_eq!(h1.pushed_bottom, 16);
        assert_eq!(h1.explicit_trimmed_top, 0);

        engine.write_bytes(b"\x1b[3J");
        let h2 = *engine.sync();
        assert_eq!(h2.total_lines, 5);
        assert_eq!(h2.explicit_trimmed_top, 16);
        assert_eq!(h2.pushed_bottom, 0);
        assert_ne!(h2.mode_flags & MODE_SAW_ERASE_SCROLLBACK, 0);
    }

    #[test]
    fn oversized_cht_clamps_to_viewport_width() {
        let mut engine = TriageTermEngine::new(40, 4, 100);
        engine.write_bytes(b"ab\x1b[2Icd");
        let h1 = *engine.sync();
        assert_eq!(h1.cursor_x, 18);

        engine.write_bytes(b"\r\x1b[999999I");
        let h2 = *engine.sync();
        assert_eq!(h2.cursor_x, 39);
    }

    #[test]
    fn narrow_resize_at_scrollback_capacity_clamps_total_lines() {
        let mut engine = TriageTermEngine::new(40, 5, 20);
        for i in 0..25 {
            engine.write_bytes(format!("row-{i:02}-01234567890123456789012345\r\n").as_bytes());
        }
        let h1 = *engine.sync();
        assert_eq!(h1.total_lines, 20);

        // Narrowing from 40 to 10 cols wraps each 33-char line into 4 physical rows,
        // expanding `Screen::lines` past `max_lines` (20). `sync()` must clamp
        // `total_lines` to `max_lines` so the Dart circular buffer never overflows.
        engine.resize(10, 5, 0, 0);
        let h2 = *engine.sync();
        assert_eq!(h2.total_lines, 20);
        assert_eq!(h2.dirty_line_count, 20);

        // Subsequent scrolling continues to report accurate `pushed_bottom`.
        engine.write_bytes(b"tail\r\n");
        let h3 = *engine.sync();
        assert_eq!(h3.total_lines, 20);
        assert_eq!(h3.pushed_bottom, 1);
    }

    #[test]
    fn clear_exits_alt_screen_and_resets_modes() {
        let mut engine = TriageTermEngine::new(20, 5, 50);
        engine.write_bytes(b"\x1b[?1049h\x1b[?1002h\x1b[?1006hAlt text");
        let h1 = *engine.sync();
        assert_ne!(h1.mode_flags & MODE_ALT_SCREEN, 0);
        assert_eq!(h1.mouse_mode, 3);
        assert_eq!(h1.mouse_report_mode, 2);

        engine.clear();
        let h2 = *engine.sync();
        assert_eq!(h2.mode_flags & MODE_ALT_SCREEN, 0);
        assert_eq!(h2.mouse_mode, 0);
        assert_eq!(h2.total_lines, 5);
    }

    #[test]
    fn alt_screen_height_shrink_clamps_total_lines_to_physical_rows() {
        let mut engine = TriageTermEngine::new(80, 24, 1000);
        engine.write_bytes(b"\x1b[?1049h\x1b[1;1HHeader\x1b[24;1HStatusBar\x1b[1;1H");
        let h1 = *engine.sync();
        assert_ne!(h1.mode_flags & MODE_ALT_SCREEN, 0);
        assert_eq!(h1.total_lines, 24);

        // Shrinking the alternate screen height when row 24 is non-whitespace
        // must still report `total_lines == physical_rows` (15), never 24.
        engine.resize(44, 15, 0, 0);
        let h2 = *engine.sync();
        assert_eq!(h2.physical_rows, 15);
        assert_eq!(h2.total_lines, 15);
        assert_eq!(h2.dirty_line_count, 15);
    }

    #[test]
    fn height_only_resize_on_primary_screen_syncs_only_viewport_tail() {
        let mut engine = TriageTermEngine::new(44, 30, 1000);
        for i in 0..1000 {
            engine.write_bytes(format!("line-{i:04}\r\n").as_bytes());
        }
        let h1 = *engine.sync();
        assert_eq!(h1.total_lines, 1000);

        // Height-only resize (such as an Android IME keyboard frame) should only
        // sync the viewport tail rather than repacking all 1,000 scrollback lines.
        engine.resize(44, 15, 0, 0);
        let h2 = *engine.sync();
        assert!(
            h2.dirty_line_count <= 30,
            "dirty_line_count={}",
            h2.dirty_line_count
        );
    }
}
