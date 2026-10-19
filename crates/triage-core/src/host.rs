//! Host CPU and battery readings for the daemon selector.
//!
//! Surfaced to remote clients through `getDaemonStats` (and the `hello`
//! handshake) so the rail can show whether the machine is pegged or about
//! to die. Best-effort like [`crate::disk`]: any failure (unprobed
//! platform, missing battery, failed syscall) yields `None`, and the
//! client hides the segment rather than showing a bogus number.
//!
//! CPU percent comes from cumulative tick deltas (macOS Mach CPU load
//! info, Linux `/proc/stat`, Windows `GetSystemTimes`), so the first poll
//! in a process only seeds the sampler and reports unknown. Battery state
//! is point-in-time (macOS `pmset`, Linux sysfs, Windows
//! `GetSystemPowerStatus`).

use std::sync::{Mutex, OnceLock};

/// Battery charge state. Desktops (no battery) never produce one.
/// Serializes lowercase for the JSON protocol (`"charging"`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BatteryState {
    Charging,
    Discharging,
    Full,
    #[default]
    #[serde(other)]
    Unknown,
}

/// Point-in-time battery reading. `percent` is 0-100.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BatteryStatus {
    pub percent: u8,
    pub state: BatteryState,
}

/// Host readings. Each leg is independent: CPU may be known while battery
/// is absent (a pegged desktop) and vice versa.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HostStats {
    pub cpu_percent: Option<u8>,
    pub battery: Option<BatteryStatus>,
}

/// Current host readings. CPU is `None` on the first call in a process
/// (the sampler needs two ticks to form a delta); battery is `None` when
/// the machine has no battery or the probe fails.
pub fn daemon_host_stats() -> HostStats {
    HostStats {
        cpu_percent: cpu_percent(),
        battery: battery_status(),
    }
}

/// Cumulative CPU ticks, normalized per platform so the delta math is
/// shared. `busy_ticks` must never exceed `total_ticks`; the percent
/// calculation clamps defensively anyway.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CpuSample {
    busy_ticks: u64,
    total_ticks: u64,
}

