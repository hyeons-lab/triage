//! Snapshot helpers for renderer-style golden tests.

/// Build a deterministic multi-line frame for golden snapshot assertions.
pub fn frame(lines: impl IntoIterator<Item = impl AsRef<str>>) -> String {
    let mut out = String::new();
    for (index, line) in lines.into_iter().enumerate() {
        if index > 0 {
            out.push('\n');
        }
        out.push_str(line.as_ref());
    }
    normalize_text(&out)
}

/// Normalize platform-specific and terminal-originated newlines.
pub fn normalize_text(input: &str) -> String {
    input.replace("\r\n", "\n").replace('\r', "\n")
}
