//! Free/total disk space for the filesystem holding the daemon's state.
//!
//! Surfaced to remote clients through the `hello` handshake so the daemon
//! selector can show remaining space. Best-effort: any failure (unknown
//! platform, missing home, failed `statvfs`) yields `None`, and the client
//! hides the line rather than showing a bogus number.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DiskStats {
    pub free_bytes: u64,
    pub total_bytes: u64,
}

/// Free/total bytes for the volume holding `$HOME/.local/state/triage`.
///
/// Probes the state dir first, then `$HOME`, then the process working
/// directory: the state dir may not exist yet on a fresh install, and the
/// home lookup may fail under an unusual service account. All three
/// normally sit on one volume, so any successful probe answers the same
/// question.
pub fn daemon_disk_stats() -> Option<DiskStats> {
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if let Some(home) = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(std::path::PathBuf::from)
    {
        candidates.push(home.join(".local/state/triage"));
        candidates.push(home);
    }
    candidates.push(std::path::PathBuf::from("."));
    candidates.iter().find_map(|p| filesystem_stats(p))
}

#[cfg(unix)]
#[allow(unsafe_code)]
fn filesystem_stats(path: &std::path::Path) -> Option<DiskStats> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    // `as u64` (not `u64::from`): these fields are u64 on Linux but u32 on
    // macOS, and the widening cast compiles on both.
    let c_path = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) } != 0 {
        return None;
    }
    let block = (stat.f_frsize as u64).max(1);
    let total_bytes = (stat.f_blocks as u64).saturating_mul(block);
    // `f_bavail` (unprivileged-available), not `f_bfree`: the reserved
    // root blocks are not free space the daemon can use.
    let free_bytes = (stat.f_bavail as u64).saturating_mul(block);
    if total_bytes == 0 {
        return None;
    }
    Some(DiskStats {
        free_bytes: free_bytes.min(total_bytes),
        total_bytes,
    })
}

#[cfg(not(unix))]
fn filesystem_stats(_path: &std::path::Path) -> Option<DiskStats> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn daemon_disk_stats_reports_a_usable_volume() {
        let stats = daemon_disk_stats().expect("statvfs should succeed on unix");
        assert!(stats.total_bytes > 0);
        assert!(stats.free_bytes <= stats.total_bytes);
    }

    #[cfg(not(unix))]
    #[test]
    fn daemon_disk_stats_is_unknown_off_unix() {
        assert_eq!(daemon_disk_stats(), None);
    }

    #[test]
    fn missing_path_reports_unknown() {
        let missing = std::path::PathBuf::from("definitely-not-a-real-triage-dir-000154");
        assert_eq!(filesystem_stats(&missing), None);
    }
}
