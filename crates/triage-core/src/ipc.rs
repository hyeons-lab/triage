//! Shared IPC path resolution and common definitions.

use std::path::PathBuf;

#[cfg(unix)]
pub fn default_socket_path() -> PathBuf {
    if let Some(runtime_dir) = std::env::var_os("XDG_RUNTIME_DIR")
        && !runtime_dir.is_empty()
    {
        use std::os::unix::fs::DirBuilderExt;
        let dir = PathBuf::from(runtime_dir).join("triage");
        if std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .is_ok()
        {
            return dir.join("triage.sock");
        }
    }

    let dir = std::env::temp_dir().join(format!("triage-{}", fallback_user_component()));
    #[cfg(target_family = "unix")]
    {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt};
        let _ = std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir);
        if let Ok(meta) = std::fs::symlink_metadata(&dir)
            && (meta.file_type().is_symlink() || meta.uid() != current_uid())
            && let Some(home) = std::env::var_os("HOME").map(PathBuf::from)
        {
            let state_dir = home.join(".local/state/triage");
            let _ = std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&state_dir);
            return state_dir.join("triage.sock");
        }
    }
    dir.join("triage.sock")
}

#[cfg(windows)]
pub fn default_socket_path() -> PathBuf {
    PathBuf::from(format!(r"\\.\pipe\triage-{}", fallback_user_component()))
}

/// Maximum length, in UTF-16 code units, for a Windows named-pipe token. NPFS
/// caps the full `\\.\pipe\<token>` path at 256 units; this leaves margin for
/// the 9-unit `\\.\pipe\` prefix.
pub const MAX_WINDOWS_PIPE_TOKEN_LEN: usize = 210;

/// Normalizes a socket or pipe path into its bare Windows named-pipe token
/// (stripping any `\\.\pipe\` / `\\?\pipe\` prefix and collapsing separators).
pub fn windows_pipe_token_raw(path: &std::path::Path) -> std::io::Result<String> {
    let raw = path.to_str().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "named pipe name is not valid UTF-8",
        )
    })?;
    let bare = if raw.as_bytes().get(..9).is_some_and(|prefix| {
        prefix.eq_ignore_ascii_case(br"\\.\pipe\") || prefix.eq_ignore_ascii_case(br"\\?\pipe\")
    }) {
        &raw[9..]
    } else {
        raw
    };
    Ok(bare
        .chars()
        .map(|c| match c {
            '\\' | '/' | ':' => '_',
            other => other,
        })
        .collect())
}

/// Truncate `s` to at most `max_units` UTF-16 code units, stopping on a `char`
/// boundary so a surrogate pair is never split.
fn truncate_utf16_units(s: &str, max_units: usize) -> String {
    let mut out = String::new();
    let mut units = 0usize;
    for c in s.chars() {
        let w = c.len_utf16();
        if units + w > max_units {
            break;
        }
        out.push(c);
        units += w;
    }
    out
}

/// Deterministic 64-bit FNV-1a digest so overlong pipe tokens remain identical
/// across `triaged` and `triage-hook` without pulling hashing crates into the
/// lightweight hook shim.
fn fnv1a_64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &byte in bytes {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

/// Returns the bounded `<token>` component for a Windows named pipe
/// (`\\.\pipe\<token>`), rejecting empty paths and deterministically hashing
/// tokens over [`MAX_WINDOWS_PIPE_TOKEN_LEN`] UTF-16 code units.
pub fn windows_pipe_token(path: &std::path::Path) -> std::io::Result<String> {
    let collapsed = windows_pipe_token_raw(path)?;
    if collapsed.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "named pipe token is empty",
        ));
    }
    if collapsed.encode_utf16().count() <= MAX_WINDOWS_PIPE_TOKEN_LEN {
        return Ok(collapsed);
    }
    // 16 hex chars (ASCII -> 16 units) + one `_` separator = 17 units.
    let hash = fnv1a_64(collapsed.as_bytes());
    let prefix = truncate_utf16_units(&collapsed, MAX_WINDOWS_PIPE_TOKEN_LEN - 17);
    Ok(format!("{prefix}_{hash:016x}"))
}

/// Resolves a socket/pipe path to a `\\.\pipe\<token>` Windows named-pipe
/// endpoint bounded to NPFS limits.
pub fn windows_pipe_endpoint(path: &std::path::Path) -> std::io::Result<String> {
    let token = windows_pipe_token(path)?;
    Ok(format!(r"\\.\pipe\{token}"))
}

