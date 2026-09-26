//! Free/total disk space for the filesystem holding the daemon's state.
//!
//! Surfaced to remote clients through the `hello` handshake so the daemon
//! selector can show remaining space. Best-effort: any failure (unprobed
//! platform, missing home, failed syscall) yields `None`, and the client
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

    let c_path = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) } != 0 {
        return None;
    }
    stats_from_statvfs(&stat)
}

/// Converts a `statvfs` result into bytes. Split from the syscall so the
/// arithmetic (including the zero-`f_frsize` fallback) is unit-testable
/// without a filesystem that produces one.
#[cfg(unix)]
// The `as u64` casts below are each a no-op on exactly one of Linux/macOS
// (the field widths differ per platform); the widening cast is what compiles
// on both, so the lint is wrong on whichever platform it fires on.
#[allow(clippy::unnecessary_cast)]
fn stats_from_statvfs(stat: &libc::statvfs) -> Option<DiskStats> {
    // `f_frsize` can read 0 on some kernels and network mounts; fall back
    // to `f_bsize` rather than pricing every block at one byte. Both zero
    // means no usable block size at all: report unknown rather than
    // fabricating byte counts at an invented 1 byte/block.
    let frsize = if stat.f_frsize > 0 {
        stat.f_frsize
    } else if stat.f_bsize > 0 {
        stat.f_bsize
    } else {
        return None;
    };
    let block = frsize as u64;
    let total_bytes = (stat.f_blocks as u64).saturating_mul(block);
    // `f_bavail` (unprivileged-available), not `f_bfree`: the reserved
    // root blocks are not free space the daemon can use.
    let free_bytes = (stat.f_bavail as u64).saturating_mul(block);
    disk_stats_from_bytes(free_bytes, total_bytes)
}

/// Assembles a reading from raw byte counts. Zero total means the probe
/// produced nothing usable: report unknown rather than a bogus zero.
/// Free clamps to total: callers treat free above total as corrupt.
#[cfg(any(unix, windows))]
fn disk_stats_from_bytes(free_bytes: u64, total_bytes: u64) -> Option<DiskStats> {
    if total_bytes == 0 {
        return None;
    }
    Some(DiskStats {
        free_bytes: free_bytes.min(total_bytes),
        total_bytes,
    })
}

#[cfg(windows)]
#[allow(unsafe_code)]
fn filesystem_stats(path: &std::path::Path) -> Option<DiskStats> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;

    let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
    wide.push(0);
    let mut free_bytes: u64 = 0;
    let mut total_bytes: u64 = 0;
    // SAFETY: `wide` is nul-terminated; the out-params are valid `u64` slots.
    let ok = unsafe {
        GetDiskFreeSpaceExW(
            wide.as_ptr(),
            &mut free_bytes,
            &mut total_bytes,
            std::ptr::null_mut(),
        )
    };
    if ok == 0 {
        return None;
    }
    // Caller-available bytes (quota-aware), not total free: blocks the
    // daemon cannot use are not free space it can use. Mirrors `f_bavail`.
    disk_stats_from_bytes(free_bytes, total_bytes)
}

#[cfg(not(any(unix, windows)))]
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

    #[cfg(windows)]
    #[test]
    fn daemon_disk_stats_reports_a_usable_volume() {
        let stats = daemon_disk_stats().expect("GetDiskFreeSpaceExW should succeed on windows");
        assert!(stats.total_bytes > 0);
        assert!(stats.free_bytes <= stats.total_bytes);
    }

    #[cfg(not(any(unix, windows)))]
    #[test]
    fn daemon_disk_stats_is_unknown_off_unix() {
        assert_eq!(daemon_disk_stats(), None);
    }

    #[cfg(any(unix, windows))]
    #[test]
    fn from_bytes_rejects_zero_total_and_clamps_free() {
        assert_eq!(disk_stats_from_bytes(0, 0), None);
        assert_eq!(
            disk_stats_from_bytes(200, 100),
            Some(DiskStats {
                free_bytes: 100,
                total_bytes: 100,
            })
        );
        assert_eq!(
            disk_stats_from_bytes(25, 100),
            Some(DiskStats {
                free_bytes: 25,
                total_bytes: 100,
            })
        );
    }

    #[test]
    fn missing_path_reports_unknown() {
        let missing = std::path::PathBuf::from("definitely-not-a-real-triage-dir-000154");
        assert_eq!(filesystem_stats(&missing), None);
    }

    #[cfg(unix)]
    #[allow(unsafe_code)]
    #[test]
    fn zero_frsize_falls_back_to_bsize() {
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        stat.f_frsize = 0;
        stat.f_bsize = 4096;
        stat.f_blocks = 100;
        stat.f_bavail = 25;
        assert_eq!(
            stats_from_statvfs(&stat),
            Some(DiskStats {
                free_bytes: 25 * 4096,
                total_bytes: 100 * 4096,
            })
        );
    }

    #[cfg(unix)]
    #[allow(unsafe_code)]
    #[test]
    fn double_zero_block_size_reports_unknown() {
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        stat.f_frsize = 0;
        stat.f_bsize = 0;
        stat.f_blocks = 100;
        stat.f_bavail = 25;
        assert_eq!(stats_from_statvfs(&stat), None);
    }

    #[cfg(unix)]
    #[allow(unsafe_code)]
    #[test]
    fn zero_blocks_reports_unknown() {
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        stat.f_frsize = 4096;
        stat.f_bsize = 4096;
        stat.f_blocks = 0;
        stat.f_bavail = 0;
        assert_eq!(stats_from_statvfs(&stat), None);
    }

    #[cfg(unix)]
    #[allow(unsafe_code)]
    #[test]
    fn free_clamps_to_total() {
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        stat.f_frsize = 4096;
        stat.f_bsize = 4096;
        stat.f_blocks = 100;
        stat.f_bavail = 150;
        assert_eq!(
            stats_from_statvfs(&stat),
            Some(DiskStats {
                free_bytes: 100 * 4096,
                total_bytes: 100 * 4096,
            })
        );
    }
}
