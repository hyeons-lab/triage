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
    #[default]
    Unknown,
    Charging,
    Discharging,
    Full,
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
    let busy = after.busy_ticks.saturating_sub(before.busy_ticks);
    let total = after.total_ticks.saturating_sub(before.total_ticks);
    if total == 0 {
        return None;
    }
    let busy = busy.min(total);
    u8::try_from(busy.saturating_mul(100) / total).ok()
}

static LAST_CPU_SAMPLE: OnceLock<Mutex<Option<CpuSample>>> = OnceLock::new();

fn cpu_percent() -> Option<u8> {
    let now = sample_cpu_ticks()?;
    let slot = LAST_CPU_SAMPLE.get_or_init(|| Mutex::new(None));
    let previous = slot.lock().ok()?.replace(now);
    previous.and_then(|before| cpu_percent_between(before, now))
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
fn sample_cpu_ticks() -> Option<CpuSample> {
    // `kern.cp_time` is gone on modern macOS; the Mach CPU load info is
    // the cumulative-ticks source. Hand-declared: libc carries no Mach
    // host APIs.
    const HOST_CPU_LOAD_INFO: i32 = 3;
    const CPU_STATE_USER: usize = 0;
    const CPU_STATE_SYSTEM: usize = 1;
    const CPU_STATE_IDLE: usize = 2;
    const CPU_STATE_NICE: usize = 3;
    const CPU_STATE_MAX: usize = 4;
    const KERN_SUCCESS: i32 = 0;

    #[link(name = "System")]
    unsafe extern "C" {
        fn mach_host_self() -> u32;
        fn host_statistics64(host: u32, flavor: i32, info: *mut i32, count: *mut u32) -> i32;
    }

    // SAFETY: `mach_host_self` returns a valid send right to the host
    // port; `host_statistics64` writes at most `CPU_STATE_MAX` integers
    // into the caller buffer when `count` starts at its capacity.
    let host = unsafe { mach_host_self() };
    let mut ticks = [0i32; CPU_STATE_MAX];
    let mut count = CPU_STATE_MAX as u32;
    let result =
        unsafe { host_statistics64(host, HOST_CPU_LOAD_INFO, ticks.as_mut_ptr(), &mut count) };
    if result != KERN_SUCCESS || count as usize != CPU_STATE_MAX {
        return None;
    }
    let tick = |index: usize| u64::try_from(ticks[index]).unwrap_or(0);
    let idle = tick(CPU_STATE_IDLE);
    let total = tick(CPU_STATE_USER) + tick(CPU_STATE_SYSTEM) + idle + tick(CPU_STATE_NICE);
    Some(CpuSample {
        busy_ticks: total.saturating_sub(idle),
        total_ticks: total,
    })
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
    // IOKit would need new FFI deps; `pmset`'s battery line has been
    // stable for a decade and one fork per 60s poll is negligible.
    let output = std::process::Command::new("pmset")
        .args(["-g", "batt"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_pmset_batt(&String::from_utf8_lossy(&output.stdout))
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
    // Order matters: "discharging" contains "charging".
    let state = if rest.contains("discharging") {
        BatteryState::Discharging
    } else if rest.contains("charged") {
        BatteryState::Full
    } else if rest.contains("charg") {
        BatteryState::Charging
    } else {
        BatteryState::Unknown
    };
    Some(BatteryStatus { percent, state })
}

#[cfg(target_os = "linux")]
fn battery_status() -> Option<BatteryStatus> {
    let mut percents = Vec::new();
    let mut statuses = Vec::new();
    let entries = std::fs::read_dir("/sys/class/power_supply").ok()?;
    for entry in entries.flatten() {
        if !entry.file_name().to_string_lossy().starts_with("BAT") {
            continue;
        }
        let capacity: u8 = std::fs::read_to_string(entry.path().join("capacity"))
            .ok()?
            .trim()
            .parse()
            .ok()?;
        let status = std::fs::read_to_string(entry.path().join("status")).ok()?;
        percents.push(capacity.min(100));
        statuses.push(status);
    }
    if percents.is_empty() {
        return None;
    }
    let percent =
        (percents.iter().map(|&percent| percent as u32).sum::<u32>() / percents.len() as u32) as u8;
    let joined = statuses.join(" ").to_lowercase();
    // Order matters: "discharging" contains "charging".
    let state = if joined.contains("discharging") {
        BatteryState::Discharging
    } else if joined.contains("charging") {
        BatteryState::Charging
    } else if joined.contains("full") {
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
    // 128 = no system battery, 255 = unknown percent: desktops and
    // UPS-backed machines report unknown (hidden), never 0%.
    if status.BatteryFlag == 128 || status.BatteryLifePercent == 255 {
        return None;
    }
    let percent = status.BatteryLifePercent.min(100);
    let state = match status.ACLineStatus {
        1 if percent >= 100 => BatteryState::Full,
        1 => BatteryState::Charging,
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
    fn pmset_parses_charging_discharging_and_charged() {
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
    fn daemon_host_stats_never_reports_bogus_values() {
        // Two consecutive polls: the first seeds the CPU sampler (unknown),
        // the second is unknown-or-bounded; battery is unknown-or-bounded.
        // No sleep: back-to-back samples may legitimately not advance.
        let first = daemon_host_stats();
        assert!(first.cpu_percent.is_none());
        if let Some(percent) = first.battery.map(|battery| battery.percent) {
            assert!(percent <= 100);
        }
        let second = daemon_host_stats();
        if let Some(percent) = second.cpu_percent {
            assert!(percent <= 100);
        }
        if let Some(percent) = second.battery.map(|battery| battery.percent) {
            assert!(percent <= 100);
        }
    }
}
