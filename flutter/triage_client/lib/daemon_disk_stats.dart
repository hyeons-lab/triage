/// Formats daemon-host disk stats for the daemon selector's free-space line.
library;

/// Formats [freeBytes]/[totalBytes] as e.g. `"12,340 MB free (23%)"`.
///
/// Returns null when the figures are unknown (0/0 from a daemon that could
/// not probe, or predates stats), so the caller hides the line.
String? formatDiskFree(int freeBytes, int totalBytes) {
  if (freeBytes < 0 || totalBytes <= 0 || freeBytes > totalBytes) return null;
  final freeMb = freeBytes ~/ (1024 * 1024);
  // Divide before scaling: `freeBytes * 100` overflows exact integer range on
  // the web number type past ~90TB free, silently corrupting the percentage.
  final percent = (freeBytes / totalBytes * 100).round();
  return '${_withThousandsSeparators(freeMb)} MB free ($percent%)';
}

String _withThousandsSeparators(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  final offset = digits.length % 3;
  if (offset > 0) buffer.write(digits.substring(0, offset));
  for (var i = offset; i < digits.length; i += 3) {
    if (buffer.isNotEmpty) buffer.write(',');
    buffer.write(digits.substring(i, i + 3));
  }
  return buffer.toString();
}