#[cfg(not(any(unix, windows)))]
pub fn default_socket_path() -> PathBuf {
    std::env::temp_dir()
        .join(format!("triage-{}", fallback_user_component()))
        .join("triage.sock")
}

fn fallback_user_component() -> String {
    user_identifier()
        .map(sanitize_path_component)
        .unwrap_or_else(|| format!("pid-{}", std::process::id()))
}

#[cfg(unix)]
#[allow(unsafe_code)]
fn current_uid() -> u32 {
    // libc::getuid() is always safe to invoke on Unix platforms.
    unsafe { libc::getuid() }
}

#[cfg(unix)]
#[allow(unsafe_code)]
fn user_identifier() -> Option<String> {
    Some(current_uid().to_string())
}

#[cfg(windows)]
fn user_identifier() -> Option<String> {
    std::env::var("USERNAME").ok()
}

#[cfg(not(any(unix, windows)))]
fn user_identifier() -> Option<String> {
    std::env::var("USER").ok()
}

fn sanitize_path_component(value: String) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_') {
                character
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_socket_path_is_non_empty_and_valid() {
        let path = default_socket_path();
        assert!(!path.as_os_str().is_empty());
        #[cfg(unix)]
        {
            assert!(path.ends_with("triage.sock"));
        }
    }

    #[test]
    fn sanitize_path_component_replaces_illegal_characters() {
        assert_eq!(sanitize_path_component("user:123".to_string()), "user_123");
        assert_eq!(
            sanitize_path_component("user/name".to_string()),
            "user_name"
        );
        assert_eq!(
            sanitize_path_component("valid-user_01".to_string()),
            "valid-user_01"
        );
    }

    #[test]
    fn windows_pipe_endpoint_normalizes_prefixes_and_separators() {
        assert_eq!(
            windows_pipe_endpoint(std::path::Path::new(r"\\.\pipe\triage-alice")).unwrap(),
            r"\\.\pipe\triage-alice"
        );
        assert_eq!(
            windows_pipe_endpoint(std::path::Path::new(r"\\.\PIPE\triage-alice")).unwrap(),
            r"\\.\pipe\triage-alice"
        );
        assert_eq!(
            windows_pipe_endpoint(std::path::Path::new(r"\\?\pipe\triage-alice")).unwrap(),
            r"\\.\pipe\triage-alice"
        );
        assert_eq!(
            windows_pipe_endpoint(std::path::Path::new(r"\\?\PiPe\triage-alice")).unwrap(),
            r"\\.\pipe\triage-alice"
        );
        assert_eq!(
            windows_pipe_endpoint(std::path::Path::new("triage-alice")).unwrap(),
            r"\\.\pipe\triage-alice"
        );
        assert_eq!(
            windows_pipe_endpoint(std::path::Path::new(r"C:\tmp\triage.sock")).unwrap(),
            r"\\.\pipe\C__tmp_triage.sock"
        );
        assert!(windows_pipe_endpoint(std::path::Path::new("")).is_err());

        let long_a = format!(r"\\.\pipe\{}", "a".repeat(400));
        let long_b = format!(r"\\.\pipe\{}", "b".repeat(400));
        let ep_a = windows_pipe_endpoint(std::path::Path::new(&long_a)).unwrap();
        let ep_b = windows_pipe_endpoint(std::path::Path::new(&long_b)).unwrap();
        assert_eq!(
            ep_a,
            windows_pipe_endpoint(std::path::Path::new(&long_a)).unwrap()
        );
        assert_ne!(ep_a, ep_b);
        assert!(
            ep_a.strip_prefix(r"\\.\pipe\")
                .unwrap()
                .encode_utf16()
                .count()
                <= MAX_WINDOWS_PIPE_TOKEN_LEN
        );

        let astral = format!(r"\\.\pipe\{}", "🦀".repeat(400));
        let ep_astral = windows_pipe_endpoint(std::path::Path::new(&astral)).unwrap();
        assert!(
            ep_astral
                .strip_prefix(r"\\.\pipe\")
                .unwrap()
                .encode_utf16()
                .count()
                <= MAX_WINDOWS_PIPE_TOKEN_LEN
        );
    }
}
