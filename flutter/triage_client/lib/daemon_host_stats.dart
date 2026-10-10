/// Formats daemon-host CPU and battery stats for the daemon selector.
library;

/// Formats host stats as e.g. `"CPU 12% · Battery 87% (charging)"`.
///
/// Each leg hides independently when unknown; returns null when both are
/// unknown so the caller hides the line. Out-of-range percents also hide
/// their leg rather than rendering a bogus number.
String? formatHostStats({
  int? cpuPercent,
  int? batteryPercent,
  String batteryState = 'unknown',
}) {
  final segments = <String>[];
  if (cpuPercent != null && cpuPercent >= 0 && cpuPercent <= 100) {
    segments.add('CPU $cpuPercent%');
  }
  if (batteryPercent != null && batteryPercent >= 0 && batteryPercent <= 100) {
    var battery = 'Battery $batteryPercent%';
    switch (batteryState) {
      case 'charging':
        battery += ' (charging)';
      case 'discharging':
        battery += ' (discharging)';
      case 'full':
        battery += ' (full)';
      case 'unknown':
        break;
      default:
        break;
    }
    segments.add(battery);
  }
  if (segments.isEmpty) return null;
  return segments.join(' · ');
}
