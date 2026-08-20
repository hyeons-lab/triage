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
}
