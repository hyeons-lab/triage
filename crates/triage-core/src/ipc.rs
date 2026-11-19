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
    let bare = raw
        .strip_prefix(r"\\.\pipe\")
        .or_else(|| raw.strip_prefix(r"\\?\pipe\"))
        .unwrap_or(raw);
    Ok(bare
        .chars()
        .map(|c| match c {
            '\\' | '/' | ':' => '_',
            other => other,
        })
        .collect())
}

/// Resolves a socket/pipe path to a `\\.\pipe\<token>` Windows named-pipe
/// endpoint without hashing/truncating, rejecting tokens over
/// [`MAX_WINDOWS_PIPE_TOKEN_LEN`] UTF-16 code units.
pub fn windows_pipe_endpoint(path: &std::path::Path) -> std::io::Result<String> {
    let token = windows_pipe_token_raw(path)?;
    if token.is_empty() || token.encode_utf16().count() > MAX_WINDOWS_PIPE_TOKEN_LEN {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "named pipe token is empty or exceeds length limit",
        ));
    }
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
            windows_pipe_endpoint(std::path::Path::new(r"\\?\pipe\triage-alice")).unwrap(),
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
    }
}
