/// Whether a live terminal grid disagrees with the shared PTY's size.
///
/// Companion to `SessionVm.hostSizeDriftedFromOwnFit`: that getter compares
/// the host against the last size this device *sent*, so a fit that applied
/// locally but never reached the host (term 46, PTY 80, last-sent 80) reads
/// as healthy. Comparing the view's *actual* grid against the host closes
/// that blind spot and lets the foreground reclaim heal a stuck-narrow grid.
///
/// False when either size is unknown: with nothing to compare, the quiet
/// option is to leave the PTY alone.
bool liveGridDriftedFromHost({
  required int? gridCols,
  required int? gridRows,
  required int? hostCols,
  required int? hostRows,
}) {
  if (gridCols == null || gridRows == null) return false;
  if (hostCols == null || hostRows == null) return false;
  return gridCols != hostCols || gridRows != hostRows;
}