/// Whole-percent CPU busy between two cumulative samples. `None` when the
/// counters did not advance (back-to-back samples) or wrapped: no delta,
/// no reading, rather than a bogus 0 or 100.
fn cpu_percent_between(before: CpuSample, after: CpuSample) -> Option<u8> {
    let busy = after.busy_ticks.checked_sub(before.busy_ticks)?;
    let total = after.total_ticks.checked_sub(before.total_ticks)?;
    if total == 0 {
        return None;
    }
    let busy = busy.min(total);
    u8::try_from(busy.saturating_mul(100) / total).ok()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CpuSamplerState {
    sample: CpuSample,
    last_percent: Option<u8>,
}

fn advance_cpu_sampler(state: &mut Option<CpuSamplerState>, now: CpuSample) -> Option<u8> {
    match *state {
        None => {
            *state = Some(CpuSamplerState {
                sample: now,
                last_percent: None,
            });
            None
        }
        Some(prev) if prev.sample.total_ticks == now.total_ticks => {
            // Two callers landed in the same OS tick: keep the prior baseline
            // and return the last reading rather than wiping it to None.
            prev.last_percent
        }
        Some(prev) => {
            let next_percent = cpu_percent_between(prev.sample, now);
            *state = Some(CpuSamplerState {
                sample: now,
                last_percent: next_percent,
            });
            next_percent
        }
    }
}

static LAST_CPU_SAMPLE: OnceLock<Mutex<Option<CpuSamplerState>>> = OnceLock::new();

fn cpu_percent() -> Option<u8> {
    let now = sample_cpu_ticks()?;
    let slot = LAST_CPU_SAMPLE.get_or_init(|| Mutex::new(None));
    let mut guard = slot.lock().ok()?;
    advance_cpu_sampler(&mut guard, now)
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
fn sample_cpu_ticks() -> Option<CpuSample> {
    // `kern.cp_time` is gone on modern macOS; the Mach CPU load info is
    // the cumulative-ticks source. Hand-declared: libc carries no Mach
    // host APIs.
    const HOST_CPU_LOAD_INFO: i32 = 3;
    const CPU_STATE_MAX: usize = 4;
    const KERN_SUCCESS: i32 = 0;

    #[link(name = "System")]
    unsafe extern "C" {
        fn mach_host_self() -> u32;
        fn host_statistics64(host: u32, flavor: i32, info: *mut u32, count: *mut u32) -> i32;
    }

    // SAFETY: `mach_host_self` is a Mach trap that grants a send-right user
    // reference on each call; caching the port in `OnceLock` acquires one
    // send right for the lifetime of the process. `host_statistics64` writes
    // at most `CPU_STATE_MAX` unsigned 32-bit `natural_t` counters into the
    // caller buffer when `count` starts at its capacity.
    static HOST_PORT: OnceLock<u32> = OnceLock::new();
    let host = *HOST_PORT.get_or_init(|| unsafe { mach_host_self() });
    let mut ticks = [0u32; CPU_STATE_MAX];
    let mut count = CPU_STATE_MAX as u32;
    let result =
        unsafe { host_statistics64(host, HOST_CPU_LOAD_INFO, ticks.as_mut_ptr(), &mut count) };
    if result != KERN_SUCCESS || count as usize != CPU_STATE_MAX {
        return None;
    }
    Some(cpu_sample_from_mach_ticks(ticks))
}

#[cfg(any(target_os = "macos", test))]
fn cpu_sample_from_mach_ticks(ticks: [u32; 4]) -> CpuSample {
    const CPU_STATE_USER: usize = 0;
    const CPU_STATE_SYSTEM: usize = 1;
    const CPU_STATE_IDLE: usize = 2;
    const CPU_STATE_NICE: usize = 3;

    let tick = |index: usize| u64::from(ticks[index]);
    let idle = tick(CPU_STATE_IDLE);
    let total = tick(CPU_STATE_USER) + tick(CPU_STATE_SYSTEM) + idle + tick(CPU_STATE_NICE);
    CpuSample {
        busy_ticks: total.saturating_sub(idle),
        total_ticks: total,
    }
}

/// Parses the aggregate `cpu` line of `/proc/stat` into cumulative ticks.
/// Split from the file read so the field mapping is unit-testable.
#[cfg(target_os = "linux")]
fn sample_cpu_ticks() -> Option<CpuSample> {
    let text = std::fs::read_to_string("/proc/stat").ok()?;
    parse_proc_stat_cpu(&text)
}

#[cfg(any(target_os = "linux", test))]
fn parse_proc_stat_cpu(text: &str) -> Option<CpuSample> {
    let mut fields = text.lines().next()?.split_whitespace();
    if fields.next()? != "cpu" {
        return None;
    }
    let numbers: Vec<u64> = fields.map(|field| field.parse().unwrap_or(0)).collect();
    // user nice system idle iowait irq softirq [steal guest guest_nice].
    // Guest times are already included in user/nice; the first eight are
    // the standard total, and iowait counts as idle (the CPU is not busy).
    if numbers.len() < 4 {
        return None;
    }
    let idle = numbers[3] + numbers.get(4).copied().unwrap_or(0);
    let total: u64 = numbers.iter().take(8).sum();
    Some(CpuSample {
        busy_ticks: total.saturating_sub(idle),
        total_ticks: total,
    })
}

#[cfg(windows)]
#[allow(unsafe_code)]
fn sample_cpu_ticks() -> Option<CpuSample> {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::GetSystemTimes;

    let mut idle = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let mut kernel = idle;
    let mut user = idle;
    // SAFETY: the three out-params are valid `FILETIME` slots.
    if unsafe { GetSystemTimes(&mut idle, &mut kernel, &mut user) } == 0 {
        return None;
    }
    let ticks = |time: &FILETIME| ((time.dwHighDateTime as u64) << 32) | time.dwLowDateTime as u64;
    let (idle, kernel, user) = (ticks(&idle), ticks(&kernel), ticks(&user));
    // Kernel time includes idle; busy is the rest plus user.
    let busy = kernel.saturating_sub(idle).saturating_add(user);
    Some(CpuSample {
        busy_ticks: busy,
        total_ticks: kernel.saturating_add(user),
    })
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn sample_cpu_ticks() -> Option<CpuSample> {
    None
}

#[cfg(target_os = "macos")]
fn battery_status() -> Option<BatteryStatus> {
    use std::time::{Duration, Instant};

    #[derive(Clone, Copy)]
    struct CachedBattery {
        sampled_at: Instant,
        status: Option<BatteryStatus>,
    }

    const BATTERY_CACHE_TTL: Duration = Duration::from_secs(15);
    static BATTERY_CACHE: OnceLock<Mutex<Option<CachedBattery>>> = OnceLock::new();

    let slot = BATTERY_CACHE.get_or_init(|| Mutex::new(None));
    if let Ok(guard) = slot.lock()
        && let Some(cached) = *guard
        && cached.sampled_at.elapsed() < BATTERY_CACHE_TTL
    {
        return cached.status;
    }

    // IOKit would need new FFI deps; `pmset`'s battery line has been
    // stable for a decade and caching across a 15s TTL bounds subprocess
    // spawns across 25s heartbeats and multiple open tabs.
    let fresh = std::process::Command::new("pmset")
        .args(["-g", "batt"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| parse_pmset_batt(&String::from_utf8_lossy(&output.stdout)));

    if let Ok(mut guard) = slot.lock() {
        *guard = Some(CachedBattery {
            sampled_at: Instant::now(),
            status: fresh,
        });
    }
    fresh
}

/// Parses `pmset -g batt`, e.g.
/// ` -InternalBattery-0 (id=40960099)\t87%; charging; 0:41 remaining present: true`.
/// Desktops print no `InternalBattery` line, which parses to unknown
/// (hidden), not to a bogus 0%.
#[cfg(any(target_os = "macos", test))]
fn parse_pmset_batt(text: &str) -> Option<BatteryStatus> {
    let line = text.lines().find(|line| line.contains("InternalBattery"))?;
    let (percent_part, rest) = line.split_once('%')?;
    let percent: u8 = percent_part
        .rsplit([' ', '\t'])
        .find_map(|token| token.parse().ok())?;
    if percent > 100 {
        return None;
    }
    let rest = rest.to_lowercase();
    // Order matters: "discharging" and "not charging" both contain "charg".
    let state = if rest.contains("discharging") {
        BatteryState::Discharging
    } else if rest.contains("charged") {
        BatteryState::Full
    } else if rest.contains("not charging") {
        BatteryState::Unknown
    } else if rest.contains("charg") {
        BatteryState::Charging
    } else {
        BatteryState::Unknown
    };
    Some(BatteryStatus { percent, state })
}

#[cfg(target_os = "linux")]
fn battery_status() -> Option<BatteryStatus> {
    battery_status_from_sysfs_dir(std::path::Path::new("/sys/class/power_supply"))
}

#[cfg(any(target_os = "linux", test))]
fn battery_status_from_sysfs_dir(dir: &std::path::Path) -> Option<BatteryStatus> {
    let mut percents = Vec::new();
    let mut statuses = Vec::new();
    let entries = std::fs::read_dir(dir).ok()?;
    for entry in entries.flatten() {
        if !entry.file_name().to_string_lossy().starts_with("BAT") {
            continue;
        }
        let Ok(capacity_text) = std::fs::read_to_string(entry.path().join("capacity")) else {
            continue;
        };
        let Ok(capacity) = capacity_text.trim().parse::<u16>() else {
            continue;
        };
        let Ok(status) = std::fs::read_to_string(entry.path().join("status")) else {
            continue;
        };
        percents.push(capacity.min(100) as u8);
        statuses.push(status);
    }
    if percents.is_empty() {
        return None;
    }
    let percent =
        (percents.iter().map(|&percent| percent as u32).sum::<u32>() / percents.len() as u32) as u8;
    let mut has_discharging = false;
    let mut has_charging = false;
    let mut has_full = false;
    for status in &statuses {
        match status.trim().to_ascii_lowercase().as_str() {
            "discharging" => has_discharging = true,
            "charging" => has_charging = true,
            "full" => has_full = true,
            _ => {}
        }
    }
    let state = if has_discharging {
        BatteryState::Discharging
    } else if has_charging {
        BatteryState::Charging
    } else if has_full {
        BatteryState::Full
    } else {
        BatteryState::Unknown
    };
    Some(BatteryStatus { percent, state })
}

#[cfg(windows)]
#[allow(unsafe_code)]
fn battery_status() -> Option<BatteryStatus> {
    use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};

    let mut status: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
    // SAFETY: `status` is a valid out-param slot.
    if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
        return None;
    }
    battery_status_from_windows_fields(
        status.ACLineStatus,
        status.BatteryFlag,
        status.BatteryLifePercent,
    )
}

#[cfg(any(windows, test))]
fn battery_status_from_windows_fields(
    ac_line_status: u8,
    battery_flag: u8,
    battery_life_percent: u8,
) -> Option<BatteryStatus> {
    // 128 = no system battery bit, 255 = unknown flag/percent: desktops
    // and UPS-backed machines report unknown (hidden), never 0%.
    if battery_life_percent == 255 || (battery_flag != 255 && (battery_flag & 128) != 0) {
        return None;
    }
    let percent = battery_life_percent.min(100);
    let is_charging = battery_flag != 255 && (battery_flag & 8) != 0;
    let state = match ac_line_status {
        _ if is_charging => BatteryState::Charging,
        1 if percent >= 100 => BatteryState::Full,
        0 => BatteryState::Discharging,
        _ => BatteryState::Unknown,
    };
    Some(BatteryStatus { percent, state })
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn battery_status() -> Option<BatteryStatus> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn battery_state_deserializes_unknown_future_variant_to_unknown() {
        let state: BatteryState = serde_json::from_str(r#""calibrating""#).unwrap();
        assert_eq!(state, BatteryState::Unknown);
    }

    #[test]
    fn cpu_delta_math_reports_busy_share() {
        let before = CpuSample {
            busy_ticks: 100,
            total_ticks: 1000,
        };
        let after = CpuSample {
            busy_ticks: 150,
            total_ticks: 1100,
        };
        assert_eq!(cpu_percent_between(before, after), Some(50));
    }

    #[test]
    fn cpu_delta_math_rejects_stalled_and_wrapped_counters() {
        let sample = CpuSample {
            busy_ticks: 100,
            total_ticks: 1000,
        };
        assert_eq!(cpu_percent_between(sample, sample), None);
        let wrapped = CpuSample {
            busy_ticks: 5,
            total_ticks: 10,
        };
        assert_eq!(cpu_percent_between(sample, wrapped), None);
        let wrapped_busy_only = CpuSample {
            busy_ticks: 90,
            total_ticks: 1100,
        };
        assert_eq!(cpu_percent_between(sample, wrapped_busy_only), None);
    }

    #[test]
    fn cpu_delta_math_clamps_busy_above_total() {
        let before = CpuSample {
            busy_ticks: 0,
            total_ticks: 0,
        };
        let after = CpuSample {
            busy_ticks: 200,
            total_ticks: 100,
        };
        assert_eq!(cpu_percent_between(before, after), Some(100));
    }

    #[test]
    fn cpu_sampler_preserves_reading_across_same_tick_polls() {
        let mut state = None;
        let t0 = CpuSample {
            busy_ticks: 100,
            total_ticks: 1000,
        };
        let t1 = CpuSample {
            busy_ticks: 125,
            total_ticks: 1100,
        };
        assert_eq!(advance_cpu_sampler(&mut state, t0), None);
        assert_eq!(advance_cpu_sampler(&mut state, t0), None);
        assert_eq!(advance_cpu_sampler(&mut state, t1), Some(25));
        assert_eq!(advance_cpu_sampler(&mut state, t1), Some(25));
    }

    #[test]
    fn mach_ticks_above_i32_max_preserve_unsigned_idle_count() {
        let sample = cpu_sample_from_mach_ticks([100, 50, 0x8000_0100, 0]);
        assert_eq!(sample.busy_ticks, 150);
        assert_eq!(sample.total_ticks, 150 + 0x8000_0100);
    }

    #[test]
    fn proc_stat_parses_aggregate_cpu_line() {
        let sample =
            parse_proc_stat_cpu("cpu  100 0 50 800 10 0 5 0 0 0\ncpu0 50 0 25 400 5 0 2 0 0 0\n")
                .expect("aggregate line parses");
        // busy = 100+0+50+0+5 = 155, total includes idle 800 + iowait 10.
        assert_eq!(sample.busy_ticks, 155);
        assert_eq!(sample.total_ticks, 965);
        assert_eq!(parse_proc_stat_cpu("garbage\n"), None);
        assert_eq!(parse_proc_stat_cpu("cpu  1 2\n"), None);
    }

    #[test]
    fn pmset_parses_charging_discharging_charged_and_not_charging() {
        let charging = parse_pmset_batt(
            "Now drawing from 'AC Power'\n -InternalBattery-0 (id=40960099)\t87%; charging; 0:41 remaining present: true\n",
        )
        .expect("charging line parses");
        assert_eq!(charging.percent, 87);
        assert_eq!(charging.state, BatteryState::Charging);

        let discharging = parse_pmset_batt(
            "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=40960099)\t42%; discharging; 3:12 remaining present: true\n",
        )
        .expect("discharging line parses");
        assert_eq!(discharging.percent, 42);
        assert_eq!(discharging.state, BatteryState::Discharging);

        let charged = parse_pmset_batt(
            "Now drawing from 'AC Power'\n -InternalBattery-0 (id=40960099)\t100%; charged; 0:00 remaining present: true\n",
        )
        .expect("charged line parses");
        assert_eq!(charged.percent, 100);
        assert_eq!(charged.state, BatteryState::Full);

        let not_charging = parse_pmset_batt(
            "Now drawing from 'AC Power'\n -InternalBattery-0 (id=40960099)\t80%; AC attached; not charging present: true\n",
        )
        .expect("not charging line parses");
        assert_eq!(not_charging.percent, 80);
        assert_eq!(not_charging.state, BatteryState::Unknown);
    }

    #[test]
    fn pmset_reports_unknown_without_a_battery_line() {
        assert_eq!(
            parse_pmset_batt("Now drawing from 'AC Power'\nNo batteries available\n"),
            None
        );
        assert_eq!(parse_pmset_batt(""), None);
        assert_eq!(
            parse_pmset_batt(" -InternalBattery-0 (id=1)\t101%; charging;\n"),
            None
        );
    }

    #[test]
    fn linux_sysfs_battery_aggregates_and_skips_unreadable_slots() {
        let temp =
            std::env::temp_dir().join(format!("triage-host-sysfs-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temp);
        let bat0 = temp.join("BAT0");
        let bat1 = temp.join("BAT1");
        let bat2 = temp.join("BAT2");
        let ac = temp.join("AC");
        std::fs::create_dir_all(&bat0).unwrap();
        std::fs::create_dir_all(&bat1).unwrap();
        std::fs::create_dir_all(&bat2).unwrap();
        std::fs::create_dir_all(&ac).unwrap();

        std::fs::write(bat0.join("capacity"), "80\n").unwrap();
        std::fs::write(bat0.join("status"), "Not charging\n").unwrap();
        // BAT1 is an unpopulated bay (missing capacity/status): must be skipped.
        std::fs::write(bat2.join("capacity"), "100\n").unwrap();
        std::fs::write(bat2.join("status"), "Full\n").unwrap();

        let status = battery_status_from_sysfs_dir(&temp).expect("valid batteries aggregate");
        assert_eq!(status.percent, 90);
        assert_eq!(status.state, BatteryState::Full);

        std::fs::write(bat2.join("status"), "Not charging\n").unwrap();
        let held = battery_status_from_sysfs_dir(&temp).expect("not charging battery parses");
        assert_eq!(held.percent, 90);
        assert_eq!(held.state, BatteryState::Unknown);

        let _ = std::fs::remove_dir_all(&temp);
    }

    #[test]
    fn windows_battery_fields_handle_bitmasks_and_charge_hold() {
        assert_eq!(battery_status_from_windows_fields(1, 128, 100), None);
        assert_eq!(battery_status_from_windows_fields(1, 128 | 1, 80), None);
        assert_eq!(battery_status_from_windows_fields(1, 1, 255), None);
        assert_eq!(
            battery_status_from_windows_fields(1, 8 | 1, 80),
            Some(BatteryStatus {
                percent: 80,
                state: BatteryState::Charging,
            })
        );
        assert_eq!(
            battery_status_from_windows_fields(1, 1, 80),
            Some(BatteryStatus {
                percent: 80,
                state: BatteryState::Unknown,
            })
        );
        assert_eq!(
            battery_status_from_windows_fields(1, 1, 100),
            Some(BatteryStatus {
                percent: 100,
                state: BatteryState::Full,
            })
        );
        assert_eq!(
            battery_status_from_windows_fields(0, 2, 25),
            Some(BatteryStatus {
                percent: 25,
                state: BatteryState::Discharging,
            })
        );
    }

    #[test]
    fn daemon_host_stats_never_reports_bogus_values() {
        if let Some(slot) = LAST_CPU_SAMPLE.get() {
            *slot.lock().unwrap() = None;
        }
        // First poll seeds the CPU sampler (unknown). On supported OSes, pin
        // that the live tick probe populated LAST_CPU_SAMPLE with a valid
        // sample, then rewind the baseline so the second poll deterministically
        // exercises the delta path without sleeping.
        let first = daemon_host_stats();
        assert!(first.cpu_percent.is_none());
        if let Some(percent) = first.battery.map(|battery| battery.percent) {
            assert!(percent <= 100);
        }
        #[cfg(any(target_os = "macos", target_os = "linux", windows))]
        {
            let mut guard = LAST_CPU_SAMPLE
                .get()
                .expect("CPU sampler slot initialized")
                .lock()
                .unwrap();
            let seeded = guard.expect("sample_cpu_ticks must succeed on supported OS");
            assert!(seeded.sample.total_ticks > 0);
            assert!(seeded.sample.busy_ticks <= seeded.sample.total_ticks);
            *guard = Some(CpuSamplerState {
                sample: CpuSample {
                    busy_ticks: 0,
                    total_ticks: 0,
                },
                last_percent: None,
            });
        }
        let second = daemon_host_stats();
        #[cfg(any(target_os = "macos", target_os = "linux", windows))]
        assert!(
            second.cpu_percent.is_some_and(|percent| percent <= 100),
            "expected bounded CPU percent after seeded baseline, got {:?}",
            second.cpu_percent
        );
        if let Some(percent) = second.cpu_percent {
            assert!(percent <= 100);
        }
        if let Some(percent) = second.battery.map(|battery| battery.percent) {
            assert!(percent <= 100);
        }
    }
}
